import AVFoundation
import Foundation

public enum LabModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple = "apple"
    case whisperBase = "whisper-base"
    case whisperTurbo = "whisper-turbo"
    case parakeet = "parakeet-ultra"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .apple: return "Apple Speech · English (US)"
        case .whisperBase: return "Whisper Base · multilingual"
        case .whisperTurbo: return "Whisper Turbo · compressed"
        case .parakeet: return "Parakeet Ultra · multilingual"
        }
    }

    var assetDirectory: String? {
        switch self {
        case .apple: return nil
        case .whisperBase: return "openai_whisper-base"
        case .whisperTurbo: return "openai_whisper-large-v3-v20240930_626MB"
        case .parakeet: return "parakeet-ultra-coreml"
        }
    }

    func makeEngine() -> any LabEngine {
        switch self {
        case .apple: return AppleSpeechEngine()
        case .whisperBase, .whisperTurbo: return WhisperEngine(modelDirectoryName: assetDirectory!)
        case .parakeet: return ParakeetEngine()
        }
    }
}

public struct LabSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}

public struct LabTranscript: Codable, Sendable {
    public let text: String
    public let language: String?
    public let segments: [LabSegment]
}

protocol LabEngine: Sendable {
    func prepare(modelsDirectory: URL) async throws -> String
    func transcribe(file: URL) async throws -> LabTranscript
}

public struct LabRecording: Identifiable, Sendable {
    public var id: String { filename }
    public let filename: String
    public let title: String
    public let createdAt: Date
    public let duration: Double
    public let url: URL

    public static func load(from directory: URL) throws -> [LabRecording] {
        struct Header: Decodable { let title: String; let createdAt: Date }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )
        return try files.filter { $0.pathExtension.lowercased() == "caf" }.map { url in
            let file = try AVAudioFile(forReading: url)
            let sidecar = url.deletingPathExtension().appendingPathExtension("metadata.json")
            let header = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(Header.self, from: $0) }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return LabRecording(filename: url.lastPathComponent, title: header?.title ?? url.deletingPathExtension().lastPathComponent,
                                createdAt: header?.createdAt ?? modified ?? .distantPast,
                                duration: Double(file.length) / file.processingFormat.sampleRate, url: url)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

public struct LabMeasurement: Codable, Identifiable, Sendable {
    public var id: String { "\(filename)#\(pass)" }
    public let filename: String
    public let recordingTitle: String
    public let audioSeconds: Double
    public let pass: Int
    public let processingSeconds: Double
    public let thermalState: String
    public let transcript: LabTranscript?
    public let error: String?
    public var realTimeFactor: Double { processingSeconds / audioSeconds }
}

public struct LabReport: Codable, Identifiable, Sendable {
    public let id: UUID
    public let model: LabModel
    public let device: String
    public let osVersion: String
    public let startedAt: Date
    public var status: String
    public var preparationSeconds: Double?
    public var preparationNotes: String?
    public var modelAssetBytes: Int64?
    public var peakAppMemoryMB: Double?
    public var measurements: [LabMeasurement]
    public var error: String?

    public func save(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    public static func load(from directory: URL) throws -> [LabReport] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(LabReport.self, from: Data(contentsOf: $0))
        }.sorted { $0.startedAt > $1.startedAt }
    }
}
