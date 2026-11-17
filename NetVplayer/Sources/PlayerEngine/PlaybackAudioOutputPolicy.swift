import Foundation
import Models
import Storage

public extension PlaybackAudioOutputMode {
    var description: String {
        switch self {
        case .automatic: L10n.text("自动（安全声道布局）")
        case .stereo: L10n.text("立体声（2.0）")
        case .surround51: L10n.text("最多 5.1 声道")
        case .surround71: L10n.text("最多 7.1 声道")
        }
    }
}

public extension PlaybackDolbyAudioMode {
    var description: String {
        switch self {
        case .automatic: L10n.text("自动（保留无损音质）")
        case .passthrough: L10n.text("开启（优先直通）")
        case .pcm: L10n.text("关闭（PCM）")
        }
    }
}

public extension PlaybackTrueHDObjectMode {
    var description: String {
        switch self {
        case .automatic: L10n.text("自动（使用原生输出）")
        case .speakers714: L10n.text("7.1.4 PCM（需要 12 声道设备）")
        case .headphones: L10n.text("耳机空间音频（固定）")
        case .trackedHeadphones: L10n.text("耳机空间音频（头部追踪）")
        }
    }
    var runtimeValue: String {
        switch self {
        case .automatic: "off"
        case .speakers714: "7.1.4"
        case .headphones: "binaural"
        case .trackedHeadphones: "tracked"
        }
    }
}

public struct PlaybackAudioOutputDevice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let transport: Transport
    public let channelCapacity: Int
    /// CoreAudio's configured speaker order, not proof of physical speakers.
    public let preferredChannels: [String]?
    public let nominalSampleRate: Double?
    public let reportedLatencySeconds: Double?
    public let bufferFrames: Int?
    /// Current HAL stream readback, never the list of supported formats.
    public var virtualFormats: [PlaybackAudioStreamFormat]? = nil
    public var physicalFormats: [PlaybackAudioStreamFormat]? = nil

    public enum Transport: String, Codable, Sendable { case builtIn, hdmi, displayPort, usb, bluetooth, virtual, aggregate, other }

    /// Virtual/aggregate drivers require a separate validated route. A local
    /// BlackHole CoreAudio open stalled inside HAL; never offer that as tested.
    public var supportsPCMSelection: Bool { transport != .virtual && transport != .aggregate }

    var surroundLayout: String? {
        guard let channels = preferredChannels, channels.count <= channelCapacity,
              Set(channels).count == channels.count else { return nil }
        switch Set(channels) {
        case Set(["FL", "FR", "FC", "LFE", "BL", "BR"]): return "5.1"
        case Set(["FL", "FR", "FC", "LFE", "SL", "SR"]): return "5.1(side)"
        case Set(["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"]): return "7.1"
          case Set(["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR"]): return "7.1.4"
        default: return nil
        }
    }
}

public struct PlaybackAudioStreamFormat: Equatable, Codable, Sendable {
    public let formatID: String
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerChannel: Int
    public let bytesPerFrame: Int
    public let flags: UInt32

    public var summary: String {
        "\(formatID) · \(String(format: "%.0f", sampleRate)) Hz · \(channels) ch · \(bitsPerChannel) bit · flags \(flags)"
    }
}

public enum PlaybackAudioRouteStatus: String, Codable, Sendable {
    case automatic, selected, unavailableFallback, failedFallback, unsupportedFallback, unsupportedDefault, checking, suspended
    public var description: String {
        switch self {
        case .automatic: L10n.text("跟随系统默认输出")
        case .selected: L10n.text("请求使用所选设备")
        case .unavailableFallback: L10n.text("所选设备不可用，暂用系统默认输出")
        case .failedFallback: L10n.text("所选设备打开失败，暂用系统默认输出")
        case .unsupportedFallback: L10n.text("虚拟或聚合设备尚未支持，暂用系统默认输出")
        case .unsupportedDefault: L10n.text("系统默认设备为未支持的虚拟或聚合设备，请选择实体音频输出")
        case .checking: L10n.text("设备信息未确认，使用安全自动输出")
        case .suspended: L10n.text("系统休眠，等待音频设备恢复")
        }
    }
}

