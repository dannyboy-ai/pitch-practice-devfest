import AVFoundation
import Foundation

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "PitchModelsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct PitchModelsTests {
    static func main() throws {
        try detectorBoundaries()
        try timelineBoundaries()
        try tuningBoundaries()
        try reviewWindowBoundaries()
        try reviewPitchSections()
        try recordingPersistence()
        print("PASS: detector, timeline gaps, nearest-note tuning, review zoom/sections, visible pitch ranges, recording persistence")
    }

    private static func detectorBoundaries() throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = PitchAnalyzer(sampleRate: rate)
            var samples = [Float](repeating: 0, count: 4096)
            for midi in [36.0, 48.0, 57.25, 69.0, 76.0, 84.0] {
                for harmonic in [false, true] {
                    for index in samples.indices {
                        let phase = 2 * Double.pi * PitchNote.frequency(midi) * Double(index) / rate
                        let signal = harmonic ? 0.12 * sin(phase) + 0.4 * sin(phase * 2) + 0.1 * sin(phase * 3) : 0.3 * sin(phase)
                        samples[index] = Float(signal)
                    }
                    let result = samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, count: $0.count) }
                    try require(result.midi != nil && abs((result.midi ?? 0) - midi) < 0.08, "Pitch \(midi), \(rate)Hz, harmonics=\(harmonic): \(String(describing: result.midi))")
                }
            }
            for index in samples.indices { samples[index] = 0 }
            let silence = samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, count: $0.count) }
            try require(silence.midi == nil, "Silence must be a gap")
            for index in samples.indices { samples[index] = 0.1 }
            let dc = samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, count: $0.count) }
            try require(dc.midi == nil, "DC offset must not be a note")
            var random: UInt64 = 12345
            for index in samples.indices {
                random = random &* 6364136223846793005 &+ 1
                samples[index] = Float(Double(random >> 32) / Double(UInt32.max) - 0.5)
            }
            let noise = samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, count: $0.count) }
            try require(noise.midi == nil, "Unpitched noise must not be a note")
        }
    }

    private static func timelineBoundaries() throws {
        let analysis = TakeAnalysis(title: "Boundary", createdAt: Date(timeIntervalSince1970: 0), duration: 4, frames: [
            PitchFrame(time: 0.5, duration: 0.5, midi: 60, confidence: 1),
            PitchFrame(time: 1, duration: 1, midi: nil, confidence: 0),
            PitchFrame(time: 3, duration: 1, midi: 67, confidence: 1)
        ])
        try require(analysis.frame(at: 0.4) == nil, "Before first frame must not borrow a future note")
        try require(analysis.frame(at: 0.5)?.midi == 60, "Exact note start")
        try require(analysis.frame(at: 0.999)?.midi == 60, "Inside note")
        try require(analysis.frame(at: 1)?.midi == nil, "Silence must not retain previous note")
        try require(analysis.frame(at: 2.5) == nil, "Missing frames are gaps")
        try require(analysis.frame(at: 3)?.midi == 67, "Seek after gap")
        try require(analysis.frame(at: 4) == nil, "End-of-file must not retain last note")
        try require(analysis.frame(at: -.infinity) == nil && analysis.frame(at: .nan) == nil, "Invalid seek")
    }

    private static func tuningBoundaries() throws {
        try require(PitchTuning(midi: 60.25).direction == .sharp, "Above nearest note is sharp")
        try require(PitchTuning(midi: 60.85).direction == .flat, "Below nearest note is flat")
        for midi in [59.9, 60, 60.1] {
            try require(PitchTuning(midi: midi).direction == .centered,
                        "Ten-cent boundary must tolerate floating point rounding")
        }
    }

    private static func reviewWindowBoundaries() throws {
        var window = ReviewWindow(duration: 105, windowDuration: 10, start: 50)
        try require(window.time(atFraction: 0.25) == 52.5, "Seek maps to absolute section time")
        let anchor = window.time(atFraction: 0.25)
        window.zoom(by: 2, anchorFraction: 0.25)
        try require(abs(window.time(atFraction: 0.25) - anchor) < 0.000001
                    && window.windowDuration == 5, "Pinch anchor stays under the same finger")

        window = ReviewWindow(duration: 105, windowDuration: 10, start: 90)
        window.moveSection(by: 1)
        try require(window.start == 100 && window.end == 105 && !window.canMoveNext,
                    "Final partial section is reachable without spilling past audio")
        try require(window.time(atFraction: -1) == 100 && window.time(atFraction: 2) == 105,
                    "Graph seeks clamp to the visible final interval")
        window.follow(105)
        try require(window.start == 100 && window.fraction(at: 105) == 1,
                    "EOF remains in the final section")
        window.moveSection(by: -1)
        try require(window.start == 90 && window.end == 100, "Previous from a partial section keeps section spacing")
        window.follow(50)
        try require(window.start == 50 && window.end == 60, "Global scrub follows to the target section")
        window.follow(60)
        try require(window.start == 60, "Playback crossing a boundary advances the section")

        var short = ReviewWindow(duration: 0.4)
        short.zoom(by: 100)
        short.moveSection(by: 1)
        try require(short.start == 0 && short.end == 0.4 && short.time(atFraction: 0.5) == 0.2,
                    "Subsecond recordings remain navigable without a zero-length viewport")
        var empty = ReviewWindow(duration: 0)
        empty.zoom(by: 2)
        empty.moveSection(by: 1)
        try require(empty.time(atFraction: 0.5) == 0 && empty.fraction(at: 0) == 0,
                    "Empty recordings never produce nonfinite seek coordinates")
    }

    private static func reviewPitchSections() throws {
        let frames = [
            PitchFrame(time: 0, duration: 1, midi: 36, confidence: 1),
            PitchFrame(time: 9.9, duration: 0.2, midi: 66.8, confidence: 1),
            PitchFrame(time: 10.1, duration: 0.2, midi: 68.2, confidence: 1),
            PitchFrame(time: 10.3, duration: 9.7, midi: nil, confidence: 0),
            PitchFrame(time: 20, duration: 1, midi: 84, confidence: 1)
        ]
        let window = ReviewWindow(duration: 30, start: 10)
        let phrase = ReviewPitchSection(frames: frames, window: window)
        try require(phrase.frameRange == 1..<4,
                    "Include a note crossing the left edge, but not one starting at the right edge")
        try require(phrase.hasPitch && phrase.lowerMIDI <= 66 && phrase.upperMIDI >= 69
                    && phrase.upperMIDI - phrase.lowerMIDI < 12,
                    "Nearby notes get a focused range, independent of distant notes")
        try require(phrase.labels.contains(67) && phrase.labels.contains(68),
                    "A focused phrase labels neighboring natural and accidental notes")
        try require(phrase.verticalFraction(for: 68.2) < phrase.verticalFraction(for: 66.8),
                    "Higher pitches appear above lower pitches")

        let silence = ReviewPitchSection(frames: frames,
                                         window: ReviewWindow(duration: 30, windowDuration: 2, start: 12))
        try require(!silence.hasPitch && silence.frameRange == 3..<4,
                    "An unvoiced section must not borrow pitches from neighboring sections")
        var fullWindow = window
        fullWindow.showFullTake()
        let full = ReviewPitchSection(frames: frames, window: fullWindow)
        for midi in [36.0, 84.0] {
            try require((0...1).contains(full.verticalFraction(for: midi)),
                        "Full-take view keeps extreme notes visible")
        }
        let empty = ReviewPitchSection(frames: [], window: ReviewWindow(duration: 0))
        try require(!empty.hasPitch && empty.verticalFraction(for: 60).isFinite,
                    "Empty analysis must have usable, finite drawing coordinates")
    }

    private static func recordingPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Sep 20, 2026 at 6.30.54 PM.caf")
        try writeFixture(to: url)
        let original = try Data(contentsOf: url)
        let store = RecordingStore(directory: directory)
        let takes = try store.recordings()
        try require(takes.count == 1 && abs(takes[0].duration - 3) < 0.001, "Legacy CAF discovered with audio duration")
        let analysis = try store.analysis(for: takes[0])
        try require(abs((analysis.frame(at: 0.3)?.midi ?? 0) - 48) < 0.08, "Legacy C3 segment")
        try require(analysis.frame(at: 1.2)?.midi == nil, "Legacy silence preserved")
        try require(abs((analysis.frame(at: 2.3)?.midi ?? 0) - 76) < 0.08, "Legacy E5 segment")
        try store.rename(takes[0], to: "  Warmup  ")
        let reopenedStore = RecordingStore(directory: directory)
        let renamed = try reopenedStore.recordings()[0]
        let reopened = try reopenedStore.analysis(for: renamed)
        try require(renamed.title == "Warmup" && reopened.title == "Warmup", "Rename survives cached analysis/relaunch")
        try require(abs((reopened.frame(at: 2.3)?.midi ?? 0) - 76) < 0.08, "Pitch survives reopen")
        let trace = url.deletingPathExtension().appendingPathExtension("pitch.json")
        try Data("corrupt".utf8).write(to: trace)
        let recovered = try reopenedStore.analysis(for: renamed)
        try require(recovered.title == "Warmup" && abs((recovered.frame(at: 0.3)?.midi ?? 0) - 48) < 0.08, "Corrupt cache rebuilt, title preserved")
        try require(try Data(contentsOf: url) == original, "Analysis and rename must never rewrite legacy audio")
        try reopenedStore.delete(renamed)
        try require(!FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: trace.path), "Delete removes audio and trace")
        try require(try reopenedStore.recordings().isEmpty, "Deleted take must not return after reload")
    }

    static func writeFixture(to url: URL) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 3))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / rate
            let midi = time < 1 ? 48.0 : 76.0
            samples[index] = time >= 1 && time < 2 ? 0 : Float(0.3 * sin(2 * Double.pi * PitchNote.frequency(midi) * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
