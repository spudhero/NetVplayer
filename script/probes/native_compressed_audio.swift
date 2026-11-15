// Independent, muted AVFoundation research host. Not linked into NetVplayer.
// No private API, process tap, global device write, or mpv clock substitution.
import AppKit
import AVFoundation
import CoreAudio
import CryptoKit
import MachO

enum ProbeError: Error { case failed(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.failed(message) }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func fourcc(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii) ?? "unknown"
}
func seconds(_ time: CMTime) -> Double { time.isNumeric ? time.seconds : -1 }
func errorRecord(_ error: Error?) -> Any {
    guard let error else { return NSNull() }
    let e = error as NSError
    // Deliberately omit localizedDescription/userInfo, which may contain paths.
    return ["domain": e.domain, "code": e.code]
}
func bytes(_ sample: CMSampleBuffer) throws -> Data {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { throw ProbeError.failed("missing block") }
    let count = CMBlockBufferGetDataLength(block)
    try require(count > 0 && count <= 1_048_576, "packet byte budget")
    var data = Data(count: count)
    let result = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
    try require(result == 0, "copy packet")
    return data
}
func format(_ sample: CMSampleBuffer) throws -> [String: Any] {
    guard let desc = sample.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
        throw ProbeError.failed("missing ASBD")
    }
    var size = 0
    let cookie = CMAudioFormatDescriptionGetMagicCookie(desc, sizeOut: &size)
    let data = cookie.map { Data(bytes: $0, count: size) } ?? Data()
    return ["formatID": fourcc(asbd.pointee.mFormatID), "sampleRate": asbd.pointee.mSampleRate,
            "channels": asbd.pointee.mChannelsPerFrame, "framesPerPacket": asbd.pointee.mFramesPerPacket,
            "cookieBytes": size, "cookieSHA256": digest(data)]
}
func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: UInt32) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var value = initial, size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == 0 ? value : nil
}
func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == 0,
          size <= 256, size % 4 == 0 else { return [] }
    guard size > 0 else { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size / 4))
    let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
    return status == 0 ? result : []
}
func deviceUID(_ device: AudioObjectID) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var uid: CFString?, size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &a, 0, nil, &size, $0) }
    return status == 0 ? uid as String? : nil
}
func routeUID(_ transport: UInt32) -> String? {
    for device in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
        if property(device, kAudioDevicePropertyTransportType, UInt32(0)) == transport {
            return deviceUID(device)
        }
    }
    return nil
}
func processOutput() -> [String: Any] {
    if #available(macOS 14.2, *) {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var pid = getpid(), process: AudioObjectID = 0, size: UInt32 = 4
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 4, &pid, &size, &process)
        guard status == 0 else { return ["status": status] }
        return ["runningOutput": property(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0,
                "deviceTransports": ids(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).compactMap {
                    property($0, kAudioDevicePropertyTransportType, UInt32(0)).map(fourcc)
                }]
    }
    return ["unavailableOnThisOS": true]
}

@MainActor final class Source {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    init(_ asset: AVURLAsset, track: AVAssetTrack, start: Double = 0) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        try require(reader.canAdd(output), "reader cannot add output")
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), duration: .positiveInfinity)
        try require(reader.startReading(), "reader start failed")
    }
}