struct PlaybackAudioOutputPlan: Equatable, Sendable {
    var device = "auto"
    var channels = "auto-safe"
    var sampleRate: Int?
    var status: PlaybackAudioRouteStatus = .automatic
    var limitedToStereo = false
    var nativeDolbyAvailable = false
    var nativeTrueHDMATAvailable = false
    var nativeDTSHDHBRAvailable = false
    var nativeDolbyEnabled = false
    var preferPassthrough = false
    var followSourceSampleRate = false
    var trueHDObjectsAvailable = false
    var trueHDObjects: PlaybackTrueHDObjectMode = .automatic
    var objectRenderingUnavailable = false

    /// The temporary sink is applied state, not a change to user preferences.
    /// Recording it ensures reconciliation writes the real AO back afterward.
    func suspendedForSystemHDR() -> Self {
        var result = self
        result.device = "null"
        return result
    }

    var options: [String: String] {
        var result = ["audio-device": device, "audio-channels": channels,
         "audio-spdif": nativeDolbyEnabled
            ? ((preferPassthrough ? "ac3,eac3,truehd,dts" : "eac3,truehd") + (nativeDTSHDHBRAvailable ? ",dts-hd" : "")) : "",
         "ao": device == "null" ? "null" : (nativeDolbyEnabled
            ? (followSourceSampleRate ? "coreaudio_exclusive,coreaudio,avfoundation" : "coreaudio_exclusive,avfoundation,coreaudio")
            : "coreaudio"),
         "coreaudio-change-physical-format": followSourceSampleRate ? "yes" : "no",
         "audio-exclusive": "no", "audio-normalize-downmix": "yes", "ad-lavc-downmix": "no", "audio-samplerate": String(sampleRate ?? 0), "audio-format": "float",
         // Keep an AO alive so a device reload can recover without reloading media.
         // The engine pauses and exposes a message if this fallback is observed.
         "audio-fallback-to-null": "yes"]
        if nativeDolbyAvailable { result["coreaudio-spdif-only"] = "yes" }
        if nativeTrueHDMATAvailable { result["coreaudio-truehd-mat"] = nativeDolbyEnabled ? "yes" : "no" }
        if nativeDTSHDHBRAvailable { result["coreaudio-dtshd-hbr"] = nativeDolbyEnabled ? "yes" : "no" }
        if trueHDObjectsAvailable {
            result["netvplayer-truehd-objects"] = trueHDObjects.runtimeValue
            // Keep orientation sampling close to presentation; never build a
            // second-long queue of PCM already rotated for an obsolete pose.
            result["ad-queue-max-secs"] = trueHDObjects == .trackedHeadphones ? "0.02" : "1"
            result["audio-buffer"] = trueHDObjects == .trackedHeadphones ? "0.05" : "0.2"
        }
        return result
    }
}

/// Recover only when a rejected compressed route stays without an AO. Missing
/// asynchronous diagnostics alone do not establish an output failure.
struct PlaybackCompressedAudioRecovery: Sendable {
    private(set) var requiresPCM = false
    private var initializationRejected = false
    private var missingOutputSince: TimeInterval?

    mutating func observeLog(prefix: String?, text: String) {
        if prefix == "ao/avfoundation", text.lowercased().contains("does not support spdif") {
            initializationRejected = true
        }
    }

    mutating func shouldRecover(audio: PlaybackDiagnostics.Audio, nativeRequested: Bool, now: TimeInterval) -> Bool {
        guard !requiresPCM, nativeRequested, initializationRejected,
              audio.inputFormat?.hasPrefix("spdif-") == true,
              audio.outputDriver == nil, audio.outputFormat == nil else {
            missingOutputSince = nil
            return false
        }
        guard let since = missingOutputSince else {
            missingOutputSince = now
            return false
        }
        guard now - since >= 1 else { return false }
        requiresPCM = true
        return true
    }
}

enum PlaybackAudioOutputPolicy {
    static let managedNames = Set(PlaybackAudioOutputPlan().options.keys).union(["coreaudio-spdif-only", "coreaudio-truehd-mat", "coreaudio-dtshd-hbr", "netvplayer-truehd-objects", "ad-queue-max-secs", "audio-buffer"])

