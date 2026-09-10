import Foundation
import Testing

@Suite("Build and run packaging")
struct BuildRunPackagingTests {
    @Test
    func appVersionMetadataAndPackagingRemainAligned() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoData = try Data(contentsOf: packageRoot.appendingPathComponent("Sources/NetVplayerApp/Info.plist"))
        let info = try #require(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        let buildScript = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8
        )

        #expect(info["CFBundleShortVersionString"] as? String == "1.0.0")
        #expect(info["CFBundleVersion"] as? String == "1")
        #expect(buildScript.contains("APP_VERSION=\"$(plutil -extract CFBundleShortVersionString"))
        #expect(buildScript.contains("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
        #expect(buildScript.contains("^[1-9][0-9]*$"))
        #expect(buildScript.contains("<string>$APP_VERSION</string>"))
        #expect(!buildScript.contains("<string>0.1.0</string>"))
    }

    @Test
    func appBundleIsSignedAndVerifiedBeforeItReplacesTheInstalledBundle() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = packageRoot.appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let buildRange = try #require(script.range(of: "swift_build --product \"$APP_NAME\""))
        let stagingResetRange = try #require(
            script.range(of: "rm -rf \"$STAGING_APP_BUNDLE\"", range: buildRange.upperBound..<script.endIndex)
        )
        let verificationRange = try #require(
            script.range(
                of: "codesign --verify --deep --strict --verbose=2 \"$STAGING_APP_BUNDLE\"",
                range: stagingResetRange.upperBound..<script.endIndex
            )
        )
        let installationRange = try #require(
            script.range(of: "\ninstall_staged_app\n", range: verificationRange.upperBound..<script.endIndex)
        )
        let runtimeLicenseAuditRange = try #require(
            script.range(
                of: "package_libmpv_runtime_licenses.py\" \\",
                range: verificationRange.upperBound..<installationRange.lowerBound
            )
        )
        let releaseSBOMRange = try #require(
            script.range(
                of: "generate_release_sbom.py\" \\",
                range: runtimeLicenseAuditRange.upperBound..<installationRange.lowerBound
            )
        )
        let packagingSection = script[buildRange.lowerBound..<verificationRange.upperBound]

        #expect(stagingResetRange.lowerBound < verificationRange.lowerBound)
        #expect(verificationRange.lowerBound < runtimeLicenseAuditRange.lowerBound)
        #expect(runtimeLicenseAuditRange.lowerBound < releaseSBOMRange.lowerBound)
        #expect(releaseSBOMRange.lowerBound < installationRange.lowerBound)
        #expect(verificationRange.lowerBound < installationRange.lowerBound)
        #expect(!packagingSection.contains("rm -rf \"$APP_BUNDLE\""))
    }

    @Test
    func appBundleUsesOneSystemInstallLocationAndRemovesLegacyBuildCopies() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = packageRoot.appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let unregisterRange = try #require(script.range(of: "\"$LSREGISTER_PATH\" -u \"$obsolete_bundle\""))
        let removalRange = try #require(
            script.range(of: "rm -rf \"$obsolete_bundle\"", range: unregisterRange.upperBound..<script.endIndex)
        )

        #expect(script.contains("INSTALL_DIR=\"/Applications\""))
        #expect(script.contains("APP_BUNDLE=\"$INSTALL_DIR/$BUNDLE_NAME.app\""))
        #expect(script.contains("\"$ROOT_DIR/dist/$BUNDLE_NAME.app\""))
        #expect(script.contains("\"$REPOSITORY_ROOT/dist/$BUNDLE_NAME.app\""))
        #expect(unregisterRange.lowerBound < removalRange.lowerBound)
        #expect(!script.contains("NETVPLAYER_DIST_DIR"))
        #expect(!script.contains("NETVPLAYER_INSTALL_DIR"))
    }

    @Test
    func installedAppGetsFreshVisibleDirectoryIdentity() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = packageRoot.appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let copyRange = try #require(
            script.range(of: "/usr/bin/ditto \"$STAGING_APP_BUNDLE\" \"$APP_BUNDLE\"")
        )
        let stagingRemovalRange = try #require(
            script.range(
                of: "rm -rf \"$STAGING_APP_BUNDLE\"",
                range: copyRange.upperBound..<script.endIndex
            )
        )

        #expect(copyRange.lowerBound < stagingRemovalRange.lowerBound)
        #expect(!script.contains("mv \"$STAGING_APP_BUNDLE\" \"$APP_BUNDLE\""))
    }

    @Test
    func runtimeDockOverridePreservesTransparentPositiveBaselineBeforeFinishLaunching() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/NetVplayerApp/NetVplayerApp.swift"),
            encoding: .utf8
        )
        let script = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let iconJSON = try Data(
            contentsOf: packageRoot.appendingPathComponent("Resources/AppIcon.icon/icon.json")
        )
        let icon = try #require(JSONSerialization.jsonObject(with: iconJSON) as? [String: Any])
        let fill = try #require(icon["fill"] as? [String: String])
        let willFinishRange = try #require(appSource.range(of: "func applicationWillFinishLaunching"))
        let didFinishRange = try #require(appSource.range(of: "func applicationDidFinishLaunching"))
        let earlyLaunchRange = willFinishRange.lowerBound..<didFinishRange.lowerBound

        #expect(appSource[earlyLaunchRange].contains("applyBundledDockIcon()"))
        #expect(appSource.contains("NSApp.applicationIconImage = NetVplayerApplicationIcon.image"))
        #expect(fill["solid"]?.hasSuffix(",0.00000") == true)
        #expect(script.contains("cp \"$APP_ICON_SOURCE\" \"$APP_RESOURCES/AppIcon-Runtime.png\""))
        #expect(script.contains("<key>CFBundleIconName</key>"))
    }

    @Test
    func libmpvPackagingRecordsSourcesAndFailsClosedOnLicenseAudit() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot.deletingLastPathComponent()
        let vendorScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/vendor_libmpv.sh"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        #expect(vendorScript.contains("COPIED_SOURCE_RECORDS"))
        #expect(vendorScript.contains("--mapping \"$SOURCE_MAPPING\""))
        #expect(vendorScript.contains("--fallback-root \"$LICENSE_FALLBACK_ROOT\""))
        #expect(buildScript.contains("--app-bundle \"$STAGING_APP_BUNDLE\""))
        #expect(buildScript.contains("--audit-only"))
    }

    @Test
    func torrentBridgeInstallMustMatchTheReviewedLicenseSnapshot() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let installRange = try #require(
            buildScript.range(of: "\"$PREPARED_NODE_EXECUTABLE\" \"$NPM_CLI_PATH\" ci \\")
        )
        let loadRange = try #require(
            buildScript.range(of: "await import('webtorrent')", range: installRange.upperBound..<buildScript.endIndex)
        )
        let replacementRange = try #require(
            buildScript.range(
                of: "apply_torrent_bridge_replacements.py\" \\",
                range: installRange.upperBound..<loadRange.lowerBound
            )
        )
        let auditRange = try #require(
            buildScript.range(
                of: "audit_torrent_bridge_licenses.py\" \\",
                range: loadRange.upperBound..<buildScript.endIndex
            )
        )
        let buildRange = try #require(
            buildScript.range(of: "swift_build --product", range: auditRange.upperBound..<buildScript.endIndex)
        )

        #expect(buildScript.contains("torrent-bridge-license-audit-2026-08-18.json"))
        #expect(buildScript.contains("npm_config_cache=\"${NETVPLAYER_NPM_CACHE:-/tmp/netvplayer-npm-cache}\""))
        #expect(!buildScript.contains("NPM_CONFIG_CACHE="))
        #expect(!buildScript.contains("--allow-known-blockers"))
        #expect(buildScript.contains("cp -R \"$TORRENT_BRIDGE_SOURCE/THIRD_PARTY_LICENSES\""))
        #expect(buildScript.contains("--root \"$TORRENT_BRIDGE_SOURCE\""))
        #expect(installRange.lowerBound < replacementRange.lowerBound)
        #expect(replacementRange.lowerBound < loadRange.lowerBound)
        #expect(loadRange.lowerBound < auditRange.lowerBound)
        #expect(auditRange.lowerBound < buildRange.lowerBound)
    }

    @Test
    func appBundlesPinnedNodeAndUsesItForEveryNodeBridge() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let torrentResolver = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/SpiderEngine/WebTorrentMagnetPlaybackResolver.swift"
            ),
            encoding: .utf8
        )

        let prepareRange = try #require(buildScript.range(of: "prepare_embedded_node_runtime.py"))
        let npmRange = try #require(
            buildScript.range(
                of: "\"$PREPARED_NODE_EXECUTABLE\" \"$NPM_CLI_PATH\" ci",
                range: prepareRange.upperBound..<buildScript.endIndex
            )
        )
        let copyRange = try #require(
            buildScript.range(
                of: "cp -R \"$PREPARED_NODE_RUNTIME_ROOT\" \"$BUNDLED_NODE_RUNTIME_ROOT\"",
                range: npmRange.upperBound..<buildScript.endIndex
            )
        )
        let signRange = try #require(
            buildScript.range(
                of: "codesign --force --sign - \"$BUNDLED_NODE_EXECUTABLE\"",
                range: copyRange.upperBound..<buildScript.endIndex
            )
        )
        let verifyRange = try #require(
            buildScript.range(
                of: "codesign --verify --strict --verbose=2 \"$BUNDLED_NODE_EXECUTABLE\"",
                range: signRange.upperBound..<buildScript.endIndex
            )
        )

        #expect(buildScript.contains("BUNDLED_NODE_RUNTIME_ROOT=\"$APP_RESOURCES/NodeRuntime\""))
        #expect(buildScript.contains("NPM_CLI_PATH=\"$PREPARED_NODE_NPM_ROOT/bin/npm-cli.js\""))
        #expect(buildScript.contains("NPM_VERSION=\"$(\"$PREPARED_NODE_EXECUTABLE\" \"$NPM_CLI_PATH\" --version)\""))
        #expect(buildScript.contains("-npm$NPM_VERSION"))
        #expect(!buildScript.contains("command -v npm"))
        #expect(buildScript.contains("provider-runners/runtime-lock-v1.json"))
        #expect(prepareRange.lowerBound < npmRange.lowerBound)
        #expect(npmRange.lowerBound < copyRange.lowerBound)
        #expect(copyRange.lowerBound < signRange.lowerBound)
        #expect(signRange.lowerBound < verifyRange.lowerBound)
        #expect(torrentResolver.contains("NodeRuntimeLocator.locate("))
    }

    @Test
    func appBundlesPinnedQuickJSRuntimeAndSignsIt() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        let prepareRange = try #require(buildScript.range(of: "prepare_embedded_quickjs_runtime.py"))
        let copyRange = try #require(
            buildScript.range(
                of: "cp -R \"$PREPARED_QUICKJS_RUNTIME_ROOT\" \"$BUNDLED_QUICKJS_RUNTIME_ROOT\"",
                range: prepareRange.upperBound..<buildScript.endIndex
            )
        )
        let signRange = try #require(
            buildScript.range(
                of: "codesign --force --sign - \"$BUNDLED_QUICKJS_EXECUTABLE\"",
                range: copyRange.upperBound..<buildScript.endIndex
            )
        )
        let verifyRange = try #require(
            buildScript.range(
                of: "codesign --verify --strict --verbose=2 \"$BUNDLED_QUICKJS_EXECUTABLE\"",
                range: signRange.upperBound..<buildScript.endIndex
            )
        )

        #expect(buildScript.contains("QUICKJS_RUNTIME_LOCK=\"$REPOSITORY_ROOT/provider-runners/quickjs-runtime-lock-v1.json\""))
        #expect(buildScript.contains("BUNDLED_QUICKJS_RUNTIME_ROOT=\"$APP_RESOURCES/QuickJSRuntime\""))
        #expect(buildScript.contains("BUNDLED_QUICKJS_POLYGLOT=\"$BUNDLED_QUICKJS_RUNTIME_ROOT/bin/qjs-cosmo\""))
        #expect(buildScript.contains("BUNDLED_QUICKJS_BOOTSTRAP=\"$BUNDLED_QUICKJS_RUNTIME_ROOT/bin/.ape-1.10\""))
        #expect(buildScript.contains("codesign --force --sign - \"$BUNDLED_QUICKJS_POLYGLOT\""))
        #expect(buildScript.contains("codesign --force --sign - \"$BUNDLED_QUICKJS_BOOTSTRAP\""))
        #expect(prepareRange.lowerBound < copyRange.lowerBound)
        #expect(copyRange.lowerBound < signRange.lowerBound)
        #expect(signRange.lowerBound < verifyRange.lowerBound)
    }

    @Test
    func feedbackDestinationAndSessionLogArePackagedForSupportHandoff() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot.deletingLastPathComponent()
        let buildScript = try String(
            contentsOf: packageRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let sourceInfo = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/NetVplayerApp/Info.plist"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/NetVplayerApp/NetVplayerApp.swift"),
            encoding: .utf8
        )
        let issueForm = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/user-feedback.yml"),
            encoding: .utf8
        )
        let issueConfig = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/config.yml"),
            encoding: .utf8
        )

        #expect(sourceInfo.contains("<key>NetVplayerFeedbackRepositoryURL</key>"))
        #expect(sourceInfo.contains("https://github.com/spudhero/NetVplayer"))
        #expect(buildScript.contains("<key>NetVplayerFeedbackRepositoryURL</key>"))
        #expect(buildScript.contains("APP_DIAGNOSTIC_LOG=\"$HOME/Library/Logs/NetVplayer/current.log\""))
        #expect(buildScript.contains("tail -F \"$LOG_FILE\" \"$APP_DIAGNOSTIC_LOG\""))
        #expect(appSource.contains("Button(\"报告问题…\")"))
        #expect(appSource.contains("if visualRegressionConfiguration == nil"))
        let visualGuardRange = try #require(appSource.range(of: "if visualRegressionConfiguration == nil"))
        let diagnosticStartRange = try #require(
            appSource.range(of: "DiagnosticLog.beginSession()", range: visualGuardRange.upperBound..<appSource.endIndex)
        )
        let stateObjectRange = try #require(
            appSource.range(of: "_appState = StateObject", range: diagnosticStartRange.upperBound..<appSource.endIndex)
        )
        #expect(visualGuardRange.lowerBound < diagnosticStartRange.lowerBound)
        #expect(diagnosticStartRange.lowerBound < stateObjectRange.lowerBound)
        for identifier in ["category", "problem", "steps", "expected", "actual", "reproduction", "public_source", "attachment", "diagnostics", "privacy"] {
            #expect(issueForm.contains("id: \(identifier)"))
        }
        #expect(issueForm.contains("仅诊断资料，真实源未验证"))
        #expect(issueForm.contains("required: true"))
        #expect(issueConfig.contains("blank_issues_enabled: true"))

        let yamlValidation = Process()
        yamlValidation.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        yamlValidation.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        yamlValidation.arguments = [
            "-ryaml",
            "-e",
            "data = YAML.safe_load(File.read(ARGV[0])); ids = data.fetch('body').map { |item| item['id'] }.compact; expected = %w[category problem steps expected actual reproduction public_source attachment diagnostics privacy]; abort('invalid issue form ids') unless ids == expected && ids.uniq == ids && data['name'] == '用户问题反馈'; privacy = data.fetch('body').find { |item| item['id'] == 'privacy' }; abort('privacy confirmation must be required') unless privacy.dig('attributes', 'options', 0, 'required') == true",
            repositoryRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/user-feedback.yml").path,
        ]
        try yamlValidation.run()
        yamlValidation.waitUntilExit()
        #expect(yamlValidation.terminationStatus == 0)
    }
}
