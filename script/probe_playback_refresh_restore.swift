// Explicit AV-11 ordinary mode-switch experiment. Never used by product playback.
// No QMS, HDR, chroma, fade suppression, persistent configuration or private APIs.
import AppKit
import Foundation
import IOKit.graphics

struct Mode: Codable, Equatable {
    let widthPoints: Int
    let heightPoints: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let rate: Double
    let flags: UInt32
    init(_ mode: CGDisplayMode) {
        widthPoints = mode.width; heightPoints = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        rate = mode.refreshRate; flags = mode.ioFlags
    }
    func sameGeometry(_ other: Mode) -> Bool {
        widthPoints == other.widthPoints && heightPoints == other.heightPoints &&
        pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }
}
struct Report: Encodable {
    let scope = "Ordinary app-lifetime CoreGraphics display-mode switch; API times are not physical blackout measurements or QMS evidence"
    let before: Mode
    var requested: Mode?
    var during: Mode?
    var after: Mode?
    var switchResult: Int32?
    var restoreResult: Int32?
    var switchAPIMilliseconds: Double?
    var restoreAPIMilliseconds: Double?
    var error: String?
    var externalChangePreserved = false
    let physicalBlackoutMilliseconds: Double? = nil
    let transportChroma: String? = nil
    let receiverDynamicRange: String? = nil
    let qmsVerified = false
}
func change(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) -> CGError {
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let config else { return begin }
    let prepare = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
    guard prepare == .success else { CGCancelDisplayConfiguration(config); return prepare }
    return CGCompleteDisplayConfiguration(config, .forAppOnly)
}
func save(_ report: Report, to path: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
}
let args = CommandLine.arguments
guard let screen = NSScreen.main,
      let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
      let original = CGDisplayCopyDisplayMode(id) else { fatalError("No display") }
var report = Report(before: Mode(original))
if args.count == 2 && args[1] == "--status" {
    print(String(decoding: try JSONEncoder().encode(report.before), as: UTF8.self))
} else {
    guard args.count == 5, args[1] == "--execute-ordinary-switch", let rate = Double(args[2]),
          [24.0, 25, 30, 50, 60].contains(rate), ["restore", "terminate", "hold"].contains(args[3]),
          !FileManager.default.fileExists(atPath: args[4]) else { fatalError("Explicit rate, completion mode and new report path required") }
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    guard CGDisplayIsInMirrorSet(id) == 0,
          let selected = modes.first(where: { $0.isUsableForDesktopGUI() && Mode($0).sameGeometry(report.before) &&
              ($0.ioFlags & ~UInt32(kDisplayModeDefaultFlag)) == (original.ioFlags & ~UInt32(kDisplayModeDefaultFlag)) &&
              abs($0.refreshRate - rate) < 0.001 }),
          abs(rate - original.refreshRate) > 0.001 else { fatalError("No same-geometry/flags alternative; no change made") }
    report.requested = Mode(selected)
    let started = ProcessInfo.processInfo.systemUptime
    let result = change(id, selected)
    report.switchAPIMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
    report.switchResult = result.rawValue
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    report.during = CGDisplayCopyDisplayMode(id).map(Mode.init)
    if result != .success { report.error = "CoreGraphics rejected ordinary mode switch" }
    try save(report, to: args[4])
    // The parent can SIGKILL 'hold' to observe app-lifetime restoration. A
    // bounded fallback still restores explicitly if the parent disappears.
    if args[3] == "terminate" { exit(result == .success ? 0 : 1) }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: args[3] == "hold" ? 15 : 2))
    let current = CGDisplayCopyDisplayMode(id).map(Mode.init)
    if current == report.requested {
        let restoreStart = ProcessInfo.processInfo.systemUptime
        report.restoreResult = change(id, original).rawValue
        report.restoreAPIMilliseconds = (ProcessInfo.processInfo.systemUptime - restoreStart) * 1000
    } else if current != report.before {
        report.externalChangePreserved = true
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    report.after = CGDisplayCopyDisplayMode(id).map(Mode.init)
    try save(report, to: args[4])
    exit(report.after == report.before && report.error == nil ? 0 : 1)
}