/// Research-only polling producer. All reads/enqueues/flushes share MainActor.
/// It retains at most one pending sample, and limits submitted media lead to 1 s.
/// The renderer's private decode buffers are not claimed as app-owned memory.
@MainActor final class Sink {
    let renderer = AVSampleBufferAudioRenderer()
    let sync = AVSampleBufferRenderSynchronizer()
    var source: Source?
    var pending: CMSampleBuffer?
    var generation = 0, epoch = 0, enqueued = 0, staleRejected = 0
    var maximumLead = 0.0, maximumPacketBytes = 0
    var firstPTS: Double?, lastEnd = 0.0
    var notices: [String: Int] = [:]
    var emptyMarkers = 0, prerollPackets = 0
    var observers: [NSObjectProtocol] = []
    init() {
        renderer.isMuted = true
        renderer.volume = 0
        renderer.allowedAudioSpatializationFormats = []
        sync.addRenderer(renderer)
        sync.delaysRateChangeUntilHasSufficientMediaData = false
        for (name, label) in [(Notification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically, "automaticFlush"),
                              (Notification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange, "configurationChange")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: renderer, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.notices[label, default: 0] += 1
                    // Conservative research failure boundary: pause and invalidate.
                    // Restart must explicitly seek/re-prime; do not silently continue.
                    self.invalidate()
                }
            })
        }
    }
    func invalidate() {
        epoch += 1
        source?.reader.cancelReading(); source = nil; pending = nil
        sync.setRate(0, time: .invalid)
        renderer.flush()
    }
    func begin(_ asset: AVURLAsset, track: AVAssetTrack, at start: Double, newMedia: Bool = false) throws {
        invalidate()
        if newMedia { generation += 1 }
        firstPTS = nil; lastEnd = start
        source = try Source(asset, track: track, start: start)
        sync.setRate(0, time: CMTime(seconds: start, preferredTimescale: 48_000))
    }
    func submit(_ sample: CMSampleBuffer, generation expectedGeneration: Int, epoch expectedEpoch: Int) throws {
        guard source != nil, expectedGeneration == generation, expectedEpoch == epoch else { staleRejected += 1; return }
        let data = try bytes(sample)
        let pts = seconds(CMSampleBufferGetOutputPresentationTimeStamp(sample)), duration = seconds(CMSampleBufferGetOutputDuration(sample))
        // Seeking may return a full compressed priming packet with zero output
        // duration. Preserve its trim attachments and let the system decode it.
        try require(pts >= 0 && duration >= 0 && duration <= 0.1 && seconds(sample.duration) > 0, "invalid packet timing")
        if duration == 0 { prerollPackets += 1 }
        try require(CMFormatDescriptionGetMediaSubType(sample.formatDescription!) == kAudioFormatEnhancedAC3, "not ordinary EAC3")
        renderer.enqueue(sample)
        firstPTS = firstPTS ?? pts; lastEnd = pts + duration; enqueued += 1
        maximumLead = max(maximumLead, lastEnd - seconds(sync.currentTime()))
        maximumPacketBytes = max(maximumPacketBytes, data.count)
    }
    func pump() throws {
        guard let source else { return }
        try require(renderer.status != .failed, "renderer failed")
        for _ in 0..<64 {
            guard renderer.isReadyForMoreMediaData else { break }
            if pending == nil { pending = source.output.copyNextSampleBuffer() }
            guard let sample = pending else {
                try require(source.reader.status == .completed, "reader failed before EOF")
                break
            }
            if sample.numSamples == 0 { emptyMarkers += 1; pending = nil; continue }
            let end = seconds(CMSampleBufferGetOutputPresentationTimeStamp(sample)) + seconds(CMSampleBufferGetOutputDuration(sample))
            if end - seconds(sync.currentTime()) > 1.0 { break }
            try submit(sample, generation: generation, epoch: epoch)
            pending = nil
        }
    }
    func run(_ duration: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat { try pump(); try await Task.sleep(for: .milliseconds(10)) }
        while ProcessInfo.processInfo.systemUptime < deadline
    }
    func snapshot(_ label: String) -> [String: Any] {
        let clock = CMTimebaseCopyUltimateSourceClock(sync.timebase)
        let record: [String: Any] = ["stage": label, "time": seconds(sync.currentTime()), "rate": sync.rate,
                "status": renderer.status.rawValue, "error": errorRecord(renderer.error),
                "generation": generation, "epoch": epoch, "enqueued": enqueued,
                "firstPTS": firstPTS as Any? ?? NSNull(), "lastEnd": lastEnd,
                "sourceIsHostClock": CFEqual(clock, CMClockGetHostTimeClock()),
                "process": processOutput(), "muted": renderer.isMuted, "volume": renderer.volume,
                "notices": notices, "emptyMarkers": emptyMarkers, "zeroOutputDurationPrerollPackets": prerollPackets]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
        }
        return record
    }
    func close() async {
        invalidate()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sync.removeRenderer(renderer, at: .invalid) { _ in continuation.resume() }
        }
    }
}

