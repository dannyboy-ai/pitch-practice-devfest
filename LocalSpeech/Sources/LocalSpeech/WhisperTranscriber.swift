import AVFoundation
import CoreML
import Foundation
import OSLog
@preconcurrency import WhisperKit

public enum WhisperCheckpoint: Sendable {
    case turbo
    case base

    fileprivate var modelDirectoryName: String {
        switch self {
        case .turbo: return "openai_whisper-large-v3-v20240930_626MB"
        case .base: return "openai_whisper-base"
        }
    }

    fileprivate var tokenizerName: String {
        switch self {
        case .turbo: return "whisper-large-v3"
        case .base: return "whisper-base"
        }
    }

    fileprivate var vocabularySize: Int { self == .turbo ? 51_866 : 51_865 }
    fileprivate var encoderSize: Int { self == .turbo ? 1_280 : 512 }
}

public struct RecognizedWord: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct RecognizedPhrase: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let words: [RecognizedWord]

    public init(start: Double, end: Double, text: String, words: [RecognizedWord]) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

struct LocalSpeechError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Saved-file recognition only. The caller owns capture and committed-file watermarks.
public actor WhisperTranscriber {
    /// Last successful window's detected language, retained for the experimental lab.
    public private(set) var detectedLanguage: String?
    private let checkpoint: WhisperCheckpoint
    private var engine: WhisperKit?
    private var preparedDirectory: URL?
    private var preparationNotes = ""
    private var isBusy = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let logger = Logger(subsystem: "ai.dannyboy.pitchpractice", category: "LocalSpeech")

    public init(checkpoint: WhisperCheckpoint = .turbo) {
        self.checkpoint = checkpoint
    }

    public func prepare(modelsDirectory: URL) async throws -> String {
        try Task.checkCancellation()
        guard !isBusy else { throw LocalSpeechError("Whisper is already preparing, transcribing, or unloading.") }
        guard modelsDirectory.isFileURL else { throw LocalSpeechError("Models must be a local file directory.") }
        let root = modelsDirectory.standardizedFileURL
        if engine != nil {
            guard root == preparedDirectory else {
                throw LocalSpeechError("Whisper is already loaded from another models directory.")
            }
            return preparationNotes
        }
        isBusy = true
        defer { finishOperation() }

        let modelDirectory = root.appendingPathComponent(checkpoint.modelDirectoryName, isDirectory: true)
        let tokenizerDirectory = root.appendingPathComponent("tokenizers/openai/\(checkpoint.tokenizerName)", isDirectory: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try requireAsset(modelDirectory.appendingPathComponent("\(name).mlmodelc"), directory: true)
        }
        for name in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            try requireAsset(tokenizerDirectory.appendingPathComponent(name), directory: false)
        }

        var candidate: WhisperKit?
        logger.notice("Local tokenizer preparation begin")
        do {
            // download:false does NOT disable the SDK's default tokenizer network fallback.
            // This strictly local factory and injection bypass that loader altogether.
            let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: tokenizerDirectory)
            try Task.checkCancellation()
            let localTokenizer = try LocalWhisperTokenizer(tokenizer)
            logger.notice("Local tokenizer ready")
            guard tokenizer.convertTokenToId("<|30.00|>") == checkpoint.vocabularySize - 1 else {
                throw LocalSpeechError("Tokenizer vocabulary does not match \(checkpoint.modelDirectoryName).")
            }
            let loaded = try await WhisperKit(WhisperKitConfig(
                model: checkpoint.modelDirectoryName,
                modelFolder: modelDirectory.path,
                tokenizerFolder: tokenizerDirectory,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuOnly,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                prewarm: false,
                load: false,
                download: false
            ))
            candidate = loaded
            loaded.tokenizer = localTokenizer
            // Injection skips automatic multilingual detection; both supported models are multilingual.
            loaded.textDecoder.isModelMultilingual = true
            // SDK 1.1.0 loads each component sequentially in both passes.
            logger.notice("Core ML sequential prewarm begin")
            try await loaded.prewarmModels()
            try Task.checkCancellation()
            logger.notice("Core ML sequential prewarm complete; loading models")
            try await loaded.loadModels()
            try Task.checkCancellation()
            logger.notice("Core ML models loaded")
            guard loaded.textDecoder.logitsSize == checkpoint.vocabularySize,
                  loaded.audioEncoder.embedSize == checkpoint.encoderSize else {
                throw LocalSpeechError("Core ML model shapes do not match \(checkpoint.modelDirectoryName).")
            }
            engine = loaded
            preparedDirectory = root
            preparationNotes = "WhisperKit 1.1.0; \(checkpoint.modelDirectoryName); local tokenizer openai/\(checkpoint.tokenizerName); downloads disabled; sequential prewarm/load; mel CPU only, encoder/decoder CPU/Neural Engine (simulator: CPU); no GPU dependency; bounded <=30-second 16 kHz mono windows; one decode worker; model-derived word alignment."
            return preparationNotes
        } catch {
            if let candidate {
                await candidate.unloadModels()
                candidate.tokenizer = nil
            }
            if error is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            throw LocalSpeechError("Unable to prepare local Whisper assets at \(modelDirectory.path): \(error.localizedDescription)")
        }
    }

    /// Returns original-file times, independent of playback speed. No microphone is opened.
    public func transcribe(file: URL, from start: Double, to end: Double, wordTimestamps: Bool = true) async throws -> [RecognizedPhrase] {
        try Task.checkCancellation()
        guard !isBusy else { throw LocalSpeechError("Whisper is already preparing, transcribing, or unloading.") }
        guard let engine else { throw LocalSpeechError("Prepare Whisper before transcribing.") }
        guard file.isFileURL else { throw LocalSpeechError("Whisper accepts only a saved local audio file.") }
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 30 else {
            throw LocalSpeechError("Request a finite audio window longer than zero and no longer than 30 seconds.")
        }
        isBusy = true
        defer { finishOperation() }
        detectedLanguage = nil

        let window = try autoreleasepool { try Self.readWindow(file: file, start: start, end: end) }
        try Task.checkCancellation()
        guard !window.samples.isEmpty else { return [] }
        let results = try await engine.transcribe(
            audioArray: window.samples,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: nil,
                usePrefillPrompt: true,
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: wordTimestamps,
                promptTokens: nil,
                prefixTokens: nil,
                concurrentWorkerCount: 1
            ),
            callback: { _ in Task.isCancelled ? false : nil }
        )
        // The SDK can return partial results normally after cancellation.
        try Task.checkCancellation()
        var phrases: [RecognizedPhrase] = []
        for result in results {
            if wordTimestamps,
               !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !result.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                throw LocalSpeechError("Whisper recognized text but did not provide aligned phrases.")
            }
            for segment in result.segments {
                guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard segment.start.isFinite, segment.end.isFinite, segment.end >= segment.start else {
                    throw LocalSpeechError("Whisper returned invalid phrase timestamps.")
                }
                let alignedWords = segment.words ?? []
                if wordTimestamps && !alignedWords.contains(where: { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    throw LocalSpeechError("Whisper recognized text but did not provide model-derived word alignment.")
                }
                let words = try alignedWords.map { word -> RecognizedWord in
                    guard word.start.isFinite, word.end.isFinite, word.end >= word.start else {
                        throw LocalSpeechError("Whisper returned invalid word alignment.")
                    }
                    return RecognizedWord(
                        start: min(end, max(start, window.start + Double(word.start))),
                        end: min(end, max(start, window.start + Double(word.end))),
                        text: word.word
                    )
                }
                phrases.append(RecognizedPhrase(
                    start: min(end, max(start, window.start + Double(segment.start))),
                    end: min(end, max(start, window.start + Double(segment.end))),
                    text: segment.text,
                    words: words
                ))
            }
        }
        detectedLanguage = results.first(where: { !$0.text.isEmpty })?.language
        return phrases
    }

    /// The caller cancels and awaits its inference task first. Also safely waits if a
    /// call is already in flight; Core ML must never be unloaded underneath prediction.
    public func unload() async {
        while isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        isBusy = true
        defer { finishOperation() }
        if let engine {
            await engine.unloadModels()
            engine.tokenizer = nil
        }
        engine = nil
        preparedDirectory = nil
        preparationNotes = ""
        detectedLanguage = nil
    }

    private func finishOperation() {
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func requireAsset(_ url: URL, directory: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == directory else {
            throw LocalSpeechError("Missing local Whisper asset: \(url.path). Stage complete assets first; no download will be attempted.")
        }
    }

    private static func readWindow(file: URL, start: Double, end: Double) throws -> (samples: [Float], start: Double) {
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = audio.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, end <= Double(audio.length) / rate + 1 / rate else {
            throw LocalSpeechError("Requested audio has not been committed to the saved file yet.")
        }
        // Round inward so decoding never reads beyond the requested source window.
        let first = AVAudioFramePosition((start * rate).rounded(.up))
        let last = min(audio.length, AVAudioFramePosition((end * rate).rounded(.down)))
        guard last > first else { return ([], start) }
        let count = last - first
        guard count <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw LocalSpeechError("Unable to allocate the bounded audio window.")
        }
        audio.framePosition = first
        try audio.read(into: buffer, frameCount: AVAudioFrameCount(count))
        // A reader of an open CAF can return a positive short read even though
        // more committed frames are available. Append subsequent reads in place.
        if buffer.frameLength < AVAudioFrameCount(count) {
            guard buffer.frameLength > 0,
                  let destination = buffer.floatChannelData,
                  let remainder = AVAudioPCMBuffer(
                    pcmFormat: audio.processingFormat,
                    frameCapacity: min(16_384, AVAudioFrameCount(count) - buffer.frameLength)
                  ),
                  let source = remainder.floatChannelData else {
                throw LocalSpeechError("The saved audio window is incomplete; try again after capture commits it.")
            }
            while buffer.frameLength < AVAudioFrameCount(count) {
                try Task.checkCancellation()
                let remaining = AVAudioFrameCount(count) - buffer.frameLength
                try audio.read(into: remainder, frameCount: min(remaining, remainder.frameCapacity))
                guard remainder.frameLength > 0 else {
                    throw LocalSpeechError("The saved audio window is incomplete; try again after capture commits it.")
                }
                for channel in 0..<Int(audio.processingFormat.channelCount) {
                    destination[channel].advanced(by: Int(buffer.frameLength)).update(
                        from: source[channel], count: Int(remainder.frameLength)
                    )
                }
                buffer.frameLength += remainder.frameLength
            }
        }
        try Task.checkCancellation()
        guard let mono = AudioProcessor.convertToMono(buffer, mode: .sumChannels(nil)) else {
            throw LocalSpeechError("Unable to convert the audio window to mono.")
        }
        let converted: AVAudioPCMBuffer
        if rate == 16_000 {
            converted = mono
        } else {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let converter = AVAudioConverter(from: mono.format, to: format),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((Double(count) / rate * 16_000).rounded(.up))) else {
                throw LocalSpeechError("Unable to create the 16 kHz audio converter.")
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if supplied {
                    state.pointee = .endOfStream
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return mono
            }
            if let conversionError { throw conversionError }
            guard status != .error, output.frameLength > 0 else {
                throw LocalSpeechError("Unable to resample the audio window to 16 kHz.")
            }
            converted = output
        }
        guard converted.frameLength <= 480_000, let channel = converted.floatChannelData?[0] else {
            throw LocalSpeechError("Invalid resampled audio window.")
        }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))), Double(first) / rate)
    }
}
