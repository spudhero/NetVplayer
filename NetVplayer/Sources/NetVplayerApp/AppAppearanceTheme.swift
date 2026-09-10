import SwiftUI

enum AppAppearanceThemeID: String, CaseIterable, Codable, Identifiable, Sendable {
    case legacyDeepSpace = "legacy-deep-space"
    case auroraViolet = "aurora-violet"
    case crimsonPetals = "crimson-petals"
    case deepSea = "deep-sea"
    case coralDusk = "coral-dusk"
    case glacierBloom = "glacier-bloom"
    case orangeSea = "orange-sea"
    case mintLemon = "mint-lemon"
    case blushSky = "blush-sky"
    case lemonSummer = "lemon-summer"
    case seaSalt = "sea-salt"
    case greenPeachBlush = "green-peach-blush"
    case caramelSunrise = "caramel-sunrise"
    case monochromeFlow = "monochrome-flow"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .legacyDeepSpace: return "深空青蓝"
        case .auroraViolet: return "极光紫蓝"
        case .crimsonPetals: return "赤夜飞花"
        case .deepSea: return "深海青绿"
        case .coralDusk: return "晚霞珊瑚"
        case .glacierBloom: return "冰川蓝粉"
        case .orangeSea: return "暮海橙光"
        case .mintLemon: return "青柠薄荷"
        case .blushSky: return "晴空花雾"
        case .lemonSummer: return "柠黄初夏"
        case .seaSalt: return "海盐蓝雾"
        case .greenPeachBlush: return "青桃初绯"
        case .caramelSunrise: return "焦糖橙曦"
        case .monochromeFlow: return "玄白流光"
        }
    }

    var symbolName: String {
        switch self {
        case .legacyDeepSpace: return "moon.stars"
        case .auroraViolet: return "sparkles"
        case .crimsonPetals: return "paintbrush.pointed.fill"
        case .deepSea: return "water.waves"
        case .coralDusk: return "sun.horizon"
        case .glacierBloom: return "snowflake"
        case .orangeSea: return "sunset"
        case .mintLemon: return "leaf"
        case .blushSky: return "cloud.sun"
        case .lemonSummer: return "sun.max"
        case .seaSalt: return "drop"
        case .greenPeachBlush: return "leaf.circle"
        case .caramelSunrise: return "cup.and.saucer.fill"
        case .monochromeFlow: return "waveform.path"
        }
    }
}

enum AppAppearanceDefaults {
    static let releaseDefaultThemeID: AppAppearanceThemeID = .auroraViolet

    static func resolvedThemeID(storedRawValue: String?) -> AppAppearanceThemeID {
        guard let storedRawValue else { return releaseDefaultThemeID }
        return AppAppearanceThemeID(rawValue: storedRawValue) ?? .legacyDeepSpace
    }
}

enum AppThemeTone: String, CaseIterable, Sendable {
    case light
    case dark

    var preferredColorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}

enum AppBackgroundMode: Equatable, Sendable {
    case solidTranslucent
    case diffuseTranslucent
    case opaque
}

enum AppSurfaceRole: CaseIterable, Sendable {
    case chrome
    case panel
    case control
    case raised
}

enum AppSemanticColorRole: CaseIterable, Sendable {
    case background
    case surface
    case primaryText
    case secondaryText
    case primaryAction
    case secondaryAccent
    case neutralIcon
    case onAccent
    case disabled
    case focusRing
    case loading
    case scrollbarThumb
    case scrollbarTrack
    case success
    case warning
    case danger
}

struct AppThemeGradientStop: Equatable, Sendable {
    let hex: UInt32
    let location: Double
}

struct AppThemeGradientVector: Equatable, Sendable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double

    var startPoint: UnitPoint { UnitPoint(x: startX, y: startY) }
    var endPoint: UnitPoint { UnitPoint(x: endX, y: endY) }
}

enum AppThemeBackdropAsset: String, Equatable, Sendable {
    case monochromeFlow = "monochrome-flow"

    var fileExtension: String { "png" }
    var subdirectory: String { "ThemeBackgrounds" }
}

enum AppThemeFieldKind: String, CaseIterable, Equatable, Sendable {
    case radial
    case ellipse
    case band
    case inkBloom
    case splatter
}

