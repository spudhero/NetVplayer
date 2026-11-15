// Read-only AV-11 display facts. No display capture, configuration, or private API.
import AppKit
import CoreVideo
import CryptoKit
import Foundation

func modeFacts(_ mode: CGDisplayMode) -> [String: Any] {
    ["logicalSizePoints": [mode.width, mode.height], "backingPixels": [mode.pixelWidth, mode.pixelHeight],
     "configuredRefreshHz": mode.refreshRate, "ioFlags": mode.ioFlags,
     "usableForDesktopGUI": mode.isUsableForDesktopGUI(),
     "transportChroma": NSNull(), "transportBitDepth": NSNull(), "receiverDynamicRange": NSNull()]
}

var displays: [[String: Any]] = []
for screen in NSScreen.screens {
    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
          let mode = CGDisplayCopyDisplayMode(id) else { continue }
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [])
    var link: CVDisplayLink?
    let status = CVDisplayLinkCreateWithCGDisplay(id, &link)
    var clock: [String: Any] = ["createStatus": status]
    let icc = screen.colorSpace?.iccProfileData
    if let link {
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        clock["nominalTimeValue"] = period.timeValue
        clock["nominalTimeScale"] = period.timeScale
        clock["nominalFlags"] = period.flags
        clock["actualPeriodSecondsBeforeStart"] = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
    }
    displays.append(["name": screen.localizedName, "currentMode": modeFacts(mode),
        "availableModes": modes.map(modeFacts), "displayLink": clock,
        "screenPoints": [screen.frame.width, screen.frame.height], "backingScale": screen.backingScaleFactor,
        "maximumFramesPerSecond": screen.maximumFramesPerSecond,
        "minimumRefreshIntervalSeconds": screen.minimumRefreshInterval,
        "maximumRefreshIntervalSeconds": screen.maximumRefreshInterval,
        "currentEDRHeadroom": screen.maximumExtendedDynamicRangeColorComponentValue,
        "potentialEDRHeadroom": screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
        "iccBytes": icc?.count as Any? ?? NSNull(),
        "iccSHA256": icc.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } as Any? ?? NSNull(),
        "isBuiltin": CGDisplayIsBuiltin(id) != 0, "isMirrored": CGDisplayIsInMirrorSet(id) != 0,
        "qmsNegotiated": NSNull(), "physicalTransport": NSNull()])
}
let report: [String: Any] = ["schema": 1, "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "displays": displays, "modeWrites": 0, "physicalBlackoutMilliseconds": NSNull(),
    "scope": "Public read-only display-mode facts. Mode, EDR and display-link periods do not prove physical signal, scanout, chroma, bit depth, HDR or QMS."]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    guard !FileManager.default.fileExists(atPath: url.path) else { fatalError("Refuse to replace prior evidence") }
    try data.write(to: url, options: .withoutOverwriting)
} else { print(String(decoding: data, as: UTF8.self)) }
