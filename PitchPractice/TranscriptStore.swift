import Foundation
import LocalSpeech

enum TranscriptStatus: String, Codable, Sendable {
    case recording, queued, transcribing, paused, complete, failed
}

struct TranscriptPhrase: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let start: Double
    let end: Double
    let text: String
}

struct TranscriptWord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let start: Double
    let end: Double
    let text: String
}

struct TakeTranscript: Codable, Sendable {
    static let currentVersion = 2

    var version: Int
    var modelID: String
    var audioFilename: String
    var duration: Double
    var processedThrough: Double
    var isFinal: Bool
    var status: TranscriptStatus
    var message: String?
    var phrases: [TranscriptPhrase]
    var words: [TranscriptWord]
    // Keep the saved phrase transcript visible until its word timing upgrade finishes.
    var previousPhrases: [TranscriptPhrase]?
    // Only the recent alignment context is needed to reconcile the next core.
    var boundaryWords: [RecognizedWord]
    fileprivate var source: TranscriptSource?

    var requiresWordTimings: Bool { version == 1 }
    var displayPhrases: [TranscriptPhrase] { previousPhrases ?? phrases }

    init(audioURL: URL, duration: Double, isFinal: Bool) {
        version = Self.currentVersion
        modelID = TranscriptStore.modelID
        audioFilename = audioURL.lastPathComponent
        self.duration = duration
        processedThrough = 0
        self.isFinal = isFinal
        status = isFinal ? .queued : .recording
        message = nil
        phrases = []
        words = []
        previousPhrases = nil
        boundaryWords = []
        source = try? TranscriptSource(url: audioURL, sealed: isFinal)
    }

    func preparingWordTimings() -> TakeTranscript {
        guard requiresWordTimings else { return self }
        var result = self
        result.version = Self.currentVersion
        result.processedThrough = 0
        result.previousPhrases = phrases
        result.phrases = []
        result.words = []
        result.boundaryWords = []
        result.status = isFinal ? .queued : .recording
        result.message = nil
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case version, modelID, audioFilename, duration, processedThrough, isFinal, status, message
        case phrases, words, previousPhrases, boundaryWords, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 || version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported transcript version."
            )
        }
        modelID = try container.decode(String.self, forKey: .modelID)
        audioFilename = try container.decode(String.self, forKey: .audioFilename)
        duration = try container.decode(Double.self, forKey: .duration)
        processedThrough = try container.decode(Double.self, forKey: .processedThrough)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        status = try container.decode(TranscriptStatus.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        phrases = try container.decode([TranscriptPhrase].self, forKey: .phrases)
        boundaryWords = try container.decode([RecognizedWord].self, forKey: .boundaryWords)
        source = try container.decodeIfPresent(TranscriptSource.self, forKey: .source)
        if version == 1 {
            words = []
            previousPhrases = nil
        } else {
            words = try container.decode([TranscriptWord].self, forKey: .words)
            previousPhrases = try container.decodeIfPresent([TranscriptPhrase].self, forKey: .previousPhrases)
        }
    }
}

struct TranscriptWindow: Sendable {
    let inputStart: Double
    let inputEnd: Double
    let commitStart: Double
    let commitEnd: Double

    static func next(processedThrough: Double, availableDuration: Double, isFinal: Bool) -> TranscriptWindow? {
        guard processedThrough.isFinite, availableDuration.isFinite,
              processedThrough >= 0, availableDuration > processedThrough else { return nil }
        let coreEnd = (floor(processedThrough / 20) + 1) * 20
        guard coreEnd > processedThrough,
              isFinal || availableDuration >= coreEnd + 5 else { return nil }
        let commitEnd = min(coreEnd, availableDuration)
        return TranscriptWindow(
            inputStart: max(0, processedThrough - 5),
            inputEnd: min(availableDuration, commitEnd + 5),
            commitStart: processedThrough,
            commitEnd: commitEnd
        )
    }
}

struct TranscriptStore: Sendable {
    static let modelID = "openai_whisper-large-v3-v20240930_626MB@0f63a7800b00dd0226abd051b906c246e1907482/whisperkit-1.1.0/core20-context5-v1"