struct AppThemeField: Equatable, Sendable {
    let kind: AppThemeFieldKind
    let startHex: UInt32
    let endHex: UInt32
    let centerX: Double
    let centerY: Double
    let widthScale: Double
    let heightScale: Double
    let rotationDegrees: Double
    let opacity: Double
    let blurScale: Double
}

struct AppThemeSurfaceTokens: Equatable, Sendable {
    let primarySidebarChromeOpacity: Double
    let chromeOpacity: Double
    let panelOpacity: Double
    let controlOpacity: Double
    let raisedOpacity: Double
    let selectionPrimaryOpacity: Double
    let selectionSecondaryOpacity: Double
    let selectionBorderOpacity: Double
    let borderOpacity: Double
    let shadowOpacity: Double

    func opacity(for role: AppSurfaceRole, reduceTransparency: Bool) -> Double {
        if reduceTransparency {
            switch role {
            case .chrome: return 0.92
            case .panel: return 0.96
            case .control: return 0.90
            case .raised: return 1.0
            }
        }

        switch role {
        case .chrome: return chromeOpacity
        case .panel: return panelOpacity
        case .control: return controlOpacity
        case .raised: return raisedOpacity
        }
    }
}

struct AppThemePalette: Equatable, Sendable {
    static let fixedDarkForegroundHex: UInt32 = 0xEFF2F6
    static let darkSuccessHex: UInt32 = 0x34C759
    static let darkWarningHex: UInt32 = 0xFF9F0A
    static let darkDangerHex: UInt32 = 0xFF7B72
    static let lightSuccessHex: UInt32 = 0x1C7C38
    static let lightWarningHex: UInt32 = 0x8A5A00
    static let lightDangerHex: UInt32 = 0xC41230

    let id: AppAppearanceThemeID
    let tone: AppThemeTone
    let backgroundStops: [AppThemeGradientStop]
    let gradientVector: AppThemeGradientVector
    let surfaceHex: UInt32
    let foregroundHex: UInt32
    let mutedHex: UInt32
    let primaryAccentHex: UInt32
    let secondaryAccentHex: UInt32
    let baseOpacity: Double
    let surfaceTokens: AppThemeSurfaceTokens
    let backdropAsset: AppThemeBackdropAsset?
    let fields: [AppThemeField]

    var backgroundMode: AppBackgroundMode {
        backgroundStops.count == 1 && fields.isEmpty && backdropAsset == nil
            ? .solidTranslucent
            : .diffuseTranslucent
    }

    func effectiveBackgroundMode(
        reduceTransparency: Bool,
        forceOpaque: Bool
    ) -> AppBackgroundMode {
        reduceTransparency || forceOpaque ? .opaque : backgroundMode
    }

    var desktopTransmission: Double { 1 - baseOpacity }
    var backgroundHex: UInt32 { backgroundStops.first?.hex ?? 0 }
    var preferredColorScheme: ColorScheme { tone.preferredColorScheme }

    var background: Color { Color(appHex: backgroundHex) }
    var surface: Color { Color(appHex: surfaceHex) }
    var foreground: Color { Color(appHex: foregroundHex) }
    var muted: Color { Color(appHex: mutedHex) }
    var accent: Color { Color(appHex: primaryAccentHex) }
    var lavender: Color { Color(appHex: secondaryAccentHex) }

    func surfaceOpacity(
        for role: AppSurfaceRole,
        reduceTransparency: Bool = false
    ) -> Double {
        surfaceTokens.opacity(for: role, reduceTransparency: reduceTransparency)
    }

    func hex(for role: AppSemanticColorRole) -> UInt32 {
        switch role {
        case .background: return backgroundHex
        case .surface: return surfaceHex
        case .primaryText: return foregroundHex
        case .secondaryText, .neutralIcon, .disabled: return mutedHex
        case .primaryAction, .focusRing, .loading, .scrollbarThumb, .scrollbarTrack:
            return primaryAccentHex
        case .secondaryAccent: return secondaryAccentHex
        case .onAccent:
            return Self.contrastRatio(foregroundHex, primaryAccentHex)
                >= Self.contrastRatio(backgroundHex, primaryAccentHex)
                ? foregroundHex
                : backgroundHex
        case .success:
            return tone == .light ? Self.lightSuccessHex : Self.darkSuccessHex
        case .warning:
            return tone == .light ? Self.lightWarningHex : Self.darkWarningHex
        case .danger:
            return tone == .light ? Self.lightDangerHex : Self.darkDangerHex
        }
    }