    static func resolve(preference: PlaybackAudioOutputPreference, devices: PlaybackAudioDeviceSnapshot,
                        failedDeviceUID: String? = nil, sleeping: Bool = false,
                        nativeDolbyAvailable: Bool = false, nativeTrueHDMATAvailable: Bool = false,
                        nativeDTSHDHBRAvailable: Bool = false,
                        nativePCMSampleRateAvailable: Bool = false,
                        trueHDObjectsAvailable: Bool = false,
                        requiresPCM: Bool = false) -> PlaybackAudioOutputPlan {
        var plan = PlaybackAudioOutputPlan()
        plan.nativeDolbyAvailable = nativeDolbyAvailable
        plan.trueHDObjectsAvailable = trueHDObjectsAvailable
        plan.objectRenderingUnavailable = preference.trueHDObjects != .automatic && !trueHDObjectsAvailable
        plan.nativeTrueHDMATAvailable = nativeDolbyAvailable && nativeTrueHDMATAvailable
        plan.nativeDTSHDHBRAvailable = nativeDolbyAvailable && nativeDTSHDHBRAvailable
        plan.nativeDolbyEnabled = nativeDolbyAvailable && preference.dolbyAudio != .pcm && !requiresPCM
        plan.preferPassthrough = plan.nativeDolbyEnabled && preference.dolbyAudio == .passthrough
        plan.followSourceSampleRate = nativePCMSampleRateAvailable && preference.pcmSampleRate == .source
        if sleeping { plan.status = .suspended; return plan }
        guard devices.enumerationSucceeded else { plan.status = .checking; return plan }
        let selected = devices.outputs.first { $0.id == preference.deviceUID }
        let usable = selected?.id == failedDeviceUID || selected?.supportsPCMSelection == false ? nil : selected
        if let usable {
            plan.device = (plan.nativeDolbyEnabled ? "netvplayer/" : "coreaudio/") + usable.id
            plan.status = .selected
        } else if preference.deviceUID != nil {
            plan.status = selected?.supportsPCMSelection == false ? .unsupportedFallback
                : (preference.deviceUID == failedDeviceUID ? .failedFallback : .unavailableFallback)
        }
        let target = usable ?? devices.outputs.first { $0.id == devices.systemDefaultUID }
        if trueHDObjectsAvailable, preference.trueHDObjects != .automatic {
            if preference.trueHDObjects == .speakers714 && target?.surroundLayout != "7.1.4" {
                plan.objectRenderingUnavailable = true
            } else {
                plan.trueHDObjects = preference.trueHDObjects
                plan.nativeDolbyEnabled = false
                plan.preferPassthrough = false
                // Replace the device prefix selected for a compressed route.
                if let usable { plan.device = "coreaudio/" + usable.id }
            }
        }
        if target?.supportsPCMSelection == false {
            // Do not silently redirect to an unrelated physical device. A null
            // AO is explicit here; the engine shows the reason and pauses.
            plan.device = "null"
            plan.channels = "stereo"
            plan.status = .unsupportedDefault
            return plan
        }
        // Shared mode follows the current device clock. Source mode delegates
        // a temporary physical format change to the runtime with restoration.
        if !plan.followSourceSampleRate, let rate = target?.nominalSampleRate, rate.isFinite, rate >= 8_000, rate <= 384_000 {
            plan.sampleRate = Int(rate.rounded())
        }
        switch preference.mode {
        case .automatic: break
        case .stereo: plan.channels = "stereo"
        case .surround51, .surround71:
            // Counts alone do not establish positions. Only permit a documented
            // configured layout, and retain an explicit stereo fallback.
            switch target?.surroundLayout {
              case "7.1.4", "7.1":
                plan.channels = preference.mode == .surround71 ? "7.1,5.1,5.1(side),stereo" : "5.1,5.1(side),stereo"
            case "5.1": plan.channels = "5.1,stereo"
            case "5.1(side)": plan.channels = "5.1(side),stereo"
            default: plan.channels = "stereo"; plan.limitedToStereo = true
            }
        }
        if plan.trueHDObjects != .automatic {
            plan.channels = plan.trueHDObjects == .speakers714 ? "fl-fr-fc-lfe-bl-br-sl-sr-tfl-tfr-tbl-tbr" : "stereo"
            plan.limitedToStereo = false
        }
        return plan
    }
}
