import AVFoundation
import Foundation
import LocalSpeech

/// The lab uses exactly the same local model/tokenizer and compute path as production.
actor WhisperEngine: LabEngine {
    private let modelDirectoryName: String
    private var transcriber: WhisperTranscriber?
    private var isBusy = false

    init(modelDirectoryName: String) {
        self.modelDirectoryName = modelDirectoryName
    }

    func prepare(modelsDirectory: URL) async throws -> String {
        guard !isBusy else { throw WhisperLabError("Whisper is already preparing or transcribing.") }
        isBusy = true
        defer { isBusy = false }
        let checkpoint: WhisperCheckpoint
        switch modelDirectoryName {
        case "openai_whisper-base": checkpoint = .base
        case "openai_whisper-large-v3-v20240930_626MB": checkpoint = .turbo
        default: throw WhisperLabError("Unsupported lab Whisper model: \(modelDirectoryName).")
        }
        let shared = transcriber ?? WhisperTranscriber(checkpoint: checkpoint)
        let notes = try await shared.prepare(modelsDirectory: modelsDirectory)
        transcriber = shared
        return notes + " Lab adapter: sequential file windows; phrase timestamps, word alignment disabled for historical benchmarks."
    }

    func transcribe(file: URL) async throws -> LabTranscript {
        try Task.checkCancellation()
        guard !isBusy else { throw WhisperLabError("Whisper is already preparing or transcribing.") }
        guard let transcriber else { throw WhisperLabError("Prepare Whisper before transcribing.") }
        isBusy = true
        defer { isBusy = false }
        let audio = try AVAudioFile(forReading: file)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        var start = 0.0
        var phrases: [RecognizedPhrase] = []
        var language: String?
        while start < duration {
            try Task.checkCancellation()
            let end = min(start + 30, duration)
            let window = try await transcriber.transcribe(file: file, from: start, to: end, wordTimestamps: false)
            phrases.append(contentsOf: window)
            if language == nil, !window.isEmpty {
                language = await transcriber.detectedLanguage
            }
            start = end
        }
        try Task.checkCancellation()
        return LabTranscript(
            text: phrases.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            language: language,
            segments: phrases.map { LabSegment(start: $0.start, end: $0.end, text: $0.text) }
        )
    }
}

private struct WhisperLabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
