import Foundation
import FluidAudio

/// FluidAudio 0.17.5, Parakeet Ultra (post-trained TDT 0.6b v3, int8 encoder).
/// Stage FluidInference/parakeet-ultra-coreml revision
/// 95eaa59a39d4394f047a4dc5cce480388a60d1b6 under Models/parakeet-ultra-coreml:
/// Encoder.mlmodelc, Decoder.mlmodelc, JointDecisionv3.mlmodelc,
/// Preprocessor.mlmodelc (complete bundles), and parakeet_vocab.json.
/// https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/ParakeetUltra.md
actor ParakeetEngine: LabEngine {
    private let version: AsrModelVersion
    private var manager: AsrManager?
    private var preparedDirectory: URL?
    private var isTranscribing = false

    init() {
        version = .ultra
        // Process-wide vendor switch; never restore it to an online default.
        ModelHub.offlineMode = true
    }

    func prepare(modelsDirectory: URL) async throws -> String {
        try Task.checkCancellation()
        guard !isTranscribing else { throw EngineError.busy }
        ModelHub.offlineMode = true
        let directory = modelsDirectory.appendingPathComponent("parakeet-ultra-coreml", isDirectory: true)
        let notes = "FluidAudio 0.17.5; Parakeet Ultra 0.6b (int8 encoder); local-only: \(directory.path); "
            + "CPU preprocessor, CPU/Neural Engine recognition, one chunk at a time; "
            + "SDK disk-backed audio above 30 seconds; token-level timestamps; no language hint."
        if manager != nil, preparedDirectory == directory { return notes }

        let models: AsrModels
        do {
            // Unlike load/downloadAndLoad, loadLocal never resolves a repository,
            // repairs a cache, downloads missing assets, or substitutes weights.
            models = try AsrModels.loadLocal(from: directory, version: version)
        } catch {
            throw EngineError.localModel(directory, error.localizedDescription)
        }
        try Task.checkCancellation()
        manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
        preparedDirectory = directory
        return notes
    }

    func transcribe(file: URL) async throws -> LabTranscript {
        try Task.checkCancellation()
        guard let manager else { throw EngineError.notPrepared }
        guard !isTranscribing else { throw EngineError.busy }
        isTranscribing = true
        defer { isTranscribing = false }

        // New decoder state for each recording; keep only the heavy models warm.
        var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
        // This direct async call preserves task cancellation into the vendor's
        // chunk/decode cancellation checks; no detached task or result stream.
        let result = try await manager.transcribe(file, decoderState: &state)
        try Task.checkCancellation()
        return LabTranscript(
            text: result.text,
            language: nil, // ASRResult does not report an identified language.
            segments: (result.tokenTimings ?? []).map {
                LabSegment(start: $0.startTime, end: $0.endTime, text: $0.token)
            }
        )
    }

    private enum EngineError: LocalizedError {
        case notPrepared
        case busy
        case localModel(URL, String)

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "Prepare Parakeet Ultra's local model assets before transcribing."
            case .busy:
                return "Parakeet Ultra is already transcribing a recording."
            case .localModel(let directory, let detail):
                return "Cannot load Parakeet Ultra from \(directory.path). Stage the complete "
                    + "Encoder.mlmodelc, Decoder.mlmodelc, JointDecisionv3.mlmodelc, "
                    + "Preprocessor.mlmodelc bundles and parakeet_vocab.json. "
                    + "No download or model fallback was attempted. \(detail)"
            }
        }
    }
}
