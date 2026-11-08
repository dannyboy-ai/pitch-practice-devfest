import Accelerate
import AVFoundation
import Foundation

struct PracticeTake: Identifiable, Hashable, Sendable {
    var id: String { audioURL.lastPathComponent }
    let audioURL: URL
    var title: String
    let createdAt: Date
    let duration: Double

    var timeLabel: String { Self.timeFormatter.string(from: createdAt) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
}

struct RecordingStore: Sendable {
    let directory: URL

    init(directory: URL = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func recordings() throws -> [PracticeTake] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var takes: [PracticeTake] = []
        for url in urls where url.pathExtension.lowercased() == "caf" {
            let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey])
            guard properties?.isRegularFile != false else { continue }
            let metadata = readMetadata(for: url)
            // Opening a CAF reads its header, not its sample data. A damaged CAF
            // remains visible (and deletable); opening its review surfaces the error.
            let duration: Double
            do {
                let audio = try openAudio(url)
                duration = Double(audio.length) / audio.processingFormat.sampleRate
            } catch {
                duration = 0
            }
            takes.append(PracticeTake(
                audioURL: url,
                title: metadata?.title ?? "Take",
                createdAt: metadata?.createdAt ?? properties?.creationDate ?? properties?.contentModificationDate ?? .distantPast,
                duration: duration
            ))
        }
        return takes.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

    func newRecordingURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
    }

    func saveAnalysis(_ analysis: TakeAnalysis, for audioURL: URL) throws {
        let audio = try openAudio(audioURL)
        let source = try AudioSource(url: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let title = analysis.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = TakeAnalysis(
            title: title.isEmpty ? "Take" : title,
            createdAt: analysis.createdAt,
            duration: duration,
            frames: analysis.frames
        )
        guard analysis.version == TakeAnalysis.currentVersion,
              isValid(canonical, sampleRate: audio.processingFormat.sampleRate) else {
            throw StoreError.invalidAnalysis
        }
        let encoder = JSONEncoder()
        let cached = CachedAnalysis(source: source, analysis: canonical)
        try encoder.encode(cached).write(to: traceURL(for: audioURL), options: .atomic)
        let metadata = Metadata(analysis: canonical, source: source)
        try encoder.encode(metadata).write(to: metadataURL(for: audioURL), options: .atomic)
    }

    func analysis(for take: PracticeTake) throws -> TakeAnalysis {
        try Task.checkCancellation()
        // Always open the original audio: a stale sidecar cannot make damaged or
        // missing audio look playable, and the actual frame count owns duration.
        let audio = try openAudio(take.audioURL)
        let sampleRate = audio.processingFormat.sampleRate
        let duration = Double(audio.length) / sampleRate
        let source = try AudioSource(url: take.audioURL)
        let metadata = readMetadata(for: take.audioURL)
        if let data = try? Data(contentsOf: traceURL(for: take.audioURL)),
           let cached = try? JSONDecoder().decode(CachedAnalysis.self, from: data),
           cached.source == source,
           cached.analysis.duration == duration,
           isValid(cached.analysis, sampleRate: sampleRate) {
            try Task.checkCancellation()
            if metadata == nil {
                let recovered = Metadata(analysis: cached.analysis, source: source)
                try JSONEncoder().encode(recovered).write(to: metadataURL(for: take.audioURL), options: .atomic)
            }
            return TakeAnalysis(
                title: metadata?.title ?? cached.analysis.title,
                createdAt: metadata?.createdAt ?? cached.analysis.createdAt,
                duration: duration,
                frames: cached.analysis.frames
            )
        }

        let chunkSize: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunkSize) else {
            throw StoreError.invalidAudio
        }
        let analyzer = PitchAnalyzer(sampleRate: sampleRate, maximumFrameCount: Int(chunkSize))
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: Int(chunkSize))
        defer { mono.deallocate() }
        var frames: [PitchFrame] = []
        let expectedFrames = audio.length / AVAudioFramePosition(chunkSize) + 1
        if expectedFrames <= AVAudioFramePosition(Int.max) { frames.reserveCapacity(Int(expectedFrames)) }
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            let start = audio.framePosition
            try audio.read(into: buffer, frameCount: chunkSize)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { throw StoreError.unexpectedEnd }
            let estimate: PitchEstimate
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 {
                estimate = analyzer.analyze(channels[0], count: count)
            } else {
                let length = vDSP_Length(count)
                vDSP_vclr(mono, 1, length)
                for channel in 0..<channelCount {
                    vDSP_vadd(mono, 1, channels[channel], 1, mono, 1, length)
                }
                var divisor = Float(channelCount)
                vDSP_vsdiv(mono, 1, &divisor, mono, 1, length)
                estimate = analyzer.analyze(mono, count: count)
            }
            frames.append(PitchFrame(
                time: Double(start) / sampleRate,
                duration: Double(count) / sampleRate,
                midi: estimate.midi,
                confidence: estimate.confidence
            ))
        }
        try Task.checkCancellation()
        let analysis = TakeAnalysis(
            title: metadata?.title ?? take.title,
            createdAt: metadata?.createdAt ?? take.createdAt,
            duration: duration,
            frames: frames
        )
        // Do not label a cache with a different source if the CAF changed during
        // analysis. The original audio itself is never rewritten or migrated.
        guard try AudioSource(url: take.audioURL) == source else { throw StoreError.audioChanged }
        try saveAnalysis(analysis, for: take.audioURL)
        return analysis
    }

    func rename(_ take: PracticeTake, to title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.emptyTitle }
        let source = try AudioSource(url: take.audioURL)
        let existing = readMetadata(for: take.audioURL)
        let metadata = Metadata(
            version: TakeAnalysis.currentVersion,
            title: title,
            createdAt: existing?.createdAt ?? take.createdAt,
            duration: existing?.duration ?? take.duration,
            source: source
        )
        // Title metadata is independent of the trace, so renaming even a long
        // legacy recording never decodes audio or allocates its pitch history.
        try JSONEncoder().encode(metadata).write(to: metadataURL(for: take.audioURL), options: .atomic)
    }

    func delete(_ take: PracticeTake) throws {
        try FileManager.default.removeItem(at: take.audioURL)
        for url in [traceURL(for: take.audioURL), metadataURL(for: take.audioURL),
                    take.audioURL.deletingPathExtension().appendingPathExtension("transcript.json")] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func openAudio(_ url: URL) throws -> AVAudioFile {
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.processingFormat.sampleRate.isFinite,
              audio.processingFormat.sampleRate > 0,
              audio.processingFormat.channelCount > 0,
              audio.length >= 0 else { throw StoreError.invalidAudio }
        return audio
    }

    private func readMetadata(for url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: url)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.version == TakeAnalysis.currentVersion,
              !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.duration.isFinite, metadata.duration >= 0 else { return nil }
        return metadata
    }

    private func isValid(_ analysis: TakeAnalysis, sampleRate: Double) -> Bool {
        guard analysis.version == TakeAnalysis.currentVersion,
              analysis.duration.isFinite, analysis.duration >= 0 else { return false }
        var previousEnd: Double = 0
        var previousStart: Double = -1
        let tolerance = 1 / sampleRate
        for frame in analysis.frames {
            guard frame.time.isFinite, frame.time >= 0,
                  frame.duration.isFinite, frame.duration > 0,
                  frame.time > previousStart,
                  frame.time >= previousEnd - tolerance,
                  frame.time < analysis.duration,
                  frame.time + frame.duration <= analysis.duration + tolerance,
                  frame.midi?.isFinite != false,
                  frame.confidence.isFinite, (0...1).contains(frame.confidence) else { return false }
            previousEnd = frame.time + frame.duration
            previousStart = frame.time
        }
        return true
    }

    private func traceURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("pitch.json")
    }

    private func metadataURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("metadata.json")
    }
}