    func load(for audioURL: URL) throws -> TakeTranscript? {
        let url = sidecarURL(for: audioURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let transcript = try? JSONDecoder().decode(TakeTranscript.self, from: data),
              isValid(transcript, for: audioURL),
              let source = transcript.source,
              (try? source.matches(url: audioURL)) == true else { return nil }
        return transcript
    }

    func save(_ transcript: TakeTranscript, for audioURL: URL) throws {
        guard isValid(transcript, for: audioURL) else { throw TranscriptStoreError.invalidCheckpoint }
        if let source = transcript.source, try !source.matches(url: audioURL) {
            throw TranscriptStoreError.audioChanged
        }
        var checkpoint = transcript
        checkpoint.source = try TranscriptSource(url: audioURL, sealed: transcript.isFinal)
        try JSONEncoder().encode(checkpoint).write(to: sidecarURL(for: audioURL), options: .atomic)
    }

    func delete(for audioURL: URL) throws {
        let url = sidecarURL(for: audioURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func pending(in directory: URL) throws -> [(URL, TakeTranscript)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var pending: [(URL, TakeTranscript)] = []
        for sidecar in urls where sidecar.lastPathComponent.hasSuffix(".transcript.json") {
            let audioURL = sidecar.deletingPathExtension().deletingPathExtension().appendingPathExtension("caf")
            if let transcript = try load(for: audioURL), transcript.status != .complete {
                pending.append((audioURL, transcript))
            }
        }
        return pending.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    func merging(_ phrases: [RecognizedPhrase], window: TranscriptWindow, into transcript: TakeTranscript) -> TakeTranscript {
        var result = transcript
        guard window.commitStart == transcript.processedThrough,
              window.inputStart.isFinite, window.inputEnd.isFinite,
              window.commitStart.isFinite, window.commitEnd.isFinite,
              window.inputStart >= 0, window.inputStart <= window.commitStart,
              window.commitStart < window.commitEnd, window.commitEnd <= window.inputEnd,
              window.inputEnd <= transcript.duration, window.inputEnd - window.inputStart <= 30 else {
            result.status = .failed
            result.message = "The transcription window does not match the saved recording cursor."
            return result
        }
        let isFinalWindow = transcript.isFinal && window.commitEnd == transcript.duration
        var recent = transcript.boundaryWords
        var committed: [TranscriptPhrase] = []
        var committedWords: [TranscriptWord] = []
        for phrase in phrases {
            guard (phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !phrase.words.isEmpty),
                  phrase.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
                result.status = .failed
                result.message = "Word timing is unavailable for this transcription window. Please retry."
                return result
            }
            var start = Double.infinity
            var end = 0.0
            var text = ""
            for word in phrase.words {
                let midpoint = word.start + (word.end - word.start) / 2
                guard midpoint >= window.commitStart,
                      midpoint < window.commitEnd || (isFinalWindow && midpoint == window.commitEnd) else { continue }
                let label = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                let clipped = RecognizedWord(
                    start: min(transcript.duration, word.start),
                    end: min(transcript.duration, word.end), text: word.text
                )
                guard !recent.contains(where: { duplicates($0, clipped) }) else { continue }
                start = min(start, clipped.start)
                end = max(end, clipped.end)
                text.append(clipped.text)
                recent.append(clipped)
                committedWords.append(TranscriptWord(
                    id: UUID(), start: clipped.start, end: clipped.end, text: label
                ))
            }
            if start.isFinite {
                committed.append(TranscriptPhrase(
                    id: UUID(), start: start, end: end,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
        result.phrases.append(contentsOf: committed.sorted { $0.start < $1.start })
        committedWords.sort { $0.start < $1.start }
        result.words.append(contentsOf: committedWords)
        result.processedThrough = window.commitEnd
        result.boundaryWords = recent.filter { $0.end >= window.commitEnd - 5 }
        result.message = nil
        result.status = isFinalWindow ? .complete : (transcript.isFinal ? .queued : .recording)
        if isFinalWindow { result.previousPhrases = nil }
        return result
    }

    private func duplicates(_ lhs: RecognizedWord, _ rhs: RecognizedWord) -> Bool {
        let overlaps = max(lhs.start, rhs.start) < min(lhs.end, rhs.end)
            || (lhs.start == lhs.end && rhs.start == rhs.end && lhs.start == rhs.start)
        guard overlaps else { return false }
        func token(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        }
        let lhsToken = token(lhs.text)
        return !lhsToken.isEmpty && lhsToken == token(rhs.text)
    }

    private func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    private func isValid(_ transcript: TakeTranscript, for audioURL: URL) -> Bool {
        guard transcript.version == 1 || transcript.version == TakeTranscript.currentVersion,
              transcript.modelID == Self.modelID,
              transcript.audioFilename == audioURL.lastPathComponent,
              transcript.duration.isFinite, transcript.duration >= 0,
              transcript.processedThrough.isFinite, transcript.processedThrough >= 0,
              transcript.processedThrough <= transcript.duration,
              transcript.status != .complete || (transcript.isFinal && transcript.processedThrough == transcript.duration),
              transcript.version != 1 || (transcript.words.isEmpty && transcript.previousPhrases == nil),
              Set(transcript.words.map(\.id)).count == transcript.words.count else { return false }
        func validPhrases(_ phrases: [TranscriptPhrase]) -> Bool {
            Set(phrases.map(\.id)).count == phrases.count && phrases.allSatisfy {
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                    && $0.end <= transcript.duration && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return validPhrases(transcript.phrases)
            && (transcript.previousPhrases.map(validPhrases) ?? true)
            && transcript.words.allSatisfy {
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                    && $0.end <= transcript.duration && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } && transcript.boundaryWords.allSatisfy {
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= transcript.duration
            }
    }
}

// An unfinished CAF can append samples and rewrite its data-chunk length on close.
// Check its identity and bounded payload probes, not that mutable header or mtime.
// Once finalized, both size and mtime must also match. No audio is decoded or written.
fileprivate struct TranscriptSource: Codable, Sendable {
    struct Probe: Codable, Sendable {
        let offset: UInt64
        let bytes: Data
    }

    let fileNumber: UInt64
    let deviceNumber: UInt64
    let createdAt: Date
    let byteCount: UInt64
    let modifiedAt: Date
    let dataOffset: UInt64
    let format: Data
    let sealed: Bool
    let probes: [Probe]

    init(url: URL, sealed: Bool, probePayload: Bool = true) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber,
              let deviceNumber = attributes[.systemNumber] as? NSNumber,
              let createdAt = attributes[.creationDate] as? Date,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let byteCount = attributes[.size] as? NSNumber else { throw TranscriptStoreError.invalidAudio }
        self.fileNumber = fileNumber.uint64Value
        self.deviceNumber = deviceNumber.uint64Value
        self.createdAt = createdAt
        self.byteCount = byteCount.uint64Value
        self.modifiedAt = modifiedAt
        self.sealed = sealed
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let layout = try Self.audioLayout(file: file, byteCount: self.byteCount)
        dataOffset = layout.offset
        format = layout.format
        let payloadCount = self.byteCount - dataOffset
        let length = min(payloadCount, 128)
        if length == 0 || !probePayload {
            probes = []
        } else {
            let offsets = Set([dataOffset, dataOffset + (payloadCount - length) / 2, self.byteCount - length]).sorted()
            probes = try offsets.map { offset in
                try file.seek(toOffset: offset)
                let bytes = try file.read(upToCount: Int(length)) ?? Data()
                guard bytes.count == Int(length) else { throw TranscriptStoreError.audioChanged }
                return Probe(offset: offset, bytes: bytes)
            }
        }
    }

    func matches(url: URL) throws -> Bool {
        let current = try TranscriptSource(url: url, sealed: sealed, probePayload: false)
        guard current.fileNumber == fileNumber, current.deviceNumber == deviceNumber,
              current.createdAt == createdAt, current.dataOffset == dataOffset, current.format == format,
              current.byteCount >= byteCount,
              !sealed || (current.byteCount == byteCount && current.modifiedAt == modifiedAt) else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        for probe in probes {
            try file.seek(toOffset: probe.offset)
            guard try file.read(upToCount: probe.bytes.count) == probe.bytes else { return false }
        }
        return true
    }

    private static func audioLayout(file: FileHandle, byteCount: UInt64) throws -> (offset: UInt64, format: Data) {
        let header = try file.read(upToCount: 8) ?? Data()
        guard header.count == 8, header.prefix(4) == Data("caff".utf8) else { throw TranscriptStoreError.invalidAudio }
        var offset: UInt64 = 8
        var format: Data?
        while offset <= byteCount, byteCount - offset >= 12 {
            try file.seek(toOffset: offset)
            let chunk = try file.read(upToCount: 12) ?? Data()
            guard chunk.count == 12 else { throw TranscriptStoreError.invalidAudio }
            let kind = chunk.prefix(4)
            let size = chunk.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            offset += 12
            if kind == Data("data".utf8) {
                guard byteCount - offset >= 4, let format else { throw TranscriptStoreError.invalidAudio }
                return (offset + 4, format)
            }
            guard size <= byteCount - offset else { throw TranscriptStoreError.invalidAudio }
            if kind == Data("desc".utf8) {
                guard size == 32 else { throw TranscriptStoreError.invalidAudio }
                format = try file.read(upToCount: 32)
                guard format?.count == 32 else { throw TranscriptStoreError.invalidAudio }
            }
            offset += size
        }
        throw TranscriptStoreError.invalidAudio
    }
}

private enum TranscriptStoreError: LocalizedError {
    case invalidCheckpoint, invalidAudio, audioChanged

    var errorDescription: String? {
        switch self {
        case .invalidCheckpoint: return "The transcript checkpoint does not match the recording timeline or transcription model."
        case .invalidAudio: return "The recording's CAF source identity could not be read."
        case .audioChanged: return "The original recording changed. Analyze it again to create a matching transcript."
        }
    }
}
