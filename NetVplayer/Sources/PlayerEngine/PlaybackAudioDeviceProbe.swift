import AudioToolbox
import CoreAudio
import Foundation

struct PlaybackAudioDeviceSnapshot: Equatable, Sendable {
    var enumerationSucceeded = false
    var outputs: [PlaybackAudioOutputDevice] = []
    var systemDefaultUID: String?
    var processOutputUIDs: [String]?
    var processOutputDevice: PlaybackAudioOutputDevice? {
        guard let ids = processOutputUIDs, ids.count == 1 else { return nil }
        return outputs.first { $0.id == ids[0] }
    }
    var systemDefaultDeviceName: String? { outputs.first { $0.id == systemDefaultUID }?.name }

    /// A compressed HDMI carrier can expose two transport channels and a 192 kHz
    /// clock even though the configured PCM device is 7.1 at 48 kHz. Keep the
    /// last PCM configuration for route planning. A two-channel carrier layout
    /// is not a replacement speaker setup; distinct PCM layouts, device/default
    /// identities and raw stream observations still update normally.
    func retainingPCMConfiguration(from previous: Self) -> Self {
        var result = self
        let compressedIDs: Set<String> = ["IAC3", "iac3", "cac3", "ac-3", "cc+3", "cd+3", "cec3", "mtc+", "mtct"]
        result.outputs = outputs.map { current in
            guard [.hdmi, .displayPort].contains(current.transport),
                  let formats = current.physicalFormats, !formats.isEmpty,
                  formats.allSatisfy({ compressedIDs.contains($0.formatID) }),
                  let pcm = previous.outputs.first(where: { $0.id == current.id && $0.transport == current.transport })
            else { return current }
            let carrierLayout = current.preferredChannels == nil ||
                ((current.preferredChannels?.count ?? 0) <= current.channelCapacity &&
                 (pcm.preferredChannels?.count ?? 0) > current.channelCapacity)
            return .init(id: current.id, name: current.name, transport: current.transport,
                channelCapacity: pcm.channelCapacity,
                preferredChannels: carrierLayout ? pcm.preferredChannels : current.preferredChannels,
                nominalSampleRate: pcm.nominalSampleRate,
                reportedLatencySeconds: current.reportedLatencySeconds, bufferFrames: current.bufferFrames,
                virtualFormats: current.virtualFormats, physicalFormats: current.physicalFormats)
        }
        return result
    }
}

