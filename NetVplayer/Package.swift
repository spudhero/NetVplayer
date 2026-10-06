// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let includesPrivateLegacyProviders = FileManager.default.fileExists(
    atPath: packageDirectory
        .appendingPathComponent("Sources/SpiderEngine/LegacyNativeProviderRegistration.swift").path
)
let privateLegacyProviderSettings: [SwiftSetting] = includesPrivateLegacyProviders
    ? [.define("NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS")]
    : []

let package = Package(
    name: "NetVplayer",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NetVplayerApp", targets: ["NetVplayerApp"]),
        .library(name: "ProviderSDK", targets: ["ProviderSDK"]),
        .library(name: "ProviderRuntime", targets: ["ProviderRuntime"]),
        .executable(name: "ProviderPackageTool", targets: ["ProviderPackageTool"]),
        .executable(name: "ProviderSandboxLauncher", targets: ["ProviderSandboxLauncher"]),
        .executable(name: "DiagnosticsProbe", targets: ["DiagnosticsProbe"]),
    ],
    dependencies: [
        // 网络框架 — 用于本地 HTTP 代理服务器
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // HTML 解析 — 用于 JS 宿主 API (jsp.pdfa/pdfh/pd)
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        // 阿里云盘网页 API 设备会话签名
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(url: "https://github.com/getsentry/sentry-apple-binaries.git", exact: "9.29.0"),
        .package(url: "https://github.com/amosavian/AMSMB2.git", exact: "4.0.3"),
    ],
    targets: [
        // ═══════════════════════════════════════════
        // 层级 0: 无依赖 — 可完全并行开发
        // ═══════════════════════════════════════════
        .target(
            name: "Models",
            path: "Sources/Models",
            resources: [.process("Resources/Localization")]
        ),
        .target(
            name: "Networking",
            dependencies: ["Models"],
            path: "Sources/Networking"
        ),
        .target(
            name: "Diagnostics",
            dependencies: ["Models", .product(name: "Sentry-Static", package: "sentry-apple-binaries")],
            path: "Sources/Diagnostics"
        ),
        .executableTarget(
            name: "DiagnosticsProbe",
            dependencies: ["Diagnostics"],
            path: "Sources/DiagnosticsProbe"
        ),
        .target(
            name: "CurlTransportShim",
            path: "Sources/CurlTransportShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("curl")
            ]
        ),
        .target(
            name: "ApplicationCore",
            dependencies: ["Models"],
            path: "Sources/ApplicationCore"
        ),
        .target(
            name: "ProviderSDK",
            dependencies: ["Models"],
            path: "Sources/ProviderSDK"
        ),
        .target(
            name: "ProviderRuntime",
            dependencies: [
                "Networking",
                "ProviderSDK",
                "Models",
                "QuickJSRuntime",
                "ProxyServer",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/ProviderRuntime",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ProviderPackageTool",
            dependencies: ["ProviderRuntime", "ProviderSDK"],
            path: "Sources/ProviderPackageTool"
        ),
        .executableTarget(
            name: "ProviderSandboxLauncher",
            path: "Sources/ProviderSandboxLauncher"
        ),
        .target(
            name: "DriveEngine",
            dependencies: [
                "Models",
                "Networking",
                "Storage",
                "CurlTransportShim",
                .product(name: "P256K", package: "swift-secp256k1"),
            ],
            path: "Sources/DriveEngine"
        ),

        // ═══════════════════════════════════════════
        // 层级 1: 依赖基础层
        // ═══════════════════════════════════════════
        .target(
            name: "Storage",
            dependencies: ["Models", "ApplicationCore", "CSQLite"],
            path: "Sources/Storage",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "CSMBGuestBridge", path: "Sources/CSMBGuestBridge", exclude: ["vendor/LICENSE", "vendor/NOTICE.md"], publicHeadersPath: "include", cSettings: [.headerSearchPath("vendor")]),
        .target(
            name: "MediaLibraryEngine",
            dependencies: ["Models", "Storage", "FileServiceEngine", "Networking", .product(name: "SwiftSoup", package: "SwiftSoup")],
            path: "Sources/MediaLibraryEngine"
        ),
        .target(
            name: "ConfigEngine",
            dependencies: ["Models", "Networking", "Storage", "NodeBundleRuntime"],
            path: "Sources/ConfigEngine"
        ),
        .target(
            name: "FileServiceEngine",
            dependencies: ["Models", "Storage", "Networking", "ProxyServer", "DriveEngine", "CSMBGuestBridge",
                           .product(name: "AMSMB2", package: "AMSMB2")],
            path: "Sources/FileServiceEngine"
        ),
        .target(
            name: "NodeBundleRuntime",
            dependencies: ["Models", "Networking"],
            path: "Sources/NodeBundleRuntime"
        ),
        .target(
            name: "QuickJSRuntime",
            path: "Sources/QuickJSRuntime"
        ),
        .target(
            name: "ProxyServer",
            dependencies: [
                "Models",
                "Networking",
                "CurlTransportShim",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/ProxyServer"
        ),
        .target(
            name: "MPVShim",
            path: "Sources/MPVShim",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/opt/mpv/include"])
            ]
        ),

        // ═══════════════════════════════════════════
        // 层级 2: 依赖业务层
        // ═══════════════════════════════════════════
        .target(
            name: "SpiderEngine",
            dependencies: [
                "MediaLibraryEngine",
                "FileServiceEngine",
                "Storage",
                "Models",
                "Networking",
                "DriveEngine",
                "ProxyServer",
                "ProviderSDK",
                "ProviderRuntime",
                "NodeBundleRuntime",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/SpiderEngine",
            swiftSettings: privateLegacyProviderSettings
        ),
        // ═══════════════════════════════════════════
        // 层级 3: 独立功能模块
        // ═══════════════════════════════════════════
        .target(
            name: "ParseEngine",
            dependencies: ["Models", "Networking"],
            path: "Sources/ParseEngine"
        ),
        .target(
            name: "PlayerEngine",
            dependencies: ["Models", "Networking", "DriveEngine", "ProxyServer", "MPVShim", "Storage"],
            path: "Sources/PlayerEngine",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "LiveEngine",
            dependencies: ["Models", "Networking"],
            path: "Sources/LiveEngine"
        ),
        .target(
            name: "DanmakuEngine",
            dependencies: ["Models", "Networking", "Storage"],
            path: "Sources/DanmakuEngine"
        ),
        .target(
            name: "WebHomeEngine",
            dependencies: ["Models", "ProxyServer", "Storage"],
            path: "Sources/WebHomeEngine"
        ),

        // ═══════════════════════════════════════════
        // 层级 4: 聚合模块
        // ═══════════════════════════════════════════
        .target(name: "SubtitleEngine", dependencies: ["Models", "Networking"], path: "Sources/SubtitleEngine"),

        .target(
            name: "SearchEngine",
            dependencies: ["Models", "ApplicationCore", "SpiderEngine"],
            path: "Sources/SearchEngine"
        ),

        // ═══════════════════════════════════════════
        // App: 可执行主入口
        // ═══════════════════════════════════════════
        .executableTarget(
            name: "NetVplayerApp",
            dependencies: [
                "MediaLibraryEngine",
                "FileServiceEngine",
                "Models",
                "Diagnostics",
                "ApplicationCore",
                "Networking",
                "DriveEngine",
                "Storage",
                "ConfigEngine",
                "SpiderEngine",
                "ProxyServer",
                "ParseEngine",
                "PlayerEngine",
                "LiveEngine",
                "SearchEngine",
                "DanmakuEngine",
                "SubtitleEngine",
                "WebHomeEngine",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/NetVplayerApp",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/ThemeBackgrounds"),
                .process("Resources/Metadata")
            ],
            swiftSettings: privateLegacyProviderSettings,
            linkerSettings: [
                .linkedFramework("WebKit"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/NetVplayerApp/Info.plist"
                ])
            ]
        ),

        // ═══════════════════════════════════════════
        // 测试
        // ═══════════════════════════════════════════
        .testTarget(
            name: "FileServiceTests",
            dependencies: ["FileServiceEngine", "MediaLibraryEngine", "Models", "Storage", "ProxyServer", "SpiderEngine"],
            path: "Tests/FileServiceTests"
        ),
        .testTarget(
            name: "ModelsTests",
            dependencies: ["Models"],
            path: "Tests/ModelsTests"
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics", "Models", .product(name: "Sentry-Static", package: "sentry-apple-binaries")],
            path: "Tests/DiagnosticsTests"
        ),
        .testTarget(
            name: "ApplicationCoreTests",
            dependencies: ["ApplicationCore", "Models"],
            path: "Tests/ApplicationCoreTests"
        ),
        .testTarget(
            name: "ProviderSDKTests",
            dependencies: ["ProviderSDK", "Models"],
            path: "Tests/ProviderSDKTests"
        ),
        .testTarget(
            name: "ProviderRuntimeTests",
            dependencies: ["ProviderRuntime", "ProviderSDK", "Models", "SpiderEngine", "DriveEngine", "Networking"],
            path: "Tests/ProviderRuntimeTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "ConfigEngineTests",
            dependencies: [
                "ApplicationCore",
                "ConfigEngine",
                "NodeBundleRuntime",
                "QuickJSRuntime",
                "Models",
                "Networking",
                "SpiderEngine",
                "ProxyServer",
                "ParseEngine",
                "PlayerEngine",
                "DriveEngine",
                "LiveEngine",
                "SearchEngine",
                "NetVplayerApp",
                "Storage",
                "DanmakuEngine",
                "SubtitleEngine",
                "WebHomeEngine"
            ],
            path: "Tests/ConfigEngineTests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
