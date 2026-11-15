import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import Models

/// Foundation URL's Transferable representation is export-only on macOS.
/// Finder supplies UTF-8 file URL data, which needs an explicit import representation.
struct LocalMediaFileURL: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard data.count <= 4096,
                  let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return LocalMediaFileURL(url: url)
        }
    }
}

enum LocalMediaFileDrop {
    // Do not depend on Launch Services registrations being available in every host.
    private static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mpeg", "mpg", "mpe", "mp3", "mp2", "m4a", "aac",
        "wav", "wave", "aiff", "aif", "aifc", "caf", "au", "3gp", "3g2", "f4v", "wma",
        "mkv", "webm", "avi", "flv", "wmv", "asf", "vob", "rm", "rmvb", "divx",
        "ogm", "ogg", "opus", "flac", "ape", "dts", "ac3", "eac3", "thd", "truehd",
        "m2ts", "mts", "ts", "m3u", "m3u8", "pls"
    ]

    static func mediaFiles(in urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let file = url.standardizedFileURL
            let ext = file.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            guard mediaExtensions.contains(ext) || type?.conforms(to: .audiovisualContent) == true,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  seen.insert(file).inserted else { return nil }
            return file
        }
    }

    /// Recovery keeps its explicit user choice; ready windows play only the first file.
    @MainActor
    static func receive<Runtime>(_ urls: [URL], startup: StartupCoordinator<Runtime>,
                                 open: (URL) -> Void) -> Bool {
        guard ![.terminating, .terminationFailed, .stopped, .failed].contains(startup.phase) else { return false }
        let files = mediaFiles(in: urls)
        guard let first = files.first else { return false }
        if startup.phase == .ready, startup.runtime != nil {
            startup.enqueue(Array(files.dropFirst()))
            open(first)
        } else {
            startup.enqueue(files)
        }
        return true
    }
}

struct LocalMediaFileDropModifier: ViewModifier {
    @ObservedObject var startup: AppStartupCoordinator
    let palette: AppThemePalette
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: LocalMediaFileURL.self) { items, _ in
                LocalMediaFileDrop.receive(items.map(\.url), startup: startup) { file in
                    guard let state = startup.runtime else { return }
                    Task { await state.openStartupFile(file) }
                }
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    LocalMediaFileDropOverlay(awaitingStartup: startup.phase != .ready,
                        usesFixedDarkChrome: startup.runtime?.isPlayerPresented == true)
                    .environment(\.appThemePalette, palette)
                    .allowsHitTesting(false)
                }
            }
    }
}

struct LocalMediaFileDropOverlay: View {
    @Environment(\.appThemePalette) private var appPalette
    let awaitingStartup: Bool
    var usesFixedDarkChrome = false

    private var palette: AppThemePalette {
        usesFixedDarkChrome ? AppThemeCatalog.palette(for: .legacyDeepSpace) : appPalette
    }

    var body: some View {
        ZStack {
            palette.background.opacity(usesFixedDarkChrome ? 0.36 : 0.12)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36)).foregroundStyle(palette.accent).accessibilityHidden(true)
                Text(L10n.text(awaitingStartup ? "松开以暂存本地文件" : "松开以播放本地文件"))
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(palette.foreground)
                Text(L10n.text(awaitingStartup
                    ? "完成启动确认后，从待打开文件中选择播放。"
                    : "多个文件会先播放第一个有效文件，其余保留待选择。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(24).frame(maxWidth: 420)
            .background(palette.surface.opacity(0.98), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.accent.opacity(0.45), lineWidth: 1) }
            .padding(24)
        }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accent, lineWidth: 2).padding(8) }
        .preferredColorScheme(palette.preferredColorScheme)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("local-file-drop-target")
    }
}
