import Foundation
import AppKit
import SwiftUI
import Models
import Testing
import ProviderRuntime
import ProviderSDK
@testable import NetVplayerApp

@Suite("Provider installation presentation")
struct ProviderInstallationPresentationTests {
    private func release(_ id: String, version: String = "1.0.0") -> ProviderRelease {
        ProviderRelease(
            providerID: id, version: version, architectures: ["arm64"],
            archiveURL: URL(string: "https://providers.example.test/\(id).zip")!,
            archiveSHA256: String(repeating: "a", count: 64)
        )
    }

    @Test func catalogShowsEveryComponentBeforeDownloadAndPreservesIndependentOutcomes() throws {
        var state = ProviderInstallationPresentation()
        let shouldNavigate = state.begin(isInitialInstallation: true)
        #expect(shouldNavigate)
        let session = try #require(state.sessionID)
        #expect(state.detailsExpanded)
        #expect(state.shouldShowNetworkHint)
        #expect(state.phase == .fetchingCatalog)

        let releases = [release("first"), release("second"), release("third")]
        state.receiveCatalog(releases, installedVersions: ["third": "2.0.0"], sessionID: session)
        #expect(state.rows.map(\.status) == [.queued, .queued, .ready])
        #expect(state.readyCount == 1)
        let first = state.rows[0].id
        state.receiveProgress(ProviderInstallProgress(
            providerID: "first", version: "1.0.0", phase: .downloading,
            receivedBytes: 30, expectedBytes: 100
        ), sessionID: session)
        guard case .installing(let progress) = state.rows[0].status else {
            Issue.record("The first component should show download progress")
            return
        }
        #expect(progress.fractionCompleted == 0.3)
        state.receiveFailure(first, message: "Connection timed out", sessionID: session)
        state.receiveProgress(ProviderInstallProgress(
            providerID: "second", version: "1.0.0", phase: .completed
        ), sessionID: session)
        #expect(state.rows.map(\.status) == [.failed("Connection timed out"), .ready, .ready])
        #expect(state.readyCount == 2)
        #expect(state.phase == .installing)
        #expect(state.isInitialInstallation)
        let shouldCollapse = state.finish(succeeded: false, message: "One component failed", sessionID: session)
        #expect(!shouldCollapse)
        state.collapseAfterSuccess(sessionID: session)
        #expect(state.detailsExpanded)
        #expect(state.shouldShowNetworkHint)
    }

    @Test func downloadRetryAndUnknownSizeUseActualBytesAndVerificationIsNotCompletion() throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let session = try #require(state.sessionID)
        state.receiveCatalog([release("first")], installedVersions: [:], sessionID: session)