@main struct Probe {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        let reportURL = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { exit(3) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var report: [String: Any] = ["schema": 1, "mode": args[1], "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "minimumTarget": "14.0", "productIntegration": false, "receiverAtmosVerified": false,
            "audibleOutputVerified": false, "spatializationAllowed": false, "mutedThroughout": true,
            "limits": "Renderer status/clock/active process device are API observations, not acoustic, HDMI bitstream, JOC or object proof."]
        var activeSink: Sink?
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            try require(tracks.count == 1, "expected one audio track")
            let track = tracks[0]
            if args[1] == "inspect" {
                let source = try Source(asset, track: track)
                defer { source.reader.cancelReading() }
                var packets: [[String: Any]] = [], buffers: [[String: Any]] = [], markers: [[String: Any]] = [], hash = SHA256(), total = 0
                while let sample = source.output.copyNextSampleBuffer() {
                    if sample.numSamples == 0 {
                        markers.append(["pts": seconds(sample.presentationTimeStamp), "hasData": sample.dataBuffer != nil])
                        continue
                    }
                    let data = try bytes(sample)
                    try require(packets.count < 8192 && total + data.count <= 128 * 1024 * 1024, "inspect budget")
                    if packets.isEmpty { report["format"] = try format(sample) }
                    hash.update(data: data); total += data.count
                    var record: [String: Any] = ["pts": seconds(sample.presentationTimeStamp),
                        "outputPTS": seconds(CMSampleBufferGetOutputPresentationTimeStamp(sample)),
                        "duration": seconds(sample.duration), "samples": sample.numSamples]
                    for (key, label) in [(kCMSampleBufferAttachmentKey_TrimDurationAtStart, "trimStart"),
                                         (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, "trimEnd")] {
                        if let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) {
                            record[label] = String(describing: value)
                        }
                    }
                    buffers.append(record)
                    // A CMSampleBuffer may carry several codec packets. Count and
                    // hash its sample-size/timing table, not one packet per buffer.
                    var offset = 0
                    for index in 0..<sample.numSamples {
                        let size = CMSampleBufferGetSampleSize(sample, at: index)
                        var timing = CMSampleTimingInfo()
                        try require(CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == 0,
                                    "sample timing table")
                        try require(size > 0 && offset + size <= data.count, "sample size table")
                        var single: CMSampleBuffer?
                        try require(CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                            sampleRange: CFRange(location: index, length: 1), sampleBufferOut: &single) == 0,
                            "copy packet timing")
                        packets.append(["pts": seconds(timing.presentationTimeStamp), "duration": seconds(timing.duration),
                                        "outputPTS": seconds(CMSampleBufferGetOutputPresentationTimeStamp(single!)),
                                        "outputDuration": seconds(CMSampleBufferGetOutputDuration(single!)),
                                        "bytes": size, "sha256": digest(data.subdata(in: offset..<offset+size))])
                        offset += size
                    }
                    try require(offset == data.count, "sample table covers payload")
                }
                try require(source.reader.status == .completed && !packets.isEmpty, "incomplete packet extraction")
                report["packets"] = packets; report["bytes"] = total
                report["emptyMarkers"] = markers
                report["buffers"] = buffers
                report["payloadSHA256"] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            } else {
                try require(args[1] == "lifecycle", "unknown mode")
                let defaultBefore = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, UInt32(0))
                let sink = Sink(); activeSink = sink
                let identity = ObjectIdentifier(sink.renderer), syncIdentity = ObjectIdentifier(sink.sync)
                var stages: [[String: Any]] = []
                try sink.begin(asset, track: track, at: 0, newMedia: true)
                try await sink.run(0.2)
                sink.sync.setRate(1, time: .invalid)
                // setRate updates the timebase asynchronously. Bound startup wait
                // separately; steady rate is measured after actual advancement.
                let startup = ProcessInfo.processInfo.systemUptime
                while seconds(sink.sync.currentTime()) < 1 && ProcessInfo.processInfo.systemUptime - startup < 3 {
                    try await sink.run(0.1)
                }
                report["startupToOneSecondWall"] = ProcessInfo.processInfo.systemUptime - startup
                try require(seconds(sink.sync.currentTime()) > 0.9, "clock did not advance")
                stages.append(sink.snapshot("playing"))
                sink.sync.setRate(0, time: .invalid); try await sink.run(0.1)
                let paused = seconds(sink.sync.currentTime())
                try await sink.run(0.3)
                report["pauseDelta"] = abs(seconds(sink.sync.currentTime()) - paused)
                try require(abs(seconds(sink.sync.currentTime()) - paused) < 0.05, "pause clock")
                let staleSource = try Source(asset, track: track)
                let staleSample = staleSource.output.copyNextSampleBuffer()!
                staleSource.reader.cancelReading()
                let oldGeneration = sink.generation, oldEpoch = sink.epoch
                try sink.begin(asset, track: track, at: 8)
                try await sink.run(0.2)
                let count = sink.enqueued
                try sink.submit(staleSample, generation: oldGeneration, epoch: oldEpoch)
                try require(sink.enqueued == count && sink.staleRejected == 1, "old seek epoch accepted")
                try require(abs(seconds(sink.sync.currentTime()) - 8) < 0.05, "paused seek clock")
                stages.append(sink.snapshot("pausedSeek"))
                sink.sync.setRate(1, time: .invalid); try await sink.run(0.5)
                stages.append(sink.snapshot("resumed"))
                // UID is never exported; this does not change the system default.
                for (label, uid) in [("builtIn", routeUID(kAudioDeviceTransportTypeBuiltIn)),
                                     ("displayPort", routeUID(kAudioDeviceTransportTypeDisplayPort))] {
                    guard let uid else { stages.append(["stage": label, "skipped": "device unavailable"]); continue }
                    let position = seconds(sink.sync.currentTime())
                    sink.invalidate(); sink.renderer.audioOutputDeviceUniqueID = uid
                    try await Task.sleep(for: .milliseconds(250))
                    try sink.begin(asset, track: track, at: position)
                    try await sink.run(0.15)
                    sink.sync.setRate(1, time: .invalid); try await sink.run(0.7)
                    try require(seconds(sink.sync.currentTime()) > position + 0.4, "route clock stalled")
                    stages.append(sink.snapshot(label))
                }
                // Non-1x is measured as a system decode/time-pitch experiment ONLY.
                // It is never called object-preserving or offered by the product.
                // SDK says nullable, but macOS 26.6.2 throws on an explicit nil setter.
                // Restore the initial device explicitly; this is NOT automatic routing.
                guard let defaultBefore, let defaultUID = deviceUID(defaultBefore) else {
                    throw ProbeError.failed("default UID unavailable")
                }
                sink.invalidate(); sink.renderer.audioOutputDeviceUniqueID = defaultUID
                report["routeRestoration"] = "explicitInitialDefaultUID_notAutomaticRouting"
                try await Task.sleep(for: .milliseconds(250))
                try sink.begin(asset, track: track, at: 12)
                try await sink.run(0.15)
                sink.sync.setRate(1.5, time: .invalid)
                try await sink.run(0.5)
                let mediaStart = seconds(sink.sync.currentTime())
                let wall = ProcessInfo.processInfo.systemUptime
                try await sink.run(0.8)
                let rate = (seconds(sink.sync.currentTime()) - mediaStart) / (ProcessInfo.processInfo.systemUptime - wall)
                report["measuredRate"] = rate
                stages.append(sink.snapshot("systemDecodeRate1_5"))
                try require(abs(rate - 1.5) < 0.1, "system rate clock")
                let previousGeneration = sink.generation, previousEpoch = sink.epoch
                try sink.begin(asset, track: track, at: 0, newMedia: true)
                try await sink.run(0.15)
                let beforeOldMedia = sink.enqueued
                try sink.submit(staleSample, generation: previousGeneration, epoch: previousEpoch)
                try require(sink.enqueued == beforeOldMedia && sink.staleRejected == 2, "old media accepted")
                stages.append(sink.snapshot("newMedia"))
                try sink.begin(asset, track: track, at: 39.5)
                try await sink.run(0.2)
                sink.sync.setRate(1, time: .invalid); try await sink.run(1.0)
                try require(sink.source?.reader.status == .completed && sink.pending == nil, "EOF not reached")
                stages.append(sink.snapshot("sourceEOF"))
                sink.invalidate()
                let stopped = sink.enqueued
                try await sink.run(0.2)
                try sink.submit(staleSample, generation: sink.generation, epoch: sink.epoch)
                try require(sink.enqueued == stopped && sink.staleRejected == 3, "post-cancel enqueue")
                stages.append(sink.snapshot("cancelled"))
                try require(ObjectIdentifier(sink.renderer) == identity && ObjectIdentifier(sink.sync) == syncIdentity, "renderer replaced")
                try require(sink.maximumLead <= 1.05 && sink.maximumPacketBytes <= 1_048_576, "queue budget")
                report["stages"] = stages; report["staleRejected"] = sink.staleRejected
                report["sameRendererAndSynchronizer"] = true
                report["maximumSubmittedLeadSeconds"] = sink.maximumLead
                report["maximumPacketBytes"] = sink.maximumPacketBytes
                report["systemDefaultUnchanged"] = defaultBefore == property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, UInt32(0))
                await sink.close(); activeSink = nil
            }
            report["passed"] = true
        } catch {
            report["passed"] = false; report["error"] = errorRecord(error)
            if case ProbeError.failed(let reason) = error { report["assertion"] = reason }
            if let sink = activeSink { report["failureStage"] = sink.snapshot("failed"); await sink.close() }
        }
        report["loadedImages"] = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic) }
        catch { exit(4) }
        exit(report["passed"] as? Bool == true ? 0 : 1)
    }
}
