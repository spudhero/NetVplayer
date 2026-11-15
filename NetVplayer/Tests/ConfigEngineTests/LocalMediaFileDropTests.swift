import Foundation
import Testing
import Diagnostics
import AppKit
import CoreTransferable
import UniformTypeIdentifiers
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct LocalMediaFileDropTests {
    private func fixtures() throws -> (directory: URL, files: [URL]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-drop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = ["本地 视频.MP4", "第二部.mkv", "音乐.flac", "说明.txt"].map {
            directory.appendingPathComponent($0)
        }
        for file in files { try Data("fixture".utf8).write(to: file) }
        return (directory, files)
    }

    @Test func acceptsDistinctLocalMediaButRejectsDirectoriesMissingFilesAndWebURLs() throws {
        let (directory, files) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder.mp4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(LocalMediaFileDrop.mediaFiles(in: [
            files[0], files[0], files[1], files[2], files[3], folder,
            directory.appendingPathComponent("missing.mp4"), URL(string: "https://example.test/video.mp4")!
        ]) == Array(files.prefix(3)))
    }

    @Test func readyDropOpensFirstAndQueuesRemainingWithoutReplacingPendingRequests() async throws {
        let (directory, files) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in 1 }, cleanup: { _ in })
        startup.startIfNeeded()
        await startup.waitForStartup()
        startup.enqueue([files[2]])
        var opened: [URL] = []
        #expect(LocalMediaFileDrop.receive([files[0], files[0], files[1]], startup: startup) { opened.append($0) })
        #expect(opened == [files[0]])
        #expect(startup.pendingFiles == [files[2], files[1]])
        #expect(await startup.terminate().value)
    }

    @Test func finderFileURLRepresentationLoadsThroughTheSwiftUIDropType() async throws {
        let (directory, files) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = files[0]
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(Data(file.absoluteString.utf8), nil)
            return nil
        }
        let received: LocalMediaFileURL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: LocalMediaFileURL.self) { continuation.resume(with: $0) }
        }
        #expect(LocalMediaFileDrop.mediaFiles(in: [received.url]) == [file])
    }

    @Test func recoveryDropWaitsForExplicitStartupAndFileSelection() throws {
        let (directory, files) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StartupSessionStore(url: directory.appendingPathComponent("session.json"))
        try store.write(.starting, recoveryPending: false)
        let startup = StartupCoordinator<Int>(store: store, factory: { _ in 1 }, cleanup: { _ in })
        startup.prepare()
        #expect(startup.phase == .recovery)
        #expect(LocalMediaFileDrop.receive(Array(files.prefix(2)), startup: startup) { _ in Issue.record("must not play during recovery") })
        #expect(startup.pendingFiles == Array(files.prefix(2)))
        #expect(startup.takeFile(files[0]) == nil)
    }

    @Test func invalidDropAndDropAfterTerminationNeverStartPlayback() async throws {
        let (directory, files) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in 1 }, cleanup: { _ in })
        #expect(!LocalMediaFileDrop.receive([files[3]], startup: startup) { _ in Issue.record("not media") })
        #expect(await startup.terminate().value)
        #expect(!LocalMediaFileDrop.receive([files[0]], startup: startup) { _ in Issue.record("already stopped") })
        #expect(startup.pendingFiles.isEmpty)
    }
}
