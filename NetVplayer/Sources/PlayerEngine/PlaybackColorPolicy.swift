import Foundation
import Models
import Storage

/// The decoder retains responsibility for matrix, levels, primaries and transfer
/// metadata (including its documented fallback for untagged frames). The host
/// fixes an SDR destination; it never relabels PQ/HLG pixels as SDR.
public enum PlaybackColorPolicy {
    /// AV-03 laboratory signal: linear BT.709, 1.0 = 203 signal nits.
    /// 1000 is a test target, never a claim about the attached SDR monitor.
    /// ColorSync converts the extended-linear tagged Metal layer at display.
    static let hdrPrototypeOptions = [
        "target-prim": "bt.709", "target-trc": "linear", "target-peak": "1000",
        "icc-profile-auto": "no", "icc-profile": "", "dither-depth": "no",
        "fbo-format": "rgba32f", "tone-mapping": "clip", "tone-mapping-param": "1",
        "gamut-mapping-mode": "clip"
    ]

    public static let maximumICCBytes = 4 * 1_024 * 1_024
    public static let defaultPeakNits = 203
    static let curves = Set(["bt.2390", "mobius", "reinhard", "hable", "clip", "linear", "gamma"])

    static func options(source: [String: String], preference: PlaybackColorPreference) -> [String: MPVEffectiveOption] {
        var result: [String: MPVEffectiveOption] = [
            "tone-mapping": .init(value: "bt.2390", origin: .colorDefault),
            "tone-mapping-param": .init(value: "default", origin: .colorDefault),
            "target-peak": .init(value: String(defaultPeakNits), origin: .colorDefault)
        ]
        if let curve = source["tone-mapping"], curves.contains(curve) {
            result["tone-mapping"] = .init(value: curve, origin: .source)
            if let parameter = source["tone-mapping-param"],
               parameter == "default" || validParameter(parameter, curve: curve) {
                result["tone-mapping-param"] = .init(value: parameter, origin: .source)
            }
        }
        if let text = source["target-peak"], let peak = Int(text), (80...203).contains(peak) {
            result["target-peak"] = .init(value: text, origin: .source)
        }
        if let curve = preference.toneMapping {
            result["tone-mapping"] = .init(value: curve.rawValue, origin: .user)
            result["tone-mapping-param"] = .init(value: "default", origin: .user)
        }
        if let peak = preference.peakNits {
            result["target-peak"] = .init(value: String(min(203, max(80, peak))), origin: .user)
        }
        if result["tone-mapping-param"]?.value == "default" {
            // The bundled 0.41 property API rejects the CLI's "default" token.
            let parameter: String
            switch result["tone-mapping"]?.value {
            case "mobius": parameter = "0.3"
            case "reinhard": parameter = "0.5"
            case "gamma": parameter = "1.8"
            default: parameter = "1"
            }
            result["tone-mapping-param"] = .init(value: parameter, origin: result["tone-mapping-param"]!.origin)
        }
        // GL_RGBA8 cannot carry HDR. ICC replaces the fallback primaries/TRC;
        // the same destination color space must tag the AppKit surface.
        for (key, value) in [
            "target-prim": "bt.709", "target-trc": "srgb", "video-output-levels": "full",
            "icc-profile": "", "icc-profile-auto": "yes", "icc-intent": "1",
            // Use the explicit zero-black BT.1886 reference. Profile-derived
            // source black points can become negative in lcms' RGB conversion,
            // producing NaN curves even for the system sRGB profile.
            "icc-force-contrast": "inf",
            "icc-3dlut-size": "129x129x129", "icc-cache": "no",
            "hdr-compute-peak": "no", "gamut-mapping-mode": "desaturate",
            "blend-subtitles": "no", "target-colorspace-hint": "no",
            "tone-mapping-max-boost": "1"
        ] {
            result[key] = .init(value: value, origin: .display)
        }
        return result
    }

    private static func validParameter(_ text: String, curve: String) -> Bool {
        guard let value = Double(text), value.isFinite else { return false }
        // Endpoints can divide by zero in vo_gpu's Mobius/Reinhard/gamma
        // shaders. Untunable curves retain their explicit default parameter.
        switch curve {
        case "mobius": return value >= 0 && value < 1
        case "reinhard": return value > 0 && value < 1
        case "gamma", "clip", "linear": return value > 0 && value <= 10
        default: return false
        }
    }

    static let managedNames = Set(options(source: [:], preference: .init()).keys)

    /// Reject truncated, non-RGB and oversized blobs before crossing the C ABI.
    static func validICC(_ data: Data) -> Bool {
        guard data.count >= 128, data.count <= maximumICCBytes,
              data[36..<40] == Data("acsp".utf8), data[16..<20] == Data("RGB ".utf8) else { return false }
        let size = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return size == data.count
    }
}

public enum PlaybackICCSubmission: String, Codable, Sendable {
    case display, sRGBFallback, unavailable

    public var description: String {
        switch self {
        case .display: L10n.text("显示器 ICC（已提交）")
        case .sRGBFallback: L10n.text("sRGB 后备 ICC（已提交）")
        case .unavailable: L10n.text("ICC 不可用，使用 sRGB 后备")
        }
    }
}