    func color(for role: AppSemanticColorRole) -> Color {
        let color = Color(appHex: hex(for: role))
        switch role {
        case .disabled: return color.opacity(0.42)
        case .scrollbarTrack: return color.opacity(0.14)
        default: return color
        }
    }

    static func contrastRatio(_ foreground: UInt32, _ background: UInt32) -> Double {
        let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
        let darker = min(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ hex: UInt32) -> Double {
        func component(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * component(16)) + (0.7152 * component(8)) + (0.0722 * component(0))
    }
}

enum AppThemeCatalog {
    static let lightThemeIDs: [AppAppearanceThemeID] = [
        .blushSky,
        .mintLemon,
        .lemonSummer,
        .greenPeachBlush,
        .seaSalt,
        .orangeSea,
    ]

    static let darkThemeIDs: [AppAppearanceThemeID] = [
        .auroraViolet,
        .crimsonPetals,
        .legacyDeepSpace,
        .deepSea,
        .coralDusk,
        .glacierBloom,
        .caramelSunrise,
        .monochromeFlow,
    ]

    static let palettes: [AppAppearanceThemeID: AppThemePalette] = [
        .legacyDeepSpace: palette(
            id: .legacyDeepSpace,
            tone: .dark,
            backgrounds: [(0x02050D, 0), (0x091A35, 0.52), (0x0B3544, 1)],
            vector: (0, 0, 1, 1),
            surface: 0x172A3B,
            foreground: 0xF1F6FA,
            muted: 0xA9BCC9,
            primary: 0x7EA6FF,
            secondary: 0xE3C36C,
            baseOpacity: 0.82,
            fields: [
                field(.band, 0x174D86, 0x43A8C7, 0.50, 0.46, 1.45, 0.26, -20, 0.38, 0.06),
                field(.radial, 0xE3C36C, 0xE3C36C, 0.82, 0.18, 0.32, 0.32, 0, 0.35, 0.08),
            ]
        ),
        .auroraViolet: palette(
            id: .auroraViolet,
            tone: .dark,
            backgrounds: [(0x080411, 0), (0x241045, 0.48), (0x072934, 1)],
            vector: (0, 0, 1, 1),
            surface: 0x2A2241,
            foreground: 0xF7F2FF,
            muted: 0xB8ACCF,
            primary: 0x54CFEF,
            secondary: 0xA77BFF,
            baseOpacity: 0.80,
            fields: [
                field(.band, 0x5723B8, 0xB06BFF, 0.32, 0.50, 0.32, 1.55, -10, 0.55, 0.065),
                field(.band, 0x08A6C5, 0x5DE3F2, 0.75, 0.50, 0.18, 1.45, 8, 0.50, 0.055),
                field(.band, 0xA12A85, 0x6A24B9, 0.04, 0.62, 0.22, 1.35, -4, 0.34, 0.10),
            ]
        ),
        .crimsonPetals: palette(
            id: .crimsonPetals,
            tone: .dark,
            backgrounds: [(0x020101, 0), (0x43000B, 0.31), (0x0A0103, 0.64), (0x010101, 1)],
            vector: (0.04, 0, 0.96, 1),
            surface: 0x261116,
            foreground: 0xFFF4F2,
            muted: 0xC9AAA7,
            primary: 0xFF6262,
            secondary: 0xD9B1A7,
            baseOpacity: 0.80,
            fields: [
                field(.radial, 0x62000D, 0x340006, 0.50, 0.50, 1.05, 1.05, 0, 0.28, 0.15),
                field(.inkBloom, 0x61000C, 0xF3262E, 0.50, 0.50, 0.98, 0.90, -2, 0.96, 0.0005),
                field(.splatter, 0x78000F, 0xFF3038, 0.52, 0.50, 1.03, 0.93, -4, 0.46, 0.0005),
            ]
        ),
        .deepSea: palette(
            id: .deepSea,
            tone: .dark,
            backgrounds: [(0x031612, 0), (0x074137, 0.56), (0x071E2E, 1)],
            vector: (0.15, 0, 1, 0.90),
            surface: 0x153B36,
            foreground: 0xEEFFFB,
            muted: 0xA1C8BE,
            primary: 0x25BBA6,
            secondary: 0x78A9FF,
            baseOpacity: 0.80,
            fields: [
                field(.band, 0x08766B, 0x32D0B5, 0.42, 0.42, 1.34, 0.30, -24, 0.48, 0.08),
                field(.ellipse, 0x1D6D9B, 0x1D6D9B, 0.70, 0.94, 1.20, 0.62, 0, 0.36, 0.14),
            ]
        ),
        .coralDusk: palette(
            id: .coralDusk,
            tone: .dark,
            backgrounds: [(0x1B0710, 0), (0x4A122A, 0.58), (0x2E0D38, 1)],
            vector: (0, 1, 1, 0),
            surface: 0x452431,
            foreground: 0xFFF4F6,
            muted: 0xD3ABB5,
            primary: 0xF46E94,
            secondary: 0xFFB36B,
            baseOpacity: 0.80,
            fields: [
                field(.radial, 0xEE376D, 0xEE376D, 0.86, 0.14, 0.92, 0.92, 0, 0.52, 0.13),
                field(.ellipse, 0xFF9C51, 0xFF9C51, 0.08, 0.88, 0.72, 0.58, -12, 0.42, 0.12),
            ]
        ),
        .glacierBloom: palette(
            id: .glacierBloom,
            tone: .dark,
            backgrounds: [(0x031522, 0), (0x0A3555, 0.52), (0x312642, 1)],
            vector: (0, 0.5, 1, 0.5),
            surface: 0x1A3046,
            foreground: 0xF3FAFF,
            muted: 0xAFC3D4,
            primary: 0x87C7FF,
            secondary: 0xF3A5C8,
            baseOpacity: 0.80,
            fields: [
                field(.band, 0x2389C4, 0x8AD8F2, 0.30, 0.42, 1.12, 0.48, -8, 0.26, 0.065),
                field(.band, 0x5874D8, 0xB26BC5, 0.55, 0.54, 1.18, 0.32, 10, 0.12, 0.075),
                field(.ellipse, 0xDF69A9, 0xFFB0CA, 0.82, 0.58, 0.78, 0.86, 0, 0.22, 0.10),
            ]
        ),
        .orangeSea: palette(
            id: .orangeSea,
            tone: .light,
            backgrounds: [
                (0xE8F9FF, 0),
                (0xC9EFF5, 0.34),
                (0xFFD6BE, 0.68),
                (0xFFF0DC, 1),
            ],
            vector: (0.5, 1, 0.5, 0),
            surface: 0xFFF9F4,
            foreground: 0x263D3A,
            muted: 0x4D645F,
            primary: 0x2F625E,
            secondary: 0x984329,
            baseOpacity: 0.70,
            fields: [
                field(.band, 0x18A9D2, 0x67CFE4, 0.50, 0.84, 1.55, 0.46, 0, 0.76, 0.045),
                field(.band, 0xF9939A, 0xFFB178, 0.50, 0.52, 1.60, 0.22, 0, 0.60, 0.035),
                field(.band, 0xFF6F3C, 0xFFAA55, 0.50, 0.16, 1.60, 0.46, 0, 0.72, 0.05),
            ]
        ),
        .mintLemon: palette(
            id: .mintLemon,
            tone: .light,
            backgrounds: [(0xF5FFD9, 0), (0xD9FFF2, 0.48), (0xFFFCE8, 1)],
            vector: (0, 0, 1, 1),
            surface: 0xFFFFFF,
            foreground: 0x17352F,
            muted: 0x526F68,
            primary: 0x0B7467,
            secondary: 0x647A10,
            baseOpacity: 0.70,
            fields: [
                field(.band, 0xBDF7D6, 0xEEFF8A, 0.38, 0.43, 1.35, 0.42, -28, 0.66, 0.055),
                field(.ellipse, 0x62DCC5, 0x62DCC5, 0.84, 0.72, 0.62, 0.78, 0, 0.38, 0.11),
            ]
        ),
        .blushSky: palette(
            id: .blushSky,
            tone: .light,
            backgrounds: [(0xFFF7FA, 0), (0xF4ECFF, 0.48), (0xDCEBFF, 1)],
            vector: (0, 1, 1, 0),
            surface: 0xFFFFFF,
            foreground: 0x2E3348,
            muted: 0x60677D,
            primary: 0x315FAE,
            secondary: 0xA44270,
            baseOpacity: 0.70,
            fields: [
                field(.band, 0xFF4F87, 0x6B8DFF, 0.52, 0.54, 1.42, 0.48, 24, 0.86, 0.055),
                field(.ellipse, 0x64B8FF, 0x64B8FF, 0.87, 0.84, 0.58, 0.70, 0, 0.56, 0.10),
            ]
        ),
        .lemonSummer: palette(
            id: .lemonSummer,
            tone: .light,
            backgrounds: [(0xFFFDEB, 0), (0xFFF2A6, 0.54), (0xF0F7C7, 1)],
            vector: (0.06, 0.05, 0.96, 0.95),
            surface: 0xFFFDF7,
            foreground: 0x353219,
            muted: 0x625E34,
            primary: 0x6F5B00,
            secondary: 0x3F6A22,
            baseOpacity: 0.70,
            fields: [
                field(.band, 0xF1D84D, 0xFFF38C, 0.50, 0.48, 1.46, 0.46, -18, 0.68, 0.065),
                field(.ellipse, 0xB7D96A, 0xB7D96A, 0.86, 0.78, 0.64, 0.72, 0, 0.36, 0.11),
            ]
        ),
        .seaSalt: palette(
            id: .seaSalt,
            tone: .light,
            backgrounds: [(0xF8FDFF, 0), (0xDCF7FF, 0.52), (0xE8EEFF, 1)],
            vector: (0, 0, 1, 1),
            surface: 0xF9FDFF,
            foreground: 0x22364D,
            muted: 0x566B82,
            primary: 0x2862A5,
            secondary: 0x0F6E74,
            baseOpacity: 0.68,
            fields: [
                field(.ellipse, 0x10BBD7, 0x10BBD7, 0.86, 0.14, 0.66, 0.58, 0, 0.70, 0.11),
                field(.ellipse, 0x3158D8, 0x3158D8, 0.16, 0.86, 0.72, 0.62, 0, 0.74, 0.12),
            ]
        ),
        .greenPeachBlush: palette(
            id: .greenPeachBlush,
            tone: .light,
            backgrounds: [
                (0xF8FBEF, 0),
                (0xF6F2E7, 0.36),
                (0xFDE7EA, 0.72),
                (0xFFE4E9, 1),
            ],
            vector: (0.04, 0.10, 0.96, 0.90),
            surface: 0xFFFDF8,
            foreground: 0x3F342B,
            muted: 0x6B5D52,
            primary: 0x876047,
            secondary: 0x8D4F66,
            baseOpacity: 0.72,
            fields: [
                field(.band, 0x9CCB7A, 0xF39AAF, 0.705, 0.085, 0.97, 0.20, 0, 0.62, 0.045),
                field(.band, 0xA4D07C, 0xEF6F92, 0.346, 0.348, 1.60, 0.20, 32, 0.72, 0.050),
                field(.band, 0xB2D993, 0xF7B5C2, 0.084, 0.448, 1.10, 0.16, 82, 0.52, 0.050),
                field(.ellipse, 0xF19AAC, 0xF8BCC7, 0.90, 0.08, 0.36, 0.30, 0, 0.42, 0.07),
                field(.ellipse, 0xED6F90, 0xF6A0AF, 0.59, 0.59, 0.66, 0.56, -10, 0.58, 0.10),
                field(.ellipse, 0xF7B7C3, 0xFAD0D5, 0.11, 0.77, 0.40, 0.46, 8, 0.34, 0.10),
            ]
        ),
        .caramelSunrise: palette(
            id: .caramelSunrise,
            tone: .dark,
            backgrounds: [
                (0x1D0804, 0),
                (0x431208, 0.34),
                (0x682109, 0.72),
                (0x7A2B0C, 1),
            ],
            vector: (0.5, 0, 0.5, 1),
            surface: 0x241109,
            foreground: 0xFFF5EB,
            muted: 0xDCC1AA,
            primary: 0xFFDDBB,
            secondary: 0xFFC27A,
            baseOpacity: 1.0,
            fields: [
                field(.band, 0xB63E00, 0xFF8A00, 0.52, 0.91, 1.55, 0.18, -2, 0.82, 0.030),
                field(.ellipse, 0xD95600, 0xFFAA08, 0.82, 0.98, 0.46, 0.28, 0, 0.58, 0.060),
            ]
        ),
        .monochromeFlow: palette(
            id: .monochromeFlow,
            tone: .dark,
            backgrounds: [(0x000000, 0), (0x000000, 1)],
            vector: (0, 0.5, 1, 0.5),
            surface: 0x101010,
            foreground: 0xFFFFFF,
            muted: 0xC7C7C7,
            primary: 0xFFFFFF,
            secondary: 0xD8D8D8,
            baseOpacity: 1.0,
            backdropAsset: .monochromeFlow,
            fields: []
        ),
    ]

