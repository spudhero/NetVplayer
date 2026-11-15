import Foundation
import Combine
import Models
import PlayerEngine
import SubtitleEngine

@MainActor
final class SubtitleRecognitionModel: ObservableObject {
    @Published private(set) var source: SubtitleRecognitionSource?
    @Published private(set) var coverage: SubtitleTranslationCoverage?
    @Published private(set) var document: SubtitleDocument?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var speechAvailability = SubtitleSpeechAvailability.unsupported
    @Published var language = "en-US"
    private var owner: UUID?
    private var playbackOwner: SubtitlePlaybackOwner?
    private var playbackID: UUID?
    private var media: String?
    private var selection = UUID()
    private var task: Task<Void,Never>?
    private var availabilityTask: Task<Void,Never>?
    let session: SubtitleRecognitionSession
    init(session: SubtitleRecognitionSession = .init()) {
        self.session = session
        session.changed = { [weak self] in
            guard let self, let owner=self.owner, let source=self.source, self.session.owner == owner,
                  self.session.coverage?.key == self.expectedKey(source:source) else { return }
            self.coverage=self.session.coverage; self.document=self.session.document
        }
    }
    private func service(for source: SubtitleRecognitionSource) -> (any SubtitleRecognitionService)? {
        if source.kind == .pgs { return AppleSubtitleOCR() }
        if #available(macOS 26.0, *) { return AppleSubtitleASR() }
        return nil
    }
    private var recognitionLanguage: String {
        if source?.kind == .pgs {
            if language == "zh-CN" { return "zh-Hans" }
            if language == "zh-TW" { return "zh-Hant" }
        }
        return language
    }
    private func expectedKey(source: SubtitleRecognitionSource) -> SubtitleTranslationKey? {
        guard let owner, let service=service(for:source), let doc=try? source.cacheDocument() else { return nil }
        return .init(media:media ?? "session:"+owner.uuidString,document:doc,sourceLanguage:recognitionLanguage,targetLanguage:"recognition",translator:service.identity)
    }
    func update(_ player: PlayerState, pendingSeek: Bool = false) {
        let identity=player.currentSpec.map(SubtitlePlaybackOwner.init), id=player.chapterOwnerID ?? player.currentSpec?.readSession?.id
        if identity != playbackOwner || id != playbackID {
            cancel(); session.reset(); source=nil; coverage=nil; document=nil; message=nil
            owner=player.currentSpec == nil ? nil : UUID(); playbackOwner=identity; playbackID=id
            media=player.currentSpec.flatMap(PlaybackMediaIdentity.resolved)?.cacheKey
        }
        session.update(position:player.position,speed:Double(player.speed),seeking:player.isSeeking || pendingSeek,discontinuity:pendingSeek)
    }
    func load(file: URL) {
        guard let owner else { return }
        cancel(); session.reset(); source=nil; document=nil; coverage=nil; busy=true; message=nil
        let token=selection
        let library=ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"]
            ?? Bundle.main.privateFrameworksURL?.appendingPathComponent("libmpv.2.dylib").path ?? ""
        task=Task {
            do {
                let loaded=try await SubtitleRecognitionSource.load(file:file,library:library)
                try Task.checkCancellation()
                guard self.owner == owner, self.selection == token else { return }
                source=loaded; busy=false
                if loaded.kind == .audio { refreshAvailability() }
            } catch { finish(error,owner:owner,token:token) }
        }
    }
    func refreshAvailability() {
        availabilityTask?.cancel(); speechAvailability = .unsupported
        guard #available(macOS 26.0, *) else { return }
        let language=language
        availabilityTask=Task {
            let status=await AppleSubtitleASR.availability(language:language)
            guard !Task.isCancelled, self.language == language else { return }
            speechAvailability=status
        }
    }
    func prepareModel() {
        guard #available(macOS 26.0, *), let owner else { return }
        cancel(); busy=true; message=L10n.text("正在准备 Apple 本机语音模型…")
        let token=selection, language=language
        task=Task {
            do {
                try await AppleSubtitleASR.prepare(language:language)
                guard !Task.isCancelled, self.owner == owner, self.selection == token else { return }
                busy=false; message=nil; refreshAvailability()
            } catch { finish(error,owner:owner,token:token) }
        }
    }
    func start() {
        guard let owner, let source, let service=service(for:source) else { return }
        cancel(); document=nil; coverage=nil; busy=true; message=nil
        let token=selection, language=recognitionLanguage, media=media ?? "session:"+owner.uuidString
        task=Task {
            do {
                try await session.bind(owner:owner,media:media,source:source,language:language,service:service)
                try Task.checkCancellation()
                guard self.owner == owner, self.selection == token else { return }
                await session.run(service:service)
                guard !Task.isCancelled, self.owner == owner, self.selection == token else { return }
                busy=false
                if let error=session.failure { finish(error,owner:owner,token:token) }
                else if session.coverage?.complete == true, session.document == nil { message=L10n.text("识别已完成，未检测到文字或语音。") }
            } catch { finish(error,owner:owner,token:token) }
        }
    }
    func cancel() { selection=UUID(); task?.cancel(); task=nil; busy=false; session.cancel() }
    func languageChanged() { cancel(); session.reset(); coverage=nil; document=nil; message=nil; refreshAvailability() }
    var canResumeAcrossSessions: Bool { media != nil }
    private func finish(_ error: any Error, owner: UUID, token: UUID) {
        guard !Task.isCancelled, self.owner == owner, self.selection == token else { return }
        busy=false
        SubtitleTranslationModel.logFailure(error,stage:"recognition")
        if case SubtitleRecognitionError.modelRequired = error {
            message=L10n.text("本机语音模型尚未就绪，请准备模型后重试。")
        } else { message=L10n.text("识别未完成。请检查本地文件、语言或本机模型后重试，已保存的进度可恢复。") }
    }
}
