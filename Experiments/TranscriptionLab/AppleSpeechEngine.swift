import AVFoundation
import CoreMedia
import Foundation
import Speech

// Uses the file API shipped in the iOS/macOS 26 SDK, not the newer input providers.
// https://developer.apple.com/documentation/speech/speechanalyzer/analyzesequence(from:)
// https://developer.apple.com/documentation/speech/assetinventory
@available(iOS 26.0, macOS 26.0, *)
actor AppleSpeechEngine: LabEngine {
    private let localeIdentifier: String
    private var preparedLocale: Locale?
    private var operationInProgress = false

    init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
    }

    func prepare(modelsDirectory _: URL) async throws -> String {
        guard !operationInProgress else { throw EngineError.busy }
        operationInProgress = true
        defer { operationInProgress = false }
        preparedLocale = nil
        try Task.checkCancellation()

        guard SpeechTranscriber.isAvailable else { throw EngineError.unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw EngineError.unsupportedLocale(localeIdentifier)
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        let initialStatus = await AssetInventory.status(forModules: [transcriber])
        guard initialStatus != .unsupported else {
            throw EngineError.assetsUnavailable(locale.identifier, String(describing: initialStatus))
        }
        try Task.checkCancellation()
        try await AssetInventory.reserve(locale: locale)

        // OS-managed downloads belong to preparation, never to a measured file run.
        if initialStatus != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        }
        try Task.checkCancellation()
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            throw EngineError.assetsUnavailable(locale.identifier, String(describing: status))
        }

        let analyzer = Self.makeAnalyzer(transcriber: transcriber)
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.prepareToAnalyze(in: nil)
                try Task.checkCancellation()
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        await analyzer.cancelAndFinishNow()
        try Task.checkCancellation()
        preparedLocale = locale

        let assetNote = initialStatus == .installed ? "already installed" : "installed during preparation"
        return "Apple SpeechTranscriber \(locale.identifier); OS-managed assets \(assetNote); "
            + "model preheated with processLifetime retention. Asset versions and storage are managed by macOS/iOS, not modelsDirectory."
    }

    func transcribe(file: URL) async throws -> LabTranscript {
        guard !operationInProgress else { throw EngineError.busy }
        guard let locale = preparedLocale else { throw EngineError.notPrepared }
        operationInProgress = true
        defer { operationInProgress = false }
        try Task.checkCancellation()

        guard SpeechTranscriber.isAvailable else { throw EngineError.unsupportedDevice }
        let transcriber = Self.makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            throw EngineError.assetsUnavailable(locale.identifier, String(describing: status))
        }
        try Task.checkCancellation()
        let audioFile = try AVAudioFile(forReading: file)
        let analyzer = Self.makeAnalyzer(transcriber: transcriber)

        // A finished analyzer cannot be reused. Each file gets its own zero-based timeline;
        // processLifetime retention shares the preheated system model across these sessions.
        return try await withTaskCancellationHandler {
            async let transcript = Self.collectResults(from: transcriber, locale: locale)
            do {
                try Task.checkCancellation()
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                    let result = try await transcript
                    try Task.checkCancellation()
                    return result
                }

                // nil means no audio samples. Close the unused result stream; its internal
                // cancellation is not a recognition failure or a reason to invent text.
                await analyzer.cancelAndFinishNow()
                try Task.checkCancellation()
                return LabTranscript(text: "", language: locale.identifier, segments: [])
            } catch {
                // Finish before the async-let scope waits for its result consumer to exit.
                await analyzer.cancelAndFinishNow()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private nonisolated static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    private nonisolated static func makeAnalyzer(transcriber: SpeechTranscriber) -> SpeechAnalyzer {
        SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
    }

    private nonisolated static func collectResults(
        from transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws -> LabTranscript {
        var text = ""
        var segments: [LabSegment] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            let phrase = String(result.text.characters)
            // Each final result is a non-overlapping phrase/passage with a real audio range.
            // Preserve its text verbatim, including spacing between successive phrases.
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            guard start.isFinite, end.isFinite, end >= start else {
                throw EngineError.invalidTimeRange
            }
            text.append(phrase)
            segments.append(LabSegment(start: start, end: end, text: phrase))
        }
        return LabTranscript(text: text, language: locale.identifier, segments: segments)
    }

    private enum EngineError: LocalizedError {
        case busy
        case notPrepared
        case unsupportedDevice
        case unsupportedLocale(String)
        case assetsUnavailable(String, String)
        case invalidTimeRange

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Apple Speech is already preparing or transcribing a file."
            case .notPrepared:
                return "Call AppleSpeechEngine.prepare before transcribing a file."
            case .unsupportedDevice:
                return "SpeechTranscriber is unavailable on this device. No other recognizer or cloud fallback is used."
            case .unsupportedLocale(let identifier):
                return "SpeechTranscriber does not support locale \(identifier) on this device."
            case .assetsUnavailable(let identifier, let status):
                return "Apple Speech assets for \(identifier) are not ready (\(status)). Run prepare to install them outside the measured transcription."
            case .invalidTimeRange:
                return "Apple Speech returned a final transcription with an invalid audio time range."
            }
        }
    }
}