    static func palette(for id: AppAppearanceThemeID) -> AppThemePalette {
        palettes[id] ?? palettes[.legacyDeepSpace]!
    }

    private static func palette(
        id: AppAppearanceThemeID,
        tone: AppThemeTone,
        backgrounds: [(UInt32, Double)],
        vector: (Double, Double, Double, Double),
        surface: UInt32,
        foreground: UInt32,
        muted: UInt32,
        primary: UInt32,
        secondary: UInt32,
        baseOpacity: Double,
        backdropAsset: AppThemeBackdropAsset? = nil,
        fields: [AppThemeField]
    ) -> AppThemePalette {
        return AppThemePalette(
            id: id,
            tone: tone,
            backgroundStops: backgrounds.map {
                AppThemeGradientStop(hex: $0.0, location: $0.1)
            },
            gradientVector: AppThemeGradientVector(
                startX: vector.0,
                startY: vector.1,
                endX: vector.2,
                endY: vector.3
            ),
            surfaceHex: surface,
            foregroundHex: foreground,
            mutedHex: muted,
            primaryAccentHex: primary,
            secondaryAccentHex: secondary,
            baseOpacity: baseOpacity,
            surfaceTokens: surfaceTokens(for: tone, themeID: id),
            backdropAsset: backdropAsset,
            fields: fields
        )
    }

