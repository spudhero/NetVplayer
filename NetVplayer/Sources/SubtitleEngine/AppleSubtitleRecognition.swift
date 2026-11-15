import Foundation
import Vision
import Speech
import AVFAudio
import CoreMedia

public struct AppleSubtitleOCR: SubtitleRecognitionService {
    public let kind = SubtitleRecognitionKind.pgs
    public var identity: SubtitleTranslatorIdentity { .init(service:"apple.on-device",model:"vision-accurate-revision-3",version:ProcessInfo.processInfo.operatingSystemVersionString+"/pgs-1") }
    public init() {}
    public func recognize(_ payload: SubtitleRecognitionPayload, unit: SubtitleRecognitionUnit, language: String, deadline: TimeInterval) async throws -> [SubtitleRecognitionSpan] {
        guard case .bitmap(let data) = payload else { throw SubtitleRecognitionError.invalidInput }
        let task = Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3; request.recognitionLevel = .accurate
            guard try request.supportedRecognitionLanguages().contains(language) else { throw SubtitleRecognitionError.unsupported }
            request.recognitionLanguages = [language]; request.usesLanguageCorrection = false
            try Task.checkCancellation()
            try VNImageRequestHandler(data:data).perform([request])
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SubtitleRecognitionError.expired }
            let rows = (request.results ?? []).sorted {
                if abs($0.boundingBox.midY-$1.boundingBox.midY) > min($0.boundingBox.height,$1.boundingBox.height)*0.5 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            let text = rows.compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
            return text.isEmpty ? [] : [SubtitleRecognitionSpan(start:unit.start,end:unit.end,text:text)]
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

public enum SubtitleSpeechAvailability: Sendable { case unsupported, needsModel, installed }
#if compiler(>=6.2)
@available(macOS 26.0, *)
public struct AppleSubtitleASR: SubtitleRecognitionService {
    public let kind = SubtitleRecognitionKind.audio
    public var identity: SubtitleTranslatorIdentity { .init(service:"apple.on-device",model:"speech-transcriber",version:ProcessInfo.processInfo.operatingSystemVersionString+"/pcm-core20-context1-2") }
    public init() {}
    private static func transcriber(_ language: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable, let locale=await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:language)) else { throw SubtitleRecognitionError.unsupported }
        return SpeechTranscriber(locale:locale,transcriptionOptions:[],reportingOptions:[],attributeOptions:[.audioTimeRange])
    }
    public static func availability(language: String) async -> SubtitleSpeechAvailability {
        guard let module=try? await transcriber(language) else { return .unsupported }
        return (try? await AppleSpeechReservations.shared.withLease(locale:module.selectedLocales[0]) {
            switch await AssetInventory.status(forModules:[module]) {
            case .installed: return SubtitleSpeechAvailability.installed
            case .unsupported: return SubtitleSpeechAvailability.unsupported
            default: return SubtitleSpeechAvailability.needsModel
            }
        }) ?? .unsupported
    }
    /// Explicit model preparation; no automatic server-recognition fallback.
    public static func prepare(language: String) async throws {
        let module=try await transcriber(language)
        try await AppleSpeechReservations.shared.withLease(locale:module.selectedLocales[0]) {
            if let request=try await AssetInventory.assetInstallationRequest(supporting:[module]) { try await request.downloadAndInstall() }
            try Task.checkCancellation()
            guard await AssetInventory.status(forModules:[module]) == .installed else { throw SubtitleRecognitionError.modelRequired }
        }
    }
    public func recognize(_ payload: SubtitleRecognitionPayload, unit: SubtitleRecognitionUnit, language: String, deadline: TimeInterval) async throws -> [SubtitleRecognitionSpan] {
        let transcriber=try await Self.transcriber(language)
        return try await AppleSpeechReservations.shared.withLease(locale:transcriber.selectedLocales[0]) {
            try await recognizeInstalled(payload, unit:unit, transcriber:transcriber, deadline:deadline)
        }
    }
    private func recognizeInstalled(_ payload: SubtitleRecognitionPayload, unit: SubtitleRecognitionUnit, transcriber: SpeechTranscriber, deadline: TimeInterval) async throws -> [SubtitleRecognitionSpan] {
        guard await AssetInventory.status(forModules:[transcriber]) == .installed else { throw SubtitleRecognitionError.modelRequired }
        guard case let .audio(data,rate,channels,isFloat) = payload else { throw SubtitleRecognitionError.invalidInput }
        let sampleBytes=isFloat ? 4 : 2, frames=data.count/(channels*sampleBytes)
        guard frames > 0, let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:Double(rate),channels:1,interleaved:false),
              let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)), let samples=buffer.floatChannelData?[0] else { throw SubtitleRecognitionError.invalidInput }
        buffer.frameLength=AVAudioFrameCount(frames)
        try data.withUnsafeBytes { raw in
            for frame in 0..<frames {
                var value: Float = 0
                for channel in 0..<channels {
                    let i=(frame*channels+channel)*sampleBytes
                    if isFloat { value += Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:i,as:UInt32.self))) }
                    else { value += Float(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:i,as:Int16.self)))/32768 }
                }
                guard value.isFinite else { throw SubtitleRecognitionError.invalidInput }
                samples[frame]=max(-1,min(1,value/Float(channels)))
            }
        }
        guard let speechFormat=await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[transcriber],considering:format) else { throw SubtitleRecognitionError.unsupported }
        let input=try Self.convert(buffer,to:speechFormat)
        let analyzer=SpeechAnalyzer(modules:[transcriber],options:.init(priority:.utility,modelRetention:.whileInUse))
        let results=Task { () throws -> [SubtitleRecognitionSpan] in
            var spans: [SubtitleRecognitionSpan] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                for run in result.text.runs {
                    let text=String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                    guard let range=run.audioTimeRange else { throw SubtitleRecognitionError.invalidResponse }
                    let start=unit.inputStart+range.start.seconds, end=unit.inputStart+CMTimeRangeGetEnd(range).seconds
                    guard start.isFinite, end.isFinite, end > start, start >= unit.inputStart-0.001,
                          end <= unit.inputEnd+0.1 else { throw SubtitleRecognitionError.invalidResponse }
                    spans.append(.init(start:start,end:end,text:text))
                }
            }
            return spans
        }
        do {
            let stream=AsyncStream<AnalyzerInput> { continuation in
                continuation.yield(AnalyzerInput(buffer:input)); continuation.finish()
            }
            try await withTaskCancellationHandler {
                try await analyzer.prepareToAnalyze(in:input.format)
                try Task.checkCancellation()
                try await analyzer.start(inputSequence:stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } onCancel: { Task { await analyzer.cancelAndFinishNow() }; results.cancel() }
            let spans=try await results.value
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SubtitleRecognitionError.expired }
            return spans
        } catch {
            results.cancel(); await analyzer.cancelAndFinishNow(); _ = await results.result; throw error
        }
    }
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter=AVAudioConverter(from:buffer.format,to:format),
              let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(ceil(Double(buffer.frameLength)*format.sampleRate/buffer.format.sampleRate))+256) else { throw SubtitleRecognitionError.unsupported }
        let feed=SpeechPCMInput(buffer)
        var error: NSError?
        let status=converter.convert(to:output,error:&error) { _,status in feed.next(status) }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { throw SubtitleRecognitionError.invalidInput }
        return output
    }

}