        for (received, expected) in [(80 as Int64, 100 as Int64?), (5, nil), (100, 100)] {
            state.receiveProgress(ProviderInstallProgress(
                providerID: "first", version: "1.0.0", phase: .downloading,
                receivedBytes: received, expectedBytes: expected
            ), sessionID: session)
            guard case .installing(let progress) = state.rows[0].status else {
                Issue.record("The component should still be downloading")
                return
            }
            #expect(progress.receivedBytes == received)
            #expect(progress.fractionCompleted == expected.map { Double(received) / Double($0) })
            #expect(state.readyCount == 0)
        }
        for phase in [ProviderInstallPhase.verifyingArchive, .extracting, .verifyingPackage, .launching] {
            state.receiveProgress(ProviderInstallProgress(
                providerID: "first", version: "1.0.0", phase: phase
            ), sessionID: session)
            guard case .installing(let progress) = state.rows[0].status else {
                Issue.record("Verification must remain in progress")
                return
            }
            #expect(progress.fractionCompleted == nil)
            #expect(state.readyCount == 0)
        }
        state.receiveProgress(ProviderInstallProgress(
            providerID: "first", version: "1.0.0", phase: .completed
        ), sessionID: session)
        state.collapseAfterSuccess(sessionID: session)
        #expect(state.phase == .installing)
        #expect(state.detailsExpanded)
        state.reconcileInstalledVersions([:], sessionID: session)
        #expect(state.readyCount == 0)
        guard case .failed = state.rows[0].status else {
            Issue.record("A component absent from final registration must not be ready")
            return
        }
    }

    @Test func successCollapsesOnlyAfterExplicitCompletionAndKeepsRows() throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let session = try #require(state.sessionID)
        state.receiveCatalog([release("first")], installedVersions: ["first": "1.0.0"], sessionID: session)
        let shouldCollapse = state.finish(succeeded: true, message: "Ready", sessionID: session)
        #expect(shouldCollapse)
        #expect(state.detailsExpanded)
        #expect(!state.shouldShowNetworkHint)
        state.collapseAfterSuccess(sessionID: session)
        #expect(!state.detailsExpanded)
        #expect(state.readyCount == 1)
    }

    @Test(arguments: [true, false])
    func manualDisclosureChoiceSurvivesCompletionAndAnotherTask(expanded: Bool) throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let session = try #require(state.sessionID)
        state.setDetailsExpanded(expanded)
        let shouldCollapse = state.finish(succeeded: true, message: "Ready", sessionID: session)
        #expect(!shouldCollapse)
        state.collapseAfterSuccess(sessionID: session)
        #expect(state.detailsExpanded == expanded)
        let shouldNavigate = state.begin(isInitialInstallation: true)
        #expect(!shouldNavigate)
        #expect(state.detailsExpanded == expanded)
    }

    @Test func staleProgressAndCollapseCannotModifyANewTask() throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let oldSession = try #require(state.sessionID)
        state.finish(succeeded: true, message: "Ready", sessionID: oldSession)
        let shouldNavigate = state.begin(isInitialInstallation: true)
        #expect(!shouldNavigate)
        let current = state
        state.collapseAfterSuccess(sessionID: oldSession)
        state.receiveProgress(ProviderInstallProgress(
            providerID: "obsolete", version: "1.0.0", phase: .completed
        ), sessionID: oldSession)
        state.receiveFailure(.init(providerID: "obsolete", version: "1.0.0"), message: "old error", sessionID: oldSession)
        state.receiveCatalog([release("obsolete")], installedVersions: [:], sessionID: oldSession)
        state.finish(succeeded: false, message: "old error", sessionID: oldSession)
        #expect(state == current)
    }

    @Test(arguments: [false, true])
    func indexFailureOrEmptyCatalogStaysOpenAndRetryDoesNotNavigate(emptyCatalog: Bool) throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let session = try #require(state.sessionID)
        if emptyCatalog { state.receiveCatalog([], installedVersions: [:], sessionID: session) }
        let shouldCollapse = state.finish(succeeded: false, message: "No components available", sessionID: session)
        #expect(!shouldCollapse)
        #expect(state.detailsExpanded)
        #expect(state.shouldShowNetworkHint)
        #expect(state.rows.isEmpty)
        let shouldNavigate = state.begin(isInitialInstallation: true)
        #expect(!shouldNavigate)
        #expect(state.phase == .fetchingCatalog)
    }

    @Test func retryOnlyResetsItsVersionAndRetainsOtherFailures() throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let session = try #require(state.sessionID)
        state.receiveCatalog([release("first"), release("second")], installedVersions: [:], sessionID: session)
        state.receiveFailure(state.rows[0].id, message: "first failure", sessionID: session)
        state.receiveFailure(state.rows[1].id, message: "second failure", sessionID: session)
        let newer = ProviderVersionReference(providerID: "first", version: "2.0.0")
        let shouldNavigate = state.begin(isInitialInstallation: true, retrying: newer)
        #expect(!shouldNavigate)
        #expect(state.rows.count == 2)
        #expect(state.rows.first { $0.id == newer }?.status == .queued)
        #expect(state.rows.first { $0.id.providerID == "second" }?.status == .failed("second failure"))
        #expect(!state.rows.contains { $0.id.providerID == "first" && $0.id.version == "1.0.0" })
    }

    @Test func backgroundUpdateAndDisabledStateDoNotShowInitialInstallation() throws {
        var state = ProviderInstallationPresentation()
        let shouldNavigate = state.begin(isInitialInstallation: false)
        #expect(!shouldNavigate)
        #expect(!state.detailsExpanded)
        #expect(!state.shouldShowNetworkHint)
        let session = try #require(state.sessionID)
        let shouldCollapse = state.finish(succeeded: true, message: "Ready", sessionID: session)
        #expect(!shouldCollapse)
        state.clear()
        #expect(state.phase == .idle)
        #expect(state.sessionID == nil)
    }

    @Test @MainActor func progressRowsFitTheSettingsPanelWithUnknownSizeAndLongErrors() throws {
        var state = ProviderInstallationPresentation()
        state.begin(isInitialInstallation: true)
        let session = try #require(state.sessionID)
        state.receiveCatalog(
            [release("netvplayer.catalog.java"), release("netvplayer.catalog.javascript"),
             release("netvplayer.catalog.python"), release("netvplayer.catalog.quickjs")],
            installedVersions: ["netvplayer.catalog.java": "1.0.0"], sessionID: session
        )
        state.receiveFailure(
            state.rows[1].id,
            message: "The connection to GitHub timed out. Check your network or proxy settings and retry this component. Other components will continue installing; any components that are already ready will remain available.",
            sessionID: session
        )
        let palette = AppThemeCatalog.palette(for: .orangeSea)
        for expectedBytes: Int64? in [nil, 100_000_000] {
            state.receiveProgress(ProviderInstallProgress(
                providerID: "netvplayer.catalog.python", version: "1.0.0", phase: .downloading,
                receivedBytes: 42_000_000, expectedBytes: expectedBytes
            ), sessionID: session)
            let content = ProviderInstallationProgressView(
                installation: state, isBusy: true,
                displayName: { value in
                    switch value {
                    case "netvplayer.catalog.java": L10n.text("Java 数据源兼容")
                    case "netvplayer.catalog.javascript": L10n.text("JavaScript 数据源兼容")
                    case "netvplayer.catalog.python": L10n.text("常用数据源兼容")
                    default: L10n.text("轻量脚本兼容")
                    }
                }, retry: { _ in }
            )
                .padding(20)
                .frame(width: 540)
                .fixedSize(horizontal: false, vertical: true)
                .background { AppThemeRootBackground(palette: palette, forceOpaque: false) }
                .environment(\.appThemePalette, palette)
                .tint(palette.accent)
                .preferredColorScheme(palette.preferredColorScheme)
            // AppKit hosting is required: ImageRenderer substitutes placeholders for native progress controls.
            let host = NSHostingView(rootView: content)
            let size = host.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            #expect(size.width == 540)
            #expect(size.height > 250 && size.height < 650)
            if let output = ProcessInfo.processInfo.environment["NETVPLAYER_INSTALLATION_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(expectedBytes == nil ? "unknown-size.png" : "known-size.png"))
            }
        }
    }
}
