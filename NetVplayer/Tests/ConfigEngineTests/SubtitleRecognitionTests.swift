import Foundation
import Testing
import Models
import PlayerEngine
@testable import SubtitleEngine
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct SubtitleRecognitionTests {
    private func temporary() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("recognition-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func wave(_ directory: URL, seconds: Int = 41) throws -> URL {
        var data=Data("RIFF".utf8)
        func u16(_ v: UInt16) { var v=v.littleEndian; data.append(Data(bytes:&v,count:2)) }
        func u32(_ v: UInt32) { var v=v.littleEndian; data.append(Data(bytes:&v,count:4)) }
        let bytes=seconds*16000*2
        u32(UInt32(bytes+36)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(bytes)); data.append(Data(count:bytes))
        let file=directory.appendingPathComponent("input.wav"); try data.write(to:file); return file
    }
    private func source(_ directory: URL) async throws -> SubtitleRecognitionSource {
        try await .load(file:wave(directory),library:"",budget:.init())
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("Timed out waiting for recognition state")
    }
    @Test func waveCreatesBoundedOverlappingWindowsAndStableContentKey() async throws {
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let first=try await source(directory)
        #expect(first.units.count == 3)
        #expect(first.units.map(\.start) == [0,20,40]); #expect(first.units.map(\.inputStart) == [0,19,39])
        #expect(first.units.map(\.inputEnd) == [21,41,41])
        let file=directory.appendingPathComponent("renamed.wav"); try FileManager.default.copyItem(at:directory.appendingPathComponent("input.wav"),to:file)
        let second=try await SubtitleRecognitionSource.load(file:file,library:"",budget:.init())
        #expect(try first.cacheDocument().fingerprint == second.cacheDocument().fingerprint)
    }
    @Test func sharedBudgetBlocksHashingAndCancelsQueuedRead() async throws {
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let file=try wave(directory), budget=PlaybackBackgroundBudget()
        budget.update(session:"foreground",bufferedAhead:0,isLoading:true,isSeeking:false,isBuffering:true)
        let task=Task { try await SubtitleRecognitionSource.load(file:file,library:"",budget:budget) }
        try await wait { budget.waitingReadCount > 0 }
        #expect(budget.activeBackgroundReads == 0)
        task.cancel()
        await #expect(throws:CancellationError.self) { try await task.value }
        try await wait { budget.waitingReadCount == 0 }
        #expect(budget.reservedBytes == 0)
    }
    @Test func cancellingOneBorrowerDoesNotCancelTheSharedAudioRead() async throws {
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let budget=PlaybackBackgroundBudget(), file=try wave(directory)
        let source=try await SubtitleRecognitionSource.load(file:file,library:"",budget:budget)
        budget.update(session:"foreground",bufferedAhead:0,isLoading:true,isSeeking:false,isBuffering:true)
        let session=PlaybackReadSession(), identity=PlaybackMediaIdentity(source:"test",account:"local",item:"same-wave")
        let firstOwner=session.makeOwner(mediaIdentity:identity,purpose:.subtitleExtraction)
        let secondOwner=session.makeOwner(mediaIdentity:identity,purpose:.subtitleExtraction)
        let first=Task { try await source.payload(for:source.units[0],owner:firstOwner) }
        let second=Task { try await source.payload(for:source.units[0],owner:secondOwner) }
        try await wait { budget.waitingReadCount == 1 }
        try await Task.sleep(for:.milliseconds(20))
        first.cancel()
        await #expect(throws:CancellationError.self) { try await first.value }
        #expect(budget.waitingReadCount == 1)
        budget.remove(session:"foreground")
        let payload=try await second.value
        if case .audio(let data,_,_,_) = payload { #expect(data.count == 21*16000*2) }
        else { Issue.record("Expected audio") }
        #expect(budget.activeBackgroundReads == 0 && budget.reservedBytes == 0)
    }
    @Test func sourceRejectsChangedAudioAndMalformedOrCompressedWave() async throws {
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let source=try await source(directory), file=directory.appendingPathComponent("input.wav")
        try Data("not audio".utf8).write(to:file)
        let reads=PlaybackReadSession(), owner=reads.makeOwner(mediaIdentity:.init(source:"test",account:"test",item:"audio"),purpose:.subtitleExtraction)
        await #expect(throws:SubtitleRecognitionError.changedInput) { try await source.payload(for:source.units[0],owner:owner) }
        await #expect(throws:(any Error).self) { try await SubtitleRecognitionSource.load(file:file,library:"",budget:.init()) }
        var data=try Data(contentsOf:wave(directory)); data[20]=6; try data.write(to:file)
        await #expect(throws:SubtitleRecognitionError.unsupported) { try await SubtitleRecognitionSource.load(file:file,library:"",budget:.init()) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"] != nil))
    func realPGSDecoderPreservesRepeatedCuesAndRejectsTruncatedInput() async throws {
        guard let library=ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"] else { Issue.record("This decoder contract requires the frozen runtime"); return }
        let file=try #require(Bundle.module.url(forResource:"recognition-original",withExtension:"sup"))
        let decoded=try await SubtitleRecognitionSource.load(file:file,library:library,budget:.init())
        #expect(decoded.units.count == 6)
        #expect(decoded.units.map(\.start) == [1,5,9,13,17,21]); #expect(decoded.units.map(\.end) == [4,8,12,16,20,24])
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let bad=directory.appendingPathComponent("bad.sup"); try Data(Data(contentsOf:file).dropLast()).write(to:bad)
        await #expect(throws:SubtitleRecognitionError.invalidInput) { try await SubtitleRecognitionSource.load(file:bad,library:library,budget:.init()) }
    }
    @Test func timedOverlapMergeKeepsContextOmissionsAndRealRepeatedWords() {
        let a=SubtitleRecognitionSpan(start:19.7,end:20.2,text:"left ")
        let b=SubtitleRecognitionSpan(start:19.8,end:20.3,text:"left ")
        let repeated=SubtitleRecognitionSpan(start:20.4,end:20.7,text:"left ")
        let contextOnly=SubtitleRecognitionSpan(start:19.2,end:19.6,text:"turn ")
        let merged=SubtitleRecognitionTimeline.merge([a,b,repeated,contextOnly],audio:true)
        #expect(merged.count == 1); #expect(merged.first?.text == "turn left left")
        #expect(SubtitleRecognitionTimeline.merge([a,a],audio:false).count == 2)
    }
    @Test func checkpointsResumeWithoutReprocessingAndSilenceIsNotInventedText() async throws {
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let source=try await source(directory), service=RecognitionContractService()
        let cache=SubtitleTranslationCache(directory:directory.appendingPathComponent("cache")), first=SubtitleRecognitionSession(cache:cache,budget:.init())
        try await first.bind(owner:UUID(),media:"stable-media",source:source,language:"en-US",service:service)
        first.changed={ if first.coverage?.translations.count == 1 { first.changed=nil; first.cancel() } }
        await first.run(service:service)
        let partial=try #require(first.coverage); #expect(!partial.complete); #expect(first.document == nil)
        let second=SubtitleRecognitionSession(cache:SubtitleTranslationCache(directory:directory.appendingPathComponent("cache")),budget:.init())
        try await second.bind(owner:UUID(),media:"stable-media",source:source,language:"en-US",service:service)
        #expect(second.coverage == partial)
        await second.run(service:service)
        #expect(second.coverage?.complete == true); #expect(second.document == nil)
        #expect(await service.calls == 3)
    }
    @Test func noncooperativeSeekCannotWriteOldGenerationOrOverlapRequests() async throws {
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        let source=try await source(directory), service=RecognitionContractService(hold:true)
        let session=SubtitleRecognitionSession(cache:.init(directory:directory.appendingPathComponent("cache")),budget:.init())
        try await session.bind(owner:UUID(),media:"stable",source:source,language:"en-US",service:service)
        let task=Task { await session.run(service:service) }
        try await wait { await service.calls == 1 }
        let generation=session.generation
        session.update(position:25,speed:1,seeking:true)
        #expect(session.generation > generation)
        await service.release()
        session.update(position:25,speed:1,seeking:false)
        await task.value
        #expect(await service.maximumActive == 1)
        #expect(session.coverage?.complete == true)
        #expect(session.coverage?.translations.values.contains(where: { $0.contains("retired") }) == false)
    }
    @Test func cancelAndExpiredNoncooperativeResponsesNeverCheckpoint() async throws {
        for expires in [false,true] {
            let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
            let source=try await source(directory), service=RecognitionContractService(hold:true)
            let session=SubtitleRecognitionSession(cache:.init(directory:directory.appendingPathComponent("cache")),budget:.init())
            try await session.bind(owner:UUID(),media:"stable",source:source,language:"en-US",service:service)
            let task=Task { await session.run(service:service,requestTimeout:expires ? 0.02 : 120) }
            try await wait { await service.calls == 1 }
            if expires { try await Task.sleep(for:.milliseconds(50)) } else { session.cancel() }
            await service.release(); await task.value
            #expect(session.coverage?.translations.isEmpty == true); #expect(session.document == nil)
            if expires { #expect(session.failure != nil) }
        }
    }
    @Test func wrongOwnerAndLanguageNotificationsCannotRestoreResults() async throws {
        let model=SubtitleRecognitionModel()
        let player=PlayerState(); player.currentSpec=PlaySpec(url:"file:///original.mkv")
        model.update(player)
        let directory=try temporary(); defer { try? FileManager.default.removeItem(at:directory) }
        model.load(file:try wave(directory))
        try await wait { !model.busy }
        #expect(model.source != nil)
        model.language="ja-JP"; model.languageChanged()
        #expect(model.coverage == nil && model.document == nil)
        player.currentSpec=PlaySpec(url:"file:///other.mkv"); model.update(player)
        model.session.changed?()
        #expect(model.source == nil && model.coverage == nil && model.document == nil)
    }
}

private actor RecognitionContractService: SubtitleRecognitionService {
    nonisolated let kind=SubtitleRecognitionKind.audio
    nonisolated let identity=SubtitleTranslatorIdentity(service:"contract-test",model:"no-real-ASR",version:"1")
    private(set) var calls=0, maximumActive=0
    private var active=0, hold: Bool
    private var continuation: CheckedContinuation<Void,Never>?
    init(hold: Bool = false) { self.hold=hold }
    func recognize(_ payload: SubtitleRecognitionPayload, unit: SubtitleRecognitionUnit, language: String, deadline: TimeInterval) async throws -> [SubtitleRecognitionSpan] {
        calls += 1; active += 1; maximumActive=max(maximumActive,active)
        defer { active -= 1 }
        if hold && calls == 1 {
            await withCheckedContinuation { continuation=$0 }
            return [.init(start:unit.start,end:unit.end,text:"retired")]
        }
        return [] // contract-only silent windows, never a real ASR claim
    }
    func release() { hold=false; continuation?.resume(); continuation=nil }
}

@MainActor @Test(.enabled(if:ProcessInfo.processInfo.environment["NETVPLAYER_RECOGNITION_NATIVE"] != nil))
func appleRecognitionNativeCheckpointResumeAndExport() async throws {
    let env=ProcessInfo.processInfo.environment
    let output=URL(fileURLWithPath:try #require(env["NETVPLAYER_RECOGNITION_OUTPUT"]))
    try #require(!FileManager.default.fileExists(atPath:output.path)); try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let library=try #require(env["NETVPLAYER_LIBMPV_PATH"])
    var reports: [[String:Any]] = []
    var services: [(String,String,any SubtitleRecognitionService)] = [(try #require(env["NETVPLAYER_RECOGNITION_SUP"]),"en-US",AppleSubtitleOCR())]
    if #available(macOS 26.0, *) {
        if env["NETVPLAYER_RECOGNITION_PREPARE"] == "1" { try await AppleSubtitleASR.prepare(language:"en-US") }
        try #require(await AppleSubtitleASR.availability(language:"en-US") == .installed)
        services.append((try #require(env["NETVPLAYER_RECOGNITION_WAV"]),"en-US",AppleSubtitleASR()))
    } else { Issue.record("Native speech test requires macOS 26"); return }
    for (file,language,service) in services {
        let source=try await SubtitleRecognitionSource.load(file:URL(fileURLWithPath:file),library:library,budget:.init())
        let root=output.appendingPathComponent(service.kind.rawValue)
        let cache=SubtitleTranslationCache(directory:root.appendingPathComponent("cache")), first=SubtitleRecognitionSession(cache:cache,budget:.init())
        let begin=ProcessInfo.processInfo.systemUptime
        try await first.bind(owner:UUID(),media:"authored-or-public-recognition-fixture",source:source,language:language,service:service)
        first.changed={ if first.coverage?.translations.count == 1 { first.changed=nil; first.cancel() } }
        await first.run(service:service)
        let partial=try #require(first.coverage)
        try #require(partial.translations.count == 1 && !partial.complete,"Actual native first checkpoint must exist")
        let second=SubtitleRecognitionSession(cache:.init(directory:root.appendingPathComponent("cache")),budget:.init())
        try await second.bind(owner:UUID(),media:"authored-or-public-recognition-fixture",source:source,language:language,service:service)
        #expect(second.coverage == partial)
        await second.run(service:service)
        try #require(second.coverage?.complete == true,"Native service must really finish")
        let document=try #require(second.document,"The genuine fixture contains text/speech")
        for format in SubtitleExportFormat.allCases {
            let data=try SubtitleExporter.render(document:document,format:format)
            try SubtitleExporter.save(data,to:root.appendingPathComponent("recognized."+format.rawValue))
            let reparsed=try SubtitleDocument(data:data,filename:"recognized."+format.rawValue)
            let tolerance=format == .srt ? 0.00051 : 0.0051
            #expect(zip(reparsed.cues,document.cues).allSatisfy { abs($0.start-$1.start) <= tolerance && abs($0.end-$1.end) <= tolerance })
        }
        reports.append(["kind":service.kind.rawValue,"inputSHA256":source.fingerprint,"inputUnits":source.units.count,"restoredUnits":partial.translations.count,
            "completedUnits":second.coverage!.translations.count,"recognizedCues":document.cues.count,"seconds":ProcessInfo.processInfo.systemUptime-begin,
            "cues":document.cues.map { ["start":$0.start,"end":$0.end,"text":$0.text] as [String:Any] }])
    }
    try JSONSerialization.data(withJSONObject:["os":ProcessInfo.processInfo.operatingSystemVersionString,"actualOnDeviceServices":true,"results":reports],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native-run.json"))
}
