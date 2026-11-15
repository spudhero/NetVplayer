// Offline AV-10 prototype. Never opens an output device or acquires head pose.
// Build: xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/netvplayer-av10-module-cache script/probe_playback_spatial_pcm.swift -o /private/tmp/netvplayer-av10-spatial-pcm
import AVFAudio
import CoreMotion
import Foundation

struct Fixture: Codable {
    let id: String
    let labels: [String]
    let azimuthDegrees: [Float?]
    let frames: Int
    let sampleRate: Double
    let decodedFile: String
}
struct Manifest: Codable { let fixtures: [Fixture] }
enum ProbeError: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.invalid(message) }
}
func writeJSON(_ value: Any, _ path: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path)
}

let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count) else { fatalError("usage: spatial-pcm <fixtures-dir> <new-output-dir> [hrtf|hrtf-hq|spherical]") }
let algorithmName = arguments.count == 4 ? arguments[3] : "hrtf"
try require(["hrtf", "hrtf-hq", "spherical"].contains(algorithmName), "unknown algorithm")
let algorithm: AVAudio3DMixingRenderingAlgorithm = algorithmName == "hrtf" ? .HRTF
    : algorithmName == "hrtf-hq" ? .HRTFHQ : .sphericalHead
let fixtures = URL(fileURLWithPath: arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
try require(!FileManager.default.fileExists(atPath: destination.path), "output exists")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
let motion = CMHeadphoneMotionManager()
try writeJSON([
    "schema": 1, "system": ProcessInfo.processInfo.operatingSystemVersionString,
    "motionAvailable": motion.isDeviceMotionAvailable,
    "motionActive": motion.isDeviceMotionActive,
    "authorizationStatus": CMHeadphoneMotionManager.authorizationStatus().rawValue,
    "poseSamples": 0, "motionUpdatesRequested": false,
    "headTrackingVerified": false, "headphoneEffectVerified": false,
    "systemSpatialAudioVerified": false, "atmosObjectsVerified": false
], destination.appendingPathComponent("environment.json"))

func render(_ fixture: Fixture, _ interleaved: [Float], channel: Int?, name: String) throws -> [String: Any] {
    let engine = AVAudioEngine()
    let environment = AVAudioEnvironmentNode()
    let stereo = AVAudioFormat(standardFormatWithSampleRate: fixture.sampleRate, channels: 2)!
    let mono = AVAudioFormat(standardFormatWithSampleRate: fixture.sampleRate, channels: 1)!
    engine.attach(environment)
    environment.outputType = .headphones
    environment.reverbParameters.enable = false
    environment.distanceAttenuationParameters.rolloffFactor = 0
    environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
    if #available(macOS 15, *) { environment.isListenerHeadTrackingEnabled = false }
    engine.connect(environment, to: engine.mainMixerNode, format: stereo)
    let algorithms = environment.applicableRenderingAlgorithms.map(\.intValue)
    try require(algorithms.contains(algorithm.rawValue), "requested algorithm unavailable")
    var players: [AVAudioPlayerNode] = []
    var retainedBuffers: [AVAudioPCMBuffer] = []
    for index in fixture.labels.indices {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let degrees = fixture.azimuthDegrees[index] {
            engine.connect(player, to: environment, format: mono)
            let radians = degrees * .pi / 180
            player.position = AVAudio3DPoint(x: sin(radians), y: 0, z: -cos(radians))
            player.sourceMode = .spatializeIfMono
            player.renderingAlgorithm = algorithm
            player.reverbBlend = 0
        } else {
            // LFE is deliberately non-positional; no invented bass direction.
            engine.connect(player, to: engine.mainMixerNode, format: mono)
        }
        player.volume = 0.125
        let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(fixture.frames))!
        buffer.frameLength = AVAudioFrameCount(fixture.frames)
        for frame in 0..<fixture.frames {
            buffer.floatChannelData![0][frame] = channel == nil || channel == index
                ? interleaved[frame * fixture.labels.count + index] : 0
        }
        player.scheduleBuffer(buffer)
        players.append(player); retainedBuffers.append(buffer)
    }
    try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
    let output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1024)!
    engine.prepare()
    try engine.start()
    defer { players.forEach { $0.stop() }; engine.stop(); engine.disableManualRenderingMode() }
    // All players start at the same offline clock, before any frame is rendered.
    players.forEach { $0.play() }
    let frames = fixture.frames + Int(fixture.sampleRate)
    var rendered = [Float](); rendered.reserveCapacity(frames * 2)
    var retries = 0
    let start = ContinuousClock.now
    while rendered.count / 2 < frames {
        let count = AVAudioFrameCount(min(1024, frames - rendered.count / 2))
        let status = try engine.renderOffline(count, to: output)
        switch status {
        case .success:
            try require(output.frameLength > 0, "empty successful render")
            for frame in 0..<Int(output.frameLength) {
                rendered.append(output.floatChannelData![0][frame])
                rendered.append(output.floatChannelData![1][frame])
            }
            retries = 0
        case .cannotDoInCurrentContext:
            retries += 1
            try require(retries < 100, "manual renderer stalled")
        default: throw ProbeError.invalid("manual rendering status \(status.rawValue)")
        }
    }
    let elapsed = start.duration(to: .now)
    let filename = fixture.id + "-" + name + ".f32"
    try rendered.withUnsafeBytes { Data($0) }.write(to: destination.appendingPathComponent(filename))
    // Keep scheduled buffers alive through the full render, including its tail.
    withExtendedLifetime(retainedBuffers) {}
    return ["fixture": fixture.id, "case": name, "file": filename, "frames": frames,
            "sampleRate": fixture.sampleRate, "algorithms": algorithms,
            "manualRenderSeconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "algorithm": algorithmName, "listenerYaw": 0, "gainPerChannel": 0.125, "physicalOutput": false]
}

var reports: [[String: Any]] = []
for fixture in manifest.fixtures {
    try require(fixture.labels.count == fixture.azimuthDegrees.count && [6, 8].contains(fixture.labels.count), "invalid layout")
    try require(fixture.frames > 0 && fixture.frames <= 480_000 && fixture.sampleRate == 48_000, "fixture budget")
    let data = try Data(contentsOf: fixtures.appendingPathComponent(fixture.decodedFile))
    try require(data.count == fixture.frames * fixture.labels.count * 4, "PCM length")
    var samples = [Float](repeating: 0, count: data.count / 4)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    try require(samples.allSatisfy(\.isFinite), "nonfinite PCM")
    reports.append(try render(fixture, samples, channel: nil, name: "all"))
    reports.append(try render(fixture, samples, channel: nil, name: "repeat"))
    for index in fixture.labels.indices {
        reports.append(try render(fixture, samples, channel: index, name: fixture.labels[index]))
    }
    try writeJSON(["schema": 1, "route": "Offline Apple \(algorithmName) from bundled-mpv decoded PCM; no headphones or pose", "renders": reports],
                  destination.appendingPathComponent("renders.json"))
}
print("Rendered \(reports.count) offline PCM cases; no physical spatial or tracking verification.")