/// Serial across both players, including cancelled/retired diagnostics tasks.
actor PlaybackAudioDeviceProbeWorker {
    static let shared = PlaybackAudioDeviceProbeWorker()
    static func snapshot() async -> PlaybackAudioDeviceSnapshot? {
        let task = Task.detached(priority: .utility) { await shared.read() }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func read() -> PlaybackAudioDeviceSnapshot? {
        guard !Task.isCancelled else { return nil }
        return PlaybackAudioDeviceProbe.read()
    }
}

enum PlaybackAudioDeviceProbe {
    private static let output = kAudioObjectPropertyScopeOutput

    /// Read-only, bounded queries; no capture, system routing or format changes.
    /// Called only from the utility worker, never from rendering or the UI thread.
    static func read() -> PlaybackAudioDeviceSnapshot {
        var snapshot = PlaybackAudioDeviceSnapshot()
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids: [AudioObjectID] = array(system, kAudioHardwarePropertyDevices), ids.count <= 64 else { return snapshot }
        snapshot.enumerationSucceeded = true
        for id in ids {
            guard scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), uid.utf8.count <= 512,
                  let streams: [AudioObjectID] = array(id, kAudioDevicePropertyStreams, scope: output), streams.count <= 64,
                  !streams.isEmpty else { continue }
            // Virtual stream formats describe the channels exposed by CoreAudio.
            let formats = streams.compactMap { scalar($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) }
            guard formats.count == streams.count else { continue }
            let capacity = formats.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
            guard capacity > 0, capacity <= 64 else { continue }
            let rate = scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
                .flatMap { $0.isFinite && $0 > 0 && $0 <= 3_072_000 ? $0 : nil }
            let deviceLatency = scalar(id, kAudioDevicePropertyLatency, scope: output, initial: UInt32(0))
            let safety = scalar(id, kAudioDevicePropertySafetyOffset, scope: output, initial: UInt32(0))
            let streamLatencies = streams.compactMap { scalar($0, kAudioStreamPropertyLatency, initial: UInt32(0)) }
            var latency: Double?
            if let rate, let deviceLatency, let safety, streamLatencies.count == streams.count,
               let streamLatency = streamLatencies.max() {
                let seconds = (Double(deviceLatency) + Double(safety) + Double(streamLatency)) / rate
                if seconds <= 10 { latency = seconds }
            }
            snapshot.outputs.append(.init(
                id: uid, name: String((string(id, kAudioObjectPropertyName) ?? uid).prefix(128)),
                transport: transport(scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0))),
                channelCapacity: capacity, preferredChannels: preferredChannels(id), nominalSampleRate: rate,
                reportedLatencySeconds: latency,
                bufferFrames: scalar(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)).map(Int.init),
                virtualFormats: streamFormats(streams, selector: kAudioStreamPropertyVirtualFormat),
                physicalFormats: streamFormats(streams, selector: kAudioStreamPropertyPhysicalFormat)
            ))
        }
        if let id = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)) {
            snapshot.systemDefaultUID = string(id, kAudioDevicePropertyDeviceUID)
        }
        if #available(macOS 14.2, *) {
            var pid = getpid()
            var process = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            if AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr,
               process != kAudioObjectUnknown,
               let devices: [AudioObjectID] = array(process, kAudioProcessPropertyDevices, scope: output), devices.count <= 64 {
                let uids = devices.compactMap { string($0, kAudioDevicePropertyDeviceUID) }
                if uids.count == devices.count { snapshot.processOutputUIDs = Array(Set(uids)).sorted() }
            }
        }
        return snapshot
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func streamFormats(_ streams: [AudioObjectID], selector: AudioObjectPropertySelector) -> [PlaybackAudioStreamFormat]? {
        // Keep the redacted diagnostic bounded; an incomplete list is unknown.
        guard !streams.isEmpty, streams.count <= 8 else { return nil }
        let result = streams.compactMap { stream in
            scalar(stream, selector, initial: AudioStreamBasicDescription()).flatMap(streamFormat)
        }
        return result.count == streams.count ? result : nil
    }

    static func streamFormat(_ value: AudioStreamBasicDescription) -> PlaybackAudioStreamFormat? {
        guard value.mSampleRate.isFinite, value.mSampleRate > 0, value.mSampleRate <= 3_072_000,
              (1...64).contains(value.mChannelsPerFrame), value.mBitsPerChannel <= 64,
              value.mBytesPerFrame <= 4096 else { return nil }
        let bytes = [24, 16, 8, 0].map { UInt8((value.mFormatID >> $0) & 0xff) }
        // No driver-provided strings or identifiers enter this record.
        let identifier = bytes.allSatisfy { (32...126).contains($0) }
            ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08X", value.mFormatID)
        return .init(formatID: identifier, sampleRate: value.mSampleRate,
                     channels: Int(value.mChannelsPerFrame), bitsPerChannel: Int(value.mBitsPerChannel),
                     bytesPerFrame: Int(value.mBytesPerFrame), flags: value.mFormatFlags)
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var property = address(selector, scope)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0) }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let value = scalar(object, selector, initial: Optional<CFString>.none), let value else { return nil }
        return value as String
    }

    private static func data(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Data? {
        var property = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size <= 65_536 else { return nil }
        if size == 0 { return Data() }
        var result = Data(count: Int(size))
        let capacity = size
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= capacity else { return nil }
        return result.prefix(Int(size))
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T]? {
        guard let bytes = data(object, selector, scope: scope), bytes.count % MemoryLayout<T>.stride == 0 else { return nil }
        return bytes.withUnsafeBytes { buffer in
            stride(from: 0, to: bytes.count, by: MemoryLayout<T>.stride).map { buffer.loadUnaligned(fromByteOffset: $0, as: T.self) }
        }
    }

    private static func preferredChannels(_ device: AudioObjectID) -> [String]? {
        guard var bytes = data(device, kAudioDevicePropertyPreferredChannelLayout, scope: output), bytes.count >= 12 else { return nil }
        let tag = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if tag != kAudioChannelLayoutTag_UseChannelDescriptions {
            var input = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: tag == kAudioChannelLayoutTag_UseChannelBitmap ? 4 : 0, as: UInt32.self) }
            let property = tag == kAudioChannelLayoutTag_UseChannelBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(property, 4, &input, &size) == noErr, size >= 12, size <= 65_536 else { return nil }
            bytes = Data(count: Int(size))
            let capacity = size
            let status = bytes.withUnsafeMutableBytes { AudioFormatGetProperty(property, 4, &input, &size, $0.baseAddress!) }
            guard status == noErr, size <= capacity, size >= 12 else { return nil }
            bytes = bytes.prefix(Int(size))
        }
        return channelNames(layoutData: bytes)
    }

    /// Explicit labels preserve order; unknown/discrete channels stay unknown.
    static func channelNames(layoutData bytes: Data) -> [String]? {
        guard bytes.count >= 12 else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        guard count > 0, count <= 64, bytes.count >= 12 + count * MemoryLayout<AudioChannelDescription>.stride else { return nil }
        let labels: [UInt32: String] = [1: "FL", 2: "FR", 3: "FC", 4: "LFE", 5: "BL", 6: "BR",
                                      7: "FLC", 8: "FRC", 9: "BC", 10: "SL", 11: "SR", 33: "SDL", 34: "SDR",
                                      13: "TFL", 15: "TFR", 16: "TBL", 18: "TBR", 49: "TSL", 51: "TSR", 52: "TBL", 54: "TBR"]
        var names = bytes.withUnsafeBytes { buffer in
            (0..<count).map { labels[buffer.loadUnaligned(fromByteOffset: 12 + $0 * MemoryLayout<AudioChannelDescription>.stride, as: UInt32.self)] ?? "unknown" }
        }
        // Same CoreAudio rear-layout normalization as bundled mpv 0.41.0.
        if Set(["FL", "FR", "BL", "BR", "SDL", "SDR"]).isSubset(of: Set(names)) {
            names = names.map { ["BL": "SL", "BR": "SR", "SDL": "BL", "SDR": "BR"][$0] ?? $0 }
        }
        return names
    }

    private static func transport(_ raw: UInt32?) -> PlaybackAudioOutputDevice.Transport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate: .aggregate
        default: .other
        }
    }
}
