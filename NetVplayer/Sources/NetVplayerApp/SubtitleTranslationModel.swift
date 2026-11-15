import Foundation
import Combine
import Models
import PlayerEngine
import SubtitleEngine
@preconcurrency import Translation

@MainActor
final class SubtitleTranslationModel: ObservableObject {
    @Published private(set) var document: SubtitleDocument?
    @Published private(set) var coverage: SubtitleTranslationCoverage?
    @Published private(set) var sourceName = ""
    @Published private(set) var original: Sub?
    @Published private(set) var message: String?
    @Published private(set) var active = false
    @Published private(set) var requestID: UUID?
    @Published private(set) var revision = 0
    @Published var sourceLanguage = "en"
    @Published var targetLanguage = "zh-Hans"
    private(set) var owner: UUID?
    private var playbackOwner: SubtitlePlaybackOwner?
    private var playbackID: UUID?
    private var mediaKey: String?
    private var task: Task<Void, Never>?
    private var selection = UUID()
    let session: SubtitleTranslationSession

    init(session: SubtitleTranslationSession = .init()) {
        self.session = session
        session.failed = { error in Self.logFailure(error, stage: "request") }
        session.changed = { [weak self] in
            guard let self else { return }
            self.coverage = self.matchingCoverage
            self.revision &+= 1
            if self.coverage != nil, self.session.failure != nil { self.message = L10n.text("翻译未完成，继续显示原字幕。可重试恢复已保存的进度。") }
        }
    }

    private var matchingCoverage: SubtitleTranslationCoverage? {
        guard let owner, let document, session.owner == owner, let coverage = session.coverage else { return nil }
        let expected = SubtitleTranslationKey(media: mediaKey ?? "session:" + owner.uuidString, document: document,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, translator: Self.appleIdentity)
        return coverage.key == expected ? coverage : nil
    }

    func bind(_ spec: PlaySpec?, playbackID: UUID? = nil) {
        let identity = spec.map(SubtitlePlaybackOwner.init)
        let playbackID = playbackID ?? spec?.readSession?.id
        guard identity != playbackOwner || playbackID != self.playbackID else { return }
        cancel(); owner = spec == nil ? nil : UUID(); playbackOwner = identity; self.playbackID = playbackID
        mediaKey = spec.flatMap(PlaybackMediaIdentity.resolved)?.cacheKey
        document = nil; coverage = nil; original = nil; sourceName = ""; message = nil
    }

    func owns(_ spec: PlaySpec?, playbackID: UUID?) -> Bool {
        spec != nil && playbackOwner == spec.map(SubtitlePlaybackOwner.init)
            && self.playbackID == (playbackID ?? spec?.readSession?.id)
    }

    func load(data: Data, filename: String) {
        guard owner != nil else { return }
        cancel()
        do {
            document = try SubtitleDocument(data: data, filename: filename)
            sourceName = (filename as NSString).lastPathComponent; coverage = nil; message = nil
            original = DownloadedSubtitle(name: sourceName, format: (filename as NSString).pathExtension.lowercased(), data: data).attachment(language: sourceLanguage)
        } catch { document = nil; coverage = nil; message = L10n.text("无法读取文本字幕，请选择有效的 SRT、ASS、SSA 或 VTT 文件。") }
    }

    func load(file: URL) {
        guard file.isFileURL, let owner else { return }
        cancel(); let selection = selection
        task = Task {
            do {
                let data = try await PlaybackBackgroundBudget.shared.withRead(purpose: .subtitleExtraction,
                    bytes: Int64(SubtitleArchive.maximumFileBytes)) {
                    let fileHandle = try FileHandle(forReadingFrom: file)
                    defer { try? fileHandle.close() }
                    let data = try fileHandle.read(upToCount: SubtitleArchive.maximumFileBytes + 1) ?? Data()
                    guard data.count <= SubtitleArchive.maximumFileBytes else { throw SubtitleTranslationError.limitExceeded }
                    return data
                }
                try Task.checkCancellation()
                guard self.owner == owner, self.selection == selection else { return }
                self.load(data: data, filename: file.lastPathComponent)
            } catch {
                guard self.owner == owner, self.selection == selection, !Task.isCancelled else { return }
                message = L10n.text("无法读取文本字幕，请选择有效的 SRT、ASS、SSA 或 VTT 文件。")
            }
        }
    }

