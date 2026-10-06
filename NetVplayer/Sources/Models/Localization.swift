import Foundation

public enum AppLanguageMode: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
}

/// Only application-owned copy is passed here. Provider content and persisted IDs
/// remain unchanged. The selected language is fixed for the lifetime of a process.
public enum L10n {
    public static let preferenceKey = "uiLanguage.v1"
    // SwiftPM's generated accessor checks the app root, then its build directory.
    // Installed apps package these resources in Contents/Resources instead.
    private static let resourceBundle = packagedResourceBundle(in: .main) ?? Bundle.module

    static func packagedResourceBundle(in applicationBundle: Bundle) -> Bundle? {
        applicationBundle.url(forResource: "NetVplayer_Models", withExtension: "bundle")
            .flatMap(Bundle.init(url:))
    }

    public static func resolvedLanguage(mode: String?, preferred: [String]) -> String {
        if mode == AppLanguageMode.english.rawValue { return "en" }
        if mode == AppLanguageMode.simplifiedChinese.rawValue { return "zh-Hans" }
        return preferred.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    public static let language: String = {
        if TestRuntime.isRunning { return "zh-Hans" }
        return resolvedLanguage(mode: UserDefaults.standard.string(forKey: preferenceKey), preferred: Locale.preferredLanguages)
    }()
    public static var locale: Locale { Locale(identifier: language) }

    public static func text(_ key: String, _ arguments: [String] = [], language: String? = nil) -> String {
        let language = language ?? Self.language
        let localization = resourceBundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        } ?? language
        let bundle = resourceBundle.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:)) ?? resourceBundle
        let template = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        let result = NSMutableString(string: template)
        guard let pattern = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#) else {
            return template
        }
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let range = Range(match.range(at: 1), in: template), let index = Int(template[range]), arguments.indices.contains(index) else { continue }
            result.replaceCharacters(in: match.range, with: arguments[index])
        }
        return result as String
    }
}