private struct AudioSource: Codable, Equatable {
    let byteCount: Int
    let modifiedAt: Date

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let byteCount = values.fileSize, let modifiedAt = values.contentModificationDate else {
            throw StoreError.invalidAudio
        }
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

private struct CachedAnalysis: Codable {
    let source: AudioSource
    let analysis: TakeAnalysis
}

private struct Metadata: Codable {
    let version: Int
    let title: String
    let createdAt: Date
    let duration: Double
    let source: AudioSource

    init(analysis: TakeAnalysis, source: AudioSource) {
        self.init(
            version: analysis.version,
            title: analysis.title,
            createdAt: analysis.createdAt,
            duration: analysis.duration,
            source: source
        )
    }

    init(version: Int, title: String, createdAt: Date, duration: Double, source: AudioSource) {
        self.version = version
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
    }
}

private enum StoreError: LocalizedError {
    case invalidAudio
    case invalidAnalysis
    case unexpectedEnd
    case audioChanged
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "The recording's audio format or file metadata could not be read."
        case .invalidAnalysis: return "The pitch analysis does not match the recording's audio timeline."
        case .unexpectedEnd: return "The recording ended before all of its audio could be read."
        case .audioChanged: return "The recording changed while its pitch was being analyzed. Please open it again."
        case .emptyTitle: return "Enter a name for this recording."
        }
    }
}