    func load(_ sub: Sub) {
        if sub.url.hasPrefix("data:"), let comma = sub.url.firstIndex(of: ","),
           sub.url[..<comma].lowercased().contains(";base64"), sub.url.utf8.count <= 6 * 1024 * 1024,
           let data = Data(base64Encoded: String(sub.url[sub.url.index(after: comma)...])) {
            load(data: data, filename: "subtitle." + sub.format.lowercased())
        } else if let url = URL(string: sub.url), url.isFileURL { load(file: url) }
        else { message = L10n.text("请先下载字幕到本机，再选择文本字幕文件。") }
    }

    func start(completing: Bool) {
        guard let document, let owner, sourceLanguage != targetLanguage else { return }
        cancel(); let selection = selection
        let key = SubtitleTranslationKey(media: mediaKey ?? "session:" + owner.uuidString, document: document,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, translator: Self.appleIdentity)
        task = Task {
            do {
                try await session.bind(owner: owner, document: document, key: key)
                try Task.checkCancellation()
                guard self.owner == owner, self.selection == selection else { return }
                session.completing = completing
                active = true; message = nil; requestID = session.coverage?.complete == true ? nil : UUID()
            } catch {
                guard self.owner == owner, self.selection == selection, !Task.isCancelled else { return }
                message = L10n.text("字幕缓存无法恢复，原字幕保持可用。")
            }
        }
    }

    func cancel() {
        selection = UUID(); task?.cancel(); task = nil
        requestID = nil; active = false; session.cancel()
    }

    func invalidateLanguages() { cancel(); coverage = nil }
    func preparationFailed() {
        cancel()
        message = L10n.text("本机翻译未就绪。请检查语言支持或模型下载后重试，原字幕保持可用。")
    }
    static func logFailure(_ error: any Error, stage: String) {
        let error = error as NSError
        let domain = String(error.domain.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }.prefix(100).map(String.init).joined())
        DiagnosticLog.write("[SUBTITLE_TRANSLATION_FAILURE] stage=\(stage) domain=\(domain) code=\(error.code)")
    }

    func update(_ player: PlayerState, pendingSeek: Bool = false) {
        bind(player.currentSpec, playbackID: player.chapterOwnerID)
        session.update(position: player.position, speed: Double(player.speed), playing: player.isPlaying,
            seeking: player.isSeeking || pendingSeek, discontinuity: pendingSeek)
    }

    var canResumeAcrossSessions: Bool { mediaKey != nil }
    /// A completed session can keep displaying its translations without doing
    /// more work. Do not cancel that session merely to dismiss a busy indicator.
    var isProcessing: Bool { active && coverage?.complete != true && session.failure == nil }
    static var appleIdentity: SubtitleTranslatorIdentity {
        // Apple exposes no language-asset build identifier. OS build plus adapter version
        // conservatively invalidates cached results on system updates.
        .init(service: "apple.on-device", model: "system-translation",
              version: ProcessInfo.processInfo.operatingSystemVersionString + "/adapter-1")
    }
}

@available(macOS 15.0, *)
@MainActor
final class AppleSubtitleTranslationService: SubtitleTranslationService {
    let identity = SubtitleTranslationModel.appleIdentity
    private let session: TranslationSession
    init(session: TranslationSession) { self.session = session }
    func translate(_ request: SubtitleTranslationRequest) async throws -> [Int: String] {
        try Task.checkCancellation()
        guard session.sourceLanguage?.languageCode == Locale.Language(identifier: request.sourceLanguage).languageCode,
              session.targetLanguage?.languageCode == Locale.Language(identifier: request.targetLanguage).languageCode,
              session.targetLanguage?.script == Locale.Language(identifier: request.targetLanguage).script else {
            DiagnosticLog.write("[SUBTITLE_TRANSLATION_FAILURE] stage=language-validation")
            throw SubtitleTranslationError.invalidResponse
        }
        let responses = try await session.translations(from: Self.requests(for: request.cues))
        try Task.checkCancellation()
        var result: [Int: String] = [:]
        for response in responses {
            guard let idString = response.clientIdentifier, let id = Int(idString), result[id] == nil,
                  let cue = request.cues.first(where: { $0.id == id }), response.sourceText == cue.text else { throw SubtitleTranslationError.invalidResponse }
            result[id] = response.targetText
        }
        return result
    }

    // The SDK request is not Sendable. Build a fresh disconnected region and
    // transfer it once to the system API; no batch is shared with UI state.
    nonisolated private static func requests(for cues: [SubtitleCue]) -> sending [TranslationSession.Request] {
        cues.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
    }
}