    private static func surfaceTokens(
        for tone: AppThemeTone,
        themeID: AppAppearanceThemeID
    ) -> AppThemeSurfaceTokens {
        if themeID == .monochromeFlow {
            return AppThemeSurfaceTokens(
                primarySidebarChromeOpacity: 0.86,
                chromeOpacity: 0.86,
                panelOpacity: 0.72,
                controlOpacity: 0.56,
                raisedOpacity: 0.86,
                selectionPrimaryOpacity: 0.20,
                selectionSecondaryOpacity: 0.14,
                selectionBorderOpacity: 0.52,
                borderOpacity: 0.16,
                shadowOpacity: 0.18
            )
        }

        switch tone {
        case .light:
            return AppThemeSurfaceTokens(
                primarySidebarChromeOpacity: 0.30,
                chromeOpacity: 0.26,
                panelOpacity: 0.48,
                controlOpacity: 0.32,
                raisedOpacity: 0.82,
                selectionPrimaryOpacity: 0.14,
                selectionSecondaryOpacity: 0.10,
                selectionBorderOpacity: 0.42,
                borderOpacity: 0.12,
                shadowOpacity: 0.08
            )
        case .dark:
            return AppThemeSurfaceTokens(
                primarySidebarChromeOpacity: 0.30,
                chromeOpacity: 0.30,
                panelOpacity: 0.38,
                controlOpacity: 0.24,
                raisedOpacity: 0.78,
                selectionPrimaryOpacity: 0.20,
                selectionSecondaryOpacity: 0.14,
                selectionBorderOpacity: 0.52,
                borderOpacity: 0.16,
                shadowOpacity: 0.18
            )
        }
    }

    private static func field(
        _ kind: AppThemeFieldKind,
        _ startHex: UInt32,
        _ endHex: UInt32,
        _ centerX: Double,
        _ centerY: Double,
        _ widthScale: Double,
        _ heightScale: Double,
        _ rotationDegrees: Double,
        _ opacity: Double,
        _ blurScale: Double
    ) -> AppThemeField {
        AppThemeField(
            kind: kind,
            startHex: startHex,
            endHex: endHex,
            centerX: centerX,
            centerY: centerY,
            widthScale: widthScale,
            heightScale: heightScale,
            rotationDegrees: rotationDegrees,
            opacity: opacity,
            blurScale: blurScale
        )
    }
}

private struct AppThemePaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppThemeCatalog.palette(
        for: AppAppearanceDefaults.releaseDefaultThemeID
    )
}

extension EnvironmentValues {
    var appThemePalette: AppThemePalette {
        get { self[AppThemePaletteEnvironmentKey.self] }
        set { self[AppThemePaletteEnvironmentKey.self] = newValue }
    }
}

extension Color {
    init(appHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
