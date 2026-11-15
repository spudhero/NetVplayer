import AppKit
import Models
import Observation
import SwiftUI
import Testing
@testable import NetVplayerApp

@Suite("Full-row disclosure interactions", .serialized) @MainActor
struct DisclosureInteractionTests {
    @Test(arguments: [CGFloat(0), 12, 14])
    func arrowTitleWhitespaceAndPaddingToggleExactlyOnce(_ padding: CGFloat) async throws {
        let state = DisclosureInteractionState()
        let host = DisclosureInteractionHost {
            DisclosureGroup(isExpanded: state.binding) {
                Text("Expanded content").frame(height: 44)
            } label: { Text("片源") }
            .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: padding))
        }
        defer { host.close() }
        try await host.settle()
        for point in [CGPoint(x: 14, y: 22), .init(x: 68, y: 22), .init(x: 420, y: 22), .init(x: 478, y: 2)] {
            let before = state.expanded
            let changes = state.changes
            try await host.click(point)
            #expect(state.expanded != before, "Header point \(point), padding \(padding)")
            #expect(state.changes == changes + 1)
        }
    }

    @Test func contentControlsAndNestedDisclosureStayIndependent() async throws {
        let state = DisclosureInteractionState()
        state.expanded = true
        let host = DisclosureInteractionHost {
            DisclosureGroup(isExpanded: state.binding) {
                Button("Independent action") { state.actions += 1 }
                    .buttonStyle(.plain).frame(width: 180, height: 44)
                DisclosureGroup(isExpanded: state.nestedBinding) { Text("Nested content") } label: { Text("Nested") }
                    .disclosureGroupStyle(FullRowDisclosureGroupStyle())
            } label: { Text("Audio") }
            .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 12))
        }
        defer { host.close() }
        try await host.settle()
        try await host.click(.init(x: 90, y: 66))
        #expect(state.actions == 1 && state.expanded)
        try await host.click(.init(x: 410, y: 106))
        #expect(state.nested && state.expanded)
        #expect(state.changes == 0)
    }

    @Test func fileVersionRowSelectionAndPlayAreSeparateActions() async throws {
        let state = DisclosureInteractionState()
        let reference = try MediaServerReference(accountID: UUID(), itemID: "film")
        let file = MediaServerFileDetail(id: "file", episodeURL: reference.locator, name: "Demo 2160p HDR.mkv", sourceID: "source-b")
        let host = DisclosureInteractionHost(size: .init(width: 800, height: 300)) {
            MediaServerFilesSection(files: [file], select: { state.selectedSource = $0 }, play: { _ in state.actions += 1 })
        }
        defer { host.close() }
        try await host.settle()
        try await host.click(.init(x: 460, y: 56))
        #expect(state.selectedSource == "source-b" && state.actions == 0)
        try await host.click(.init(x: 735, y: 56))
        #expect(state.actions == 1)
        try await host.click(.init(x: 460, y: 112))
        #expect(state.actions == 1 && state.selectedSource == "source-b")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_DISCLOSURE_CAPTURE_DIR"] != nil))
    func captureNativeBeforeAndAfter() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_DISCLOSURE_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for improved in [false, true] {
            let host = DisclosureInteractionHost(size: .init(width: 580, height: 540)) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("播放设置 · 技术详情").font(.title2.bold()).padding(.bottom, 4)
                    ForEach(["片源", "实际解码", "当前输出", "音频", "空间音频与追踪"], id: \.self) { title in
                        Group {
                            if improved {
                                DisclosureGroup { Text("播放参数") } label: { Text(title).font(.callout.bold()) }
                                    .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 12))
                            } else {
                                DisclosureGroup { Text("播放参数") } label: { Text(title).font(.callout.bold()) }
                                    .disclosureGroupStyle(.automatic).padding(12)
                            }
                        }
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
            }
            try await host.settle()
            try host.capture(output.appendingPathComponent(improved ? "after.png" : "before.png"))
            host.close()
        }
        let reference = try MediaServerReference(accountID: UUID(), itemID: "film")
        let files = ["1080p H.264", "2160p HEVC HDR10"].enumerated().map { index, name in
            MediaServerFileDetail(id: "version-\(index)", episodeURL: reference.locator, name: "示例影片 · " + name,
                container: "mkv", size: index == 0 ? 6_000_000_000 : 28_000_000_000,
                width: index == 0 ? 1920 : 3840, height: index == 0 ? 1080 : 2160, videoCodec: index == 0 ? "h264" : "hevc",
                videoRange: index == 0 ? "SDR" : "HDR10", audio: ["中文 · E-AC-3 · 5.1"], subtitles: ["简体中文 · SRT"], sourceID: "source-\(index)")
        }
        let dark = AppThemeCatalog.palette(for: .auroraViolet)
        let legacy = DisclosureInteractionHost(size: .init(width: 900, height: 420)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("文件信息")).font(.headline)
                ForEach(files) { file in
                    DisclosureGroup {
                        Text(file.audio.joined(separator: " · "))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.name).font(.callout.bold())
                            Text(MediaServerFilePresentation.summary(file)).font(.caption).foregroundStyle(dark.muted)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    .disclosureGroupStyle(.automatic).padding(14)
                    .background(dark.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(dark.foreground.opacity(0.08)))
                }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(dark.foreground).background(dark.background).preferredColorScheme(.dark)
        }
        try await legacy.settle()
        try legacy.capture(output.appendingPathComponent("versions-before.png"))
        legacy.close()
        for palette in [AppThemeCatalog.palette(for: .auroraViolet), AppThemeCatalog.palette(for: .seaSalt)] {
            let host = DisclosureInteractionHost(size: .init(width: 900, height: 420)) {
                MediaServerFilesSection(files: files, selectedSourceID: "source-1")
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.appThemePalette, palette)
                    .foregroundStyle(palette.foreground).background(palette.background)
                    .preferredColorScheme(palette.preferredColorScheme)
            }
            try await host.settle()
            try host.capture(output.appendingPathComponent(palette.preferredColorScheme == .light ? "versions-light.png" : "versions-dark.png"))
            host.close()
        }
    }
}

@MainActor @Observable private final class DisclosureInteractionState {
    var expanded = false
    var nested = false
    var changes = 0
    var actions = 0
    var selectedSource: String?
    var binding: Binding<Bool> { .init(get: { self.expanded }, set: { self.expanded = $0; self.changes += 1 }) }
    var nestedBinding: Binding<Bool> { .init(get: { self.nested }, set: { self.nested = $0 }) }
}

@MainActor private final class DisclosureInteractionHost {
    let window: NSWindow
    let view: NSHostingView<AnyView>
    init<Content: View>(size: CGSize = .init(width: 480, height: 240), @ViewBuilder content: () -> Content) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: AnyView(content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)))
        window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentView = view
        window.orderFrontRegardless()
    }
    func settle() async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        view.layoutSubtreeIfNeeded()
    }
    func click(_ point: CGPoint) async throws {
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let location = view.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let down = try event(.leftMouseDown)
        let up = try event(.leftMouseUp)
        // NSButton may synchronously track mouseDown until it dequeues mouseUp.
        // Queue the release before entering that nested event loop.
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        // Gesture-based views can return without a tracking loop. Deliver the
        // release ourselves only if the button did not already consume it.
        if let pending = NSApplication.shared.nextEvent(matching: .leftMouseUp,
            until: Date(), inMode: .default, dequeue: true) {
            if pending === up { window.sendEvent(pending) }
            else { NSApplication.shared.postEvent(pending, atStart: true) }
        }
        try await settle()
    }
    func capture(_ url: URL) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    func close() { window.orderOut(nil) }
}
