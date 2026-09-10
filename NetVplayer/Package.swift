// swift-tools-version: 6.0
import PackageDescription
import Foundation

let includesPrivateLegacyProviders = FileManager.default.fileExists(
    atPath: "Sources/SpiderEngine/LegacyNativeProviderRegistration.swift"
)
let privateLegacyProviderSettings: [SwiftSetting] = includesPrivateLegacyProviders
    ? [.define("NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS")]
    : []

let package = Package(
    name: "NetVplayer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NetVplayerApp", targets: ["NetVplayerApp"]),
        .library(name: "ProviderSDK", targets: ["ProviderSDK"]),
        .library(name: "ProviderRuntime", targets: ["ProviderRuntime"]),
        .executable(name: "ProviderPackageTool", targets: ["ProviderPackageTool"]),
        .executable(name: "ProviderSandboxLauncher", targets: ["ProviderSandboxLauncher"]),
    ],
    dependencies: [
        // 网络框架 — 用于本地 HTTP 代理服务器
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // HTML 解析 — 用于 JS 宿主 API (jsp.pdfa/pdfh/pd)
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        // 阿里云盘网页 API 设备会话签名
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.2"),
    ],
    targets: [
        // ═══════════════════════════════════════════
        // 层级 0: 无依赖 — 可完全并行开发
        // ═══════════════════════════════════════════
        .target(
            name: "Models",
            path: "Sources/Models"
        ),
        .target(
            name: "Networking",
            path: "Sources/Networking"
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
            dependencies: ["Models", "ApplicationCore"],
            path: "Sources/Storage"
        ),
        .target(
            name: "ConfigEngine",
            dependencies: ["Models", "Networking", "Storage", "NodeBundleRuntime"],
            path: "Sources/ConfigEngine"
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
            dependencies: ["Models", "Networking", "DriveEngine", "ProxyServer", "MPVShim"],
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
                "Models",
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
                "WebHomeEngine",
            ],
            path: "Sources/NetVplayerApp",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/ThemeBackgrounds")
            ],
            swiftSettings: privateLegacyProviderSettings,
            linkerSettings: [
                .linkedFramework("WebKit"),
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
            name: "ModelsTests",
            dependencies: ["Models"],
            path: "Tests/ModelsTests"
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
            dependencies: ["ProviderRuntime", "ProviderSDK", "Models", "SpiderEngine", "DriveEngine"],
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
                "WebHomeEngine"
            ],
            path: "Tests/ConfigEngineTests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