/// Reserve only while checking/preparing/using this app's speech assets. Count
/// concurrent windows; never release reservations that predated this adapter.
@available(macOS 26.0, *)
private actor AppleSpeechReservations {
    static let shared = AppleSpeechReservations()
    private struct Entry { var count: Int; var owned: Bool }
    private var entries: [String:Entry] = [:]
    private var transition: Task<Void,Never>?
    func withLease<T: Sendable>(locale: Locale, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(locale)
        do {
            try Task.checkCancellation()
            let value=try await operation()
            await release(locale); return value
        } catch { await release(locale); throw error }
    }
    private func acquire(_ locale: Locale) async throws {
        let previous=transition
        let task=Task {
            await previous?.value
            try await reserveSerially(locale)
        }
        transition=Task { _ = await task.result }
        try await task.value
    }
    private func reserveSerially(_ locale: Locale) async throws {
        if var entry=entries[locale.identifier] {
            entry.count += 1; entries[locale.identifier]=entry
        } else {
            let owned=try await AssetInventory.reserve(locale:locale)
            entries[locale.identifier]=Entry(count:1,owned:owned)
        }
    }
    private func release(_ locale: Locale) async {
        let previous=transition
        let task=Task {
            await previous?.value
            await releaseSerially(locale)
        }
        transition=task
        await task.value
    }
    private func releaseSerially(_ locale: Locale) async {
        guard var entry=entries[locale.identifier] else { return }
        entry.count -= 1
        if entry.count > 0 { entries[locale.identifier]=entry; return }
        if entry.owned { _ = await AssetInventory.release(reservedLocale:locale) }
        entries.removeValue(forKey:locale.identifier)
    }
}

@available(macOS 26.0, *)
private final class SpeechPCMInput: @unchecked Sendable {
    private let lock=NSLock()
    private let buffer: AVAudioPCMBuffer
    private var consumed=false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer=buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        lock.withLock {
            if consumed { status.pointee = .endOfStream; return nil }
            consumed=true; status.pointee = .haveData; return buffer
        }
    }
}
#else
/// Keep builds using the repository's older pinned Xcode usable for OCR/text.
/// SpeechAnalyzer requires the Xcode 26 SDK and its Swift 6.2 toolchain.
@available(macOS 26.0, *)
public struct AppleSubtitleASR: SubtitleRecognitionService {
    public let kind = SubtitleRecognitionKind.audio
    public var identity: SubtitleTranslatorIdentity {
        .init(service: "apple.on-device", model: "speech-unavailable", version: "sdk-before-26")
    }
    public init() {}
    public static func availability(language: String) async -> SubtitleSpeechAvailability { .unsupported }
    public static func prepare(language: String) async throws { throw SubtitleRecognitionError.unsupported }
    public func recognize(_ payload: SubtitleRecognitionPayload, unit: SubtitleRecognitionUnit,
                          language: String, deadline: TimeInterval) async throws -> [SubtitleRecognitionSpan] {
        throw SubtitleRecognitionError.unsupported
    }
}
#endif
