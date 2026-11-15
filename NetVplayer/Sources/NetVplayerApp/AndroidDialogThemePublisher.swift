import Foundation
import SpiderEngine

enum AndroidDialogThemePublisher {
    /// Only public appearance tokens cross this boundary. No dialog text,
    /// account state or source configuration is written to this file.
    static func publish(_ palette: AppThemePalette) {
        guard let archive = Bundle.module.url(forResource: "android-presentation", withExtension: "jar",
                                               subdirectory: "AndroidPresentation") else { return }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("NetVplayer/Presentation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let theme = directory.appendingPathComponent("android-theme.properties")
            let tokens: [(String, UInt32)] = [
                ("background", palette.backgroundHex), ("surface", palette.surfaceHex),
                ("foreground", palette.foregroundHex), ("muted", palette.mutedHex),
                ("accent", palette.primaryAccentHex), ("secondaryAccent", palette.secondaryAccentHex),
                ("onAccent", palette.hex(for: .onAccent))
            ]
            let data = Data(tokens.map { "\($0.0)=\(String(format: "%06X", $0.1))\n" }.joined().utf8)
            if (try? Data(contentsOf: theme)) != data { try data.write(to: theme, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: theme.path)
            AndroidDialogPresentation.configure(.init(archive: archive, theme: theme,
                darkAppearance: palette.preferredColorScheme == .dark))
        } catch {
            print("[ANDROID_PRESENTATION] Theme publication unavailable: \(type(of: error))")
        }
    }
}
