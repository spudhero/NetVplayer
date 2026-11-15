import AppKit
import CryptoKit
import ColorSync
import Foundation

func cs(_ value: Unmanaged<CFString>?) -> String { value!.takeUnretainedValue() as String }
func jsonValue(_ value: Any) -> Any {
    if let data = value as? Data { return ["dataHex": data.map { String(format: "%02x", $0) }.joined()] }
    if let dict = value as? [String: Any] { return dict.mapValues(jsonValue) }
    if let array = value as? [Any] { return array.map(jsonValue) }
    if value is String || value is NSNumber || value is NSNull { return value }
    return ["opaqueType": String(describing: type(of: value))]
}

// AV-12 read-only capture. The directory must be new; no system profile changes.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: probe manifest.json new-output-directory")
}
let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
_ = NSApplication.shared
guard let screen = NSScreen.main, let current = screen.colorSpace,
      let linearCG = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
      let linear = NSColorSpace(cgColorSpace: linearCG), let linearICC = linear.iccProfileData else {
    fatalError("No current screen or linear reference profile")
}
try linearICC.write(to: output.appendingPathComponent("linear-srgb.icc"), options: .withoutOverwriting)
var profiles: [[String: Any]] = []
for (name, space) in [("sRGB", NSColorSpace.sRGB), ("Display-P3", NSColorSpace.displayP3), ("current-display", current)] {
    guard let icc = space.iccProfileData else { fatalError("Missing ICC") }
    try icc.write(to: output.appendingPathComponent(name + ".icc"), options: .withoutOverwriting)
    let sourceProfile = ColorSyncProfileCreate(linearICC as CFData, nil)!.takeRetainedValue()
    let destinationProfile = ColorSyncProfileCreate(icc as CFData, nil)!.takeRetainedValue()
    var transforms: [(String, ColorSyncTransform)] = []
    for (qualityName, quality) in [("best", cs(kColorSyncBestQuality)), ("normal", cs(kColorSyncNormalQuality))] {
        let sequence: [[String: Any]] = [
            [cs(kColorSyncProfile): sourceProfile, cs(kColorSyncRenderingIntent): cs(kColorSyncRenderingIntentRelative),
             cs(kColorSyncTransformTag): cs(kColorSyncTransformDeviceToPCS), cs(kColorSyncBlackPointCompensation): false],
            [cs(kColorSyncProfile): destinationProfile, cs(kColorSyncRenderingIntent): cs(kColorSyncRenderingIntentRelative),
             cs(kColorSyncTransformTag): cs(kColorSyncTransformPCSToDevice), cs(kColorSyncBlackPointCompensation): false]]
        transforms.append((qualityName, ColorSyncTransformCreate(sequence as CFArray,
            [cs(kColorSyncConvertQuality): quality] as CFDictionary)!.takeRetainedValue()))
    }
    var samples: [[String: Any]] = []
    var fragments: [String: Any] = [:]
    for (quality, transform) in transforms {
        if let fragment = ColorSyncTransformCopyProperty(transform,
            kColorSyncTransformParametricConversionData!.takeUnretainedValue(), nil)?.takeRetainedValue() {
            // Public ColorSync conversion components, not a private API.
            fragments[quality] = jsonValue(fragment)
        }
    }
    for sample in manifest["samples"] as! [[String: Any]] {
        let patches = try (sample["patches"] as! [[String: Any]]).map { patch -> [String: Any] in
            let input = patch["linearSRGB"] as! [Double]
            let components = (input + [1]).map { CGFloat($0) }
            guard let color = NSColor(colorSpace: linear, components: components, count: 4).usingColorSpace(space) else {
                throw NSError(domain: "ICCReference", code: 1)
            }
            var variants: [String: [Double]] = [:]
            for (quality, transform) in transforms {
                for extended in [false, true] {
                    var source = input.map(Float.init)
                    var destination = [Float](repeating: 0, count: 3)
                    guard ColorSyncTransformConvert(transform, 1, 1, &destination, kColorSync32BitFloat,
                        ColorSyncDataLayout(kColorSyncAlphaNone.rawValue), 12, &source, kColorSync32BitFloat,
                        ColorSyncDataLayout(kColorSyncAlphaNone.rawValue), 12,
                        [cs(kColorSyncConvertUseExtendedRange): extended] as CFDictionary) else {
                        throw NSError(domain: "ColorSyncConvert", code: 1)
                    }
                    variants[quality + (extended ? "-extended" : "-bounded")] = destination.map { Double(min(1, max(0, $0))) * 255 }
                }
            }
            return ["linearSRGB": input, "referenceRGB8": [color.redComponent, color.greenComponent, color.blueComponent].map { min(1, max(0, $0)) * 255 }, "explicitColorSyncRGB8": variants]
        }
        samples.append(["file": sample["file"]!, "patches": patches])
    }
    profiles.append(["profile": name, "bytes": icc.count,
                     "sha256": SHA256.hash(data: icc).map { String(format: "%02x", $0) }.joined(),
                     "samples": samples, "colorSyncParametricFragments": fragments])
}
let report: [String: Any] = ["schema": 1, "capturedAt": ISO8601DateFormatter().string(from: Date()),
    "displayCount": NSScreen.screens.count, "profiles": profiles,
    "reference": "Unmodified AV-02 extended-linear sRGB to NSColor.usingColorSpace", "systemSettingsChanged": false]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("reference.json"), options: .withoutOverwriting)
print("Captured \(profiles.count) profiles and unchanged reference values")
