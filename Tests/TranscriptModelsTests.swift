import Foundation
import LocalSpeech

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NSError(domain: "TranscriptModelsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct TranscriptModelsTests {
    static func main() throws {
        try windows()
        try wordsAndRepetition()
        try emptyAndInvalidAlignment()
        try withDirectory { try persistenceAndResume(in: $0) }
        try withDirectory { try legacyWordTimingMigration(in: $0) }
        try withDirectory { try interruptedWordTimingUpgrade(in: $0) }
        try withDirectory { try corruptWordCheckpoints(in: $0) }
        try withDirectory { try growingSource(in: $0) }
        try withDirectory { try staleCheckpoints(in: $0) }
        try withDirectory { try deletionAndPending(in: $0) }
        print("PASS: transcript windows, whole-word intervals, repetition, final tails, durable IDs/resume, legacy upgrades, corrupt checkpoints, growing/stale sources, deletion and pending enumeration")
    }

    private static func windows() throws {
        try require(TranscriptWindow.next(processedThrough: 0, availableDuration: 24.999, isFinal: false) == nil,
                    "Recording must wait for all five seconds of lookahead")
        let first = try window(0, 25, final: false)
        try require(first.inputStart == 0 && first.inputEnd == 25 && first.commitStart == 0 && first.commitEnd == 20,
                    "First core clips only the unavailable leading context")
        let second = try window(20, 45, final: false)
        try require(second.inputStart == 15 && second.inputEnd == 45 && second.commitEnd == 40,
                    "Interior input includes both contextual margins")
        let tail = try window(40, 43.25, final: true)
        try require(tail.inputStart == 35 && tail.inputEnd == 43.25 && tail.commitEnd == 43.25,
                    "Final short tail is committed without waiting for lookahead")
        try require(TranscriptWindow.next(processedThrough: 43.25, availableDuration: 43.25, isFinal: true) == nil,
                    "Finished cursor must not schedule duplicate work")
        try require(TranscriptWindow.next(processedThrough: 0, availableDuration: 0, isFinal: true) == nil,
                    "Zero-length takes do not ask the engine for an empty window")
        for invalid in [-1.0, Double.nan, Double.infinity] {
            try require(TranscriptWindow.next(processedThrough: invalid, availableDuration: 45, isFinal: true) == nil,
                        "Invalid cursors cannot schedule inference")
            try require(TranscriptWindow.next(processedThrough: 0, availableDuration: invalid, isFinal: true) == nil,
                        "Invalid durations cannot schedule inference")
        }
        var cursor = 0.0
        var ends: [Double] = []
        while let next = TranscriptWindow.next(processedThrough: cursor, availableDuration: 102.5, isFinal: true) {
            try require(next.commitStart == cursor && next.inputEnd - next.inputStart <= 30,
                        "Windows are contiguous and the engine never receives more than 30 seconds")
            ends.append(next.commitEnd)
            cursor = next.commitEnd
        }
        try require(ends == [20, 40, 60, 80, 100, 102.5], "Final scheduling follows deterministic 20-second cores")
    }

    private static func wordsAndRepetition() throws {
        let store = TranscriptStore()
        var transcript = TakeTranscript(audioURL: URL(fileURLWithPath: "/missing/words.caf"), duration: 40, isFinal: true)
        transcript = store.merging([
            phrase([word(0, 0.4, " \nHello,"), word(1, 1.5, " hello!"), word(17.8, 20.8, " cross"), word(19.6, 20.2, " la"), word(19.9, 20.1, " exact")])
        ], window: try window(0, 40, final: true), into: transcript)
        try require(transcript.phrases.map(\.text) == ["Hello, hello! cross la"],
                    "Repeated lyrics at different times survive; midpoint exactly at the boundary belongs to the next core")
        try require(transcript.phrases[0].start == 0 && transcript.phrases[0].end == 20.8,
                    "Phrase times come from selected words, not the model's uncommitted full phrase")
        let firstID = transcript.phrases[0].id
        let firstWords = transcript.words
        try require(firstWords.map(\.text) == ["Hello,", "hello!", "cross", "la"],
                    "Every accepted word is retained with surrounding whitespace removed")
        try require(firstWords[2].start == 17.8 && firstWords[2].end == 20.8,
                    "A held three-second word keeps its full duration across the 20-second core boundary")
        transcript = store.merging([
            phrase([word(19.8, 20.4, " LA,"), word(19.9, 20.1, " exact"), word(21, 21.3, " la"), word(21.3, 21.6, " la"), word(23, 24, " \n"), word(40, 40, " end. \n"), word(40, 40, " END!")])
        ], window: try window(20, 40, final: true), into: transcript)
        try require(transcript.phrases.map(\.text) == ["Hello, hello! cross la", "exact la la end."],
                    "Only overlapping matching boundary tokens are removed; touching repeated words and the final endpoint survive")
        try require(transcript.phrases[0].id == firstID && transcript.phrases[1].end == 40,
                    "Committed phrase identity survives later windows and final seek times stay in the original clip")
        try require(transcript.words.map(\.text) == ["Hello,", "hello!", "cross", "la", "exact", "la", "la", "end."],
                    "Word persistence uses the same boundary deduplication, repeat, whitespace, and final endpoint rules as phrases")
        try require(Array(transcript.words.prefix(firstWords.count)) == firstWords,
                    "Appending a core cannot replace prior word IDs, labels, or full intervals")
        try require(transcript.words[4].start == 19.9 && transcript.words[4].end == 20.1,
                    "A word owned by the second core keeps its original start before that core")
        try require(transcript.words.last?.start == 40 && transcript.words.last?.end == 40,
                    "A zero-duration EOF word stays an event, without an invented held interval")
        try require(transcript.processedThrough == 40 && transcript.status == .complete,
                    "The exact 20-second final core completes without a phantom tail")
    }

    private static func emptyAndInvalidAlignment() throws {
        let store = TranscriptStore()
        let initial = TakeTranscript(audioURL: URL(fileURLWithPath: "/missing/empty.caf"), duration: 3, isFinal: true)
        let final = try window(0, 3, final: true)
        let empty = store.merging([], window: final, into: initial)
        try require(empty.status == .complete && empty.processedThrough == 3 && empty.phrases.isEmpty && empty.words.isEmpty && empty.message == nil,
                    "Empty recognition completes honestly without inventing words or claiming silence")
        let unaligned = store.merging([RecognizedPhrase(start: 0, end: 3, text: "Words without alignment", words: [])],
                                      window: final, into: initial)
        try require(unaligned.status == .failed && unaligned.processedThrough == 0 && unaligned.phrases.isEmpty && unaligned.words.isEmpty,
                    "Nonempty unaligned recognition must not be committed as an empty success")
        for invalidWord in [word(.nan, 1, " bad"), word(0, .infinity, " bad"), word(-1, 1, " bad"), word(2, 1, " bad")] {
            let invalid = store.merging([phrase([word(0, 0.5, " first")]), phrase([invalidWord])], window: final, into: initial)
            try require(invalid.status == .failed && invalid.processedThrough == 0 && invalid.words.isEmpty && invalid.phrases.isEmpty,
                        "An invalid later phrase rejects the whole window without committing earlier word progress")
        }
        let clipped = store.merging([phrase([word(2.5, 3.1, " tail")])], window: final, into: initial)
        try require(clipped.phrases.first?.start == 2.5 && clipped.phrases.first?.end == 3,
                    "A final word straddling EOF cannot seek outside the original audio")
        try require(clipped.words.first?.start == 2.5 && clipped.words.first?.end == 3,
                    "Persisted word intervals clip only the portion beyond EOF")
        let events = store.merging([phrase([word(0, 0, " start"), word(1, 1, " event"), word(3, 3, " end")])],
                                   window: final, into: initial)
        try require(events.words.map(\.start) == [0, 1, 3] && events.words.allSatisfy { $0.start == $0.end },
                    "Zero-duration SDK alignment is retained at the beginning, interior, and final endpoint")
    }

    private static func persistenceAndResume(in directory: URL) throws {
        let audioURL = directory.appendingPathComponent("resume.caf")
        try makeAudio(at: audioURL, seconds: 43)
        let original = try Data(contentsOf: audioURL)
        let store = TranscriptStore()
        var transcript = TakeTranscript(audioURL: audioURL, duration: 43, isFinal: true)
        transcript = store.merging([phrase([word(18, 21, " again")])],
                                   window: try window(0, 43, final: true), into: transcript)
        transcript.status = .paused
        transcript.message = "Paused while Practice is closed."
        try store.save(transcript, for: audioURL)
        guard var resumed = try TranscriptStore().load(for: audioURL) else { throw failure("Checkpoint must survive reopening") }
        try require(resumed.processedThrough == 20 && resumed.phrases == transcript.phrases
                    && resumed.words == transcript.words && resumed.status == .paused,
                    "Resume preserves cursor, phrase and word IDs/text/full intervals, and pending status")
        let next = try window(resumed.processedThrough, resumed.duration, final: resumed.isFinal)
        try require(next.inputStart == 15 && next.commitStart == 20 && next.commitEnd == 40,
                    "Resume uses saved original-file cursor, not phrase end or wall-clock time")
        resumed = store.merging([phrase([word(19.8, 20.4, " again"), word(22, 22.5, " again")])], window: next, into: resumed)
        try require(resumed.phrases.map(\.text) == ["again", "again"],
                    "Persisted boundary alignment removes duplicate recognition but retains the later repeated lyric")
        try require(resumed.words.map(\.text) == ["again", "again"] && resumed.words[0] == transcript.words[0]
                    && resumed.words[1].start == 22,
                    "Persisted boundary alignment deduplicates the overlapping word without losing the later repeat or earlier ID")
        try store.save(resumed, for: audioURL)
        guard let secondResume = try TranscriptStore().load(for: audioURL) else { throw failure("Replacement checkpoint must reopen") }
        try require(secondResume.words == resumed.words, "Every committed word survives successive atomic checkpoints")
        resumed = store.merging([], window: try window(secondResume.processedThrough, 43, final: true), into: secondResume)
        try store.save(resumed, for: audioURL)
        try require(try store.load(for: audioURL)?.status == .complete, "Final empty tail advances and persists completion")
        try require(try store.load(for: audioURL)?.words == transcript.words + [secondResume.words[1]],
                    "An empty final tail preserves all previously committed word identities")
        try require(try Data(contentsOf: audioURL) == original, "Checkpointing cannot modify any original audio bytes")
    }

    private static func legacyWordTimingMigration(in directory: URL) throws {
        let audioURL = directory.appendingPathComponent("v1.caf")
        try makeAudio(at: audioURL, seconds: 43)
        let original = try Data(contentsOf: audioURL)
        let store = TranscriptStore()
        let prior = [
            TranscriptPhrase(id: UUID(), start: 1, end: 4, text: "Saved words"),
            TranscriptPhrase(id: UUID(), start: 30, end: 33, text: "Still readable")
        ]
        let statuses: [TranscriptStatus] = [.recording, .queued, .transcribing, .paused, .complete, .failed]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for isFinal in [false, true] {
            for status in statuses where isFinal || status != .complete {
                var old = TakeTranscript(audioURL: audioURL, duration: 43, isFinal: isFinal)
                old.phrases = prior
                old.boundaryWords = [word(19.6, 20.2, " boundary")]
                old.processedThrough = status == .complete ? 43 : 20
                old.status = status
                old.message = "Saved status message"
                try saveLegacy(old, for: audioURL)
                guard let legacy = try store.load(for: audioURL) else { throw failure("Supported v1 checkpoint must load") }
                try require(legacy.version == 1 && legacy.requiresWordTimings && legacy.status == status
                            && legacy.words.isEmpty && legacy.previousPhrases == nil && legacy.displayPhrases == prior,
                            "Every supported legacy status stays readable without inventing word intervals or automatically migrating")
                try store.save(legacy, for: audioURL)
                try require(try store.load(for: audioURL)?.version == 1,
                            "A readable v1 checkpoint can still be saved without silently opting into reanalysis")
                let pending = try store.pending(in: directory)
                try require(pending.count == (status == .complete ? 0 : 1)
                            && pending.allSatisfy { $0.1.requiresWordTimings },
                            "Completed v1 takes stay out of automatic recovery; unfinished v1 work remains discoverable")

                let upgraded = legacy.preparingWordTimings()
                try require(upgraded.version == 2 && !upgraded.requiresWordTimings
                            && upgraded.processedThrough == 0 && upgraded.words.isEmpty
                            && upgraded.phrases.isEmpty && upgraded.boundaryWords.isEmpty,
                            "Explicit word timing upgrades restart alignment from zero with no guessed words")
                try require(upgraded.previousPhrases == prior && upgraded.displayPhrases == prior
                            && upgraded.status == (isFinal ? .queued : .recording) && upgraded.message == nil,
                            "The prior transcript stays visible while an upgrade receives a clean runnable status")
                try require(upgraded.modelID == legacy.modelID && upgraded.audioFilename == legacy.audioFilename
                            && upgraded.duration == legacy.duration && upgraded.isFinal == legacy.isFinal,
                            "An upgrade preserves model, original-file timebase, duration, and audio identity")
                try require(try encoder.encode(upgraded.preparingWordTimings()) == encoder.encode(upgraded),
                            "Preparing an existing v2 checkpoint is a complete no-op")
                try store.save(upgraded, for: audioURL)
                guard let reopened = try store.load(for: audioURL) else { throw failure("Prepared upgrade must retain valid source protection") }
                try require(reopened.previousPhrases == prior && reopened.words.isEmpty && reopened.processedThrough == 0,
                            "The prior phrase transcript is durably retained before any replacement inference succeeds")
            }
        }
        try require(try Data(contentsOf: audioURL) == original, "Migrating sidecars never rewrites the original CAF")
    }

    private static func interruptedWordTimingUpgrade(in directory: URL) throws {
        let audioURL = directory.appendingPathComponent("upgrade.caf")
        try makeAudio(at: audioURL, seconds: 43)
        let store = TranscriptStore()
        let prior = [TranscriptPhrase(id: UUID(), start: 1, end: 42, text: "The complete saved transcript")]
        var old = TakeTranscript(audioURL: audioURL, duration: 43, isFinal: true)
        old.phrases = prior
        old.processedThrough = 43
        old.status = .complete
        try saveLegacy(old, for: audioURL)
        guard let legacy = try store.load(for: audioURL) else { throw failure("Legacy transcript must reopen before upgrade") }
        var upgraded = legacy.preparingWordTimings()
        upgraded = store.merging([phrase([word(18, 21, " cross")])],
                                 window: try window(0, 43, final: true), into: upgraded)
        try require(upgraded.previousPhrases == prior && upgraded.displayPhrases == prior
                    && upgraded.phrases.map(\.text) == ["cross"] && upgraded.words.map(\.text) == ["cross"],
                    "Partial word analysis accumulates replacements without replacing the saved phrase transcript")
        upgraded.status = .paused
        upgraded.message = "Interrupted upgrade"
        try store.save(upgraded, for: audioURL)
        guard let paused = try store.load(for: audioURL) else { throw failure("Interrupted word upgrade must reopen") }
        try require(paused.previousPhrases == prior && paused.displayPhrases == prior
                    && paused.words == upgraded.words && paused.processedThrough == 20 && paused.status == .paused,
                    "Interruption preserves both the entire prior transcript and new committed word progress")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try require(try encoder.encode(paused.preparingWordTimings()) == encoder.encode(paused),
                    "Resuming a paused v2 upgrade cannot reset its cursor, stable IDs, fallback transcript, or status")
        let next = try window(20, 43, final: true)
        let failed = store.merging([
            phrase([word(22, 23, " uncommitted")]),
            RecognizedPhrase(start: 24, end: 25, text: "No alignment", words: [])
        ], window: next, into: paused)
        try require(failed.status == .failed && failed.previousPhrases == prior && failed.displayPhrases == prior
                    && failed.words == paused.words && failed.phrases == paused.phrases && failed.processedThrough == 20,
                    "A failed later phrase retains the old transcript and prior word progress without a partial window commit")
        try store.save(failed, for: audioURL)
        guard let retried = try store.load(for: audioURL) else { throw failure("Failed upgrade must remain durable") }
        try require(retried.previousPhrases == prior && retried.words == paused.words && retried.status == .failed,
                    "Failure must not discard either durable transcript generation")
        let mismatch = store.merging([], window: try window(0, 43, final: true), into: retried)
        try require(mismatch.status == .failed && mismatch.words == paused.words
                    && mismatch.previousPhrases == prior && mismatch.processedThrough == 20,
                    "Rejected stale windows cannot destroy upgrade progress or the saved transcript")
        var resumed = store.merging([phrase([word(19.8, 20.4, " CROSS,"), word(22, 23, " cross")])],
                                    window: next, into: retried.preparingWordTimings())
        try require(resumed.previousPhrases == prior && resumed.words.count == 2 && resumed.words[0] == paused.words[0]
                    && resumed.words[1].start == 22 && resumed.status == .queued,
                    "Retry resumes the saved cursor and dedup context while preserving distinct repeated lyrics")
        resumed = store.merging([], window: try window(40, 43, final: true), into: resumed)
        try require(resumed.status == .complete && resumed.previousPhrases == nil
                    && resumed.displayPhrases == resumed.phrases && resumed.words.count == 2,
                    "Only successful final completion releases the saved transcript in favor of the new word-backed phrases")
        try store.save(resumed, for: audioURL)
        guard let completed = try store.load(for: audioURL) else { throw failure("Completed upgrade must reopen") }
        try require(completed.previousPhrases == nil && completed.words == resumed.words
                    && completed.displayPhrases == resumed.phrases,
                    "Completed upgrade durably stores all replacement words and releases prior phrases")

        var empty = legacy.preparingWordTimings()
        while let next = TranscriptWindow.next(processedThrough: empty.processedThrough,
                                               availableDuration: empty.duration, isFinal: empty.isFinal) {
            empty = store.merging([], window: next, into: empty)
            if empty.status != .complete {
                try require(empty.displayPhrases == prior, "An empty intermediate core must not discard the saved transcript")
            }
        }
        try require(empty.status == .complete && empty.words.isEmpty && empty.previousPhrases == nil && empty.displayPhrases.isEmpty,
                    "Successful empty reanalysis also releases the old transcript instead of presenting stale words as current")
    }

    private static func corruptWordCheckpoints(in directory: URL) throws {
        let audioURL = directory.appendingPathComponent("corrupt-words.caf")
        try makeAudio(at: audioURL, seconds: 3)
        let store = TranscriptStore()
        let validTranscript = store.merging([phrase([word(0.5, 2.5, " held")])],
                                            window: try window(0, 3, final: true),
                                            into: TakeTranscript(audioURL: audioURL, duration: 3, isFinal: true))
        try store.save(validTranscript, for: audioURL)
        let sidecar = sidecarURL(audioURL)
        let valid = try Data(contentsOf: sidecar)
        let invalidTimes: [(Double, Double)] = [(-1, 1), (2, 1), (1, 4), (.nan, 1), (0, .infinity)]
        for (start, end) in invalidTimes {
            var invalid = validTranscript
            invalid.words = [TranscriptWord(id: UUID(), start: start, end: end, text: "bad")]
            var rejected = false
            do { try store.save(invalid, for: audioURL) } catch { rejected = true }
            try require(try rejected && Data(contentsOf: sidecar) == valid,
                        "Invalid persisted word times must be rejected without replacing the last durable checkpoint")
        }
        for (start, end) in invalidTimes where start.isFinite && end.isFinite {
            var json = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            var words = json["words"] as! [[String: Any]]
            words[0]["start"] = start
            words[0]["end"] = end
            json["words"] = words
            try JSONSerialization.data(withJSONObject: json).write(to: sidecar, options: .atomic)
            try require(try store.load(for: audioURL) == nil, "Corrupt on-disk word intervals cannot enter the displayed timeline")
        }
        var missingWords = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        missingWords.removeValue(forKey: "words")
        try JSONSerialization.data(withJSONObject: missingWords).write(to: sidecar, options: .atomic)
        try require(try store.load(for: audioURL) == nil, "A v2 checkpoint missing its durable words is not a valid v1 migration")
        try valid.write(to: sidecar, options: .atomic)
        var duplicate = validTranscript
        duplicate.words.append(duplicate.words[0])
        var blank = validTranscript
        blank.words = [TranscriptWord(id: UUID(), start: 0, end: 1, text: " \n")]
        var invalidPrior = validTranscript
        invalidPrior.previousPhrases = [TranscriptPhrase(id: UUID(), start: 0, end: 4, text: "out of bounds")]
        for invalid in [duplicate, blank, invalidPrior] {
            var rejected = false
            do { try store.save(invalid, for: audioURL) } catch { rejected = true }
            try require(try rejected && Data(contentsOf: sidecar) == valid,
                        "Duplicate word IDs, blank labels, and invalid retained phrase times cannot corrupt a durable checkpoint")
        }
    }

    private static func growingSource(in directory: URL) throws {
        let audioURL = directory.appendingPathComponent("growing.caf")
        try makeAudio(at: audioURL, seconds: 25, growing: true)
        let store = TranscriptStore()
        var transcript = TakeTranscript(audioURL: audioURL, duration: 25, isFinal: false)
        transcript = store.merging([phrase([word(1, 2, " retained")])],
                                   window: try window(0, 25, final: false), into: transcript)
        try store.save(transcript, for: audioURL)
        let file = try FileHandle(forWritingTo: audioURL)
        try file.seekToEnd()
        try file.write(contentsOf: Data(repeating: 0, count: 64_000 * 3))
        // Simulate the normal CAF data-length update when capture closes.
        try file.seek(toOffset: 56)
        try file.write(contentsOf: bigEndian(UInt64(64_000 * 28 + 4)))
        try file.close()
        guard var recovered = try store.load(for: audioURL) else { throw failure("Growing capture must remain resumable after its CAF header closes") }
        try require(!recovered.isFinal && recovered.processedThrough == 20 && recovered.duration == 25,
                    "Store preserves the committed watermark; coordinator owns actual-duration finalization")
        recovered.duration = 28
        recovered.isFinal = true
        recovered = store.merging([], window: try window(20, 28, final: true), into: recovered)
        try store.save(recovered, for: audioURL)
        try require(try store.load(for: audioURL)?.processedThrough == 28,
                    "Recovered recording can flush its final tail and seal the source")
    }

    private static func staleCheckpoints(in directory: URL) throws {
        let audioURL = directory.appendingPathComponent("stale.caf")
        try makeAudio(at: audioURL, seconds: 30)
        let store = TranscriptStore()
        let initial = TakeTranscript(audioURL: audioURL, duration: 30, isFinal: true)
        try require(try store.load(for: audioURL) == nil, "Missing sidecars do not manufacture a transcript")
        try store.save(initial, for: audioURL)
        let sidecar = sidecarURL(audioURL)
        let valid = try Data(contentsOf: sidecar)
        var invalid = initial
        invalid.processedThrough = 31
        var rejected = false
        do { try store.save(invalid, for: audioURL) } catch { rejected = true }
        let retained = try Data(contentsOf: sidecar)
        try require(rejected && retained == valid,
                    "Rejected checkpoints must leave the last durable resume point intact")
        for (key, value) in [("modelID", "different-model" as Any), ("version", 999 as Any), ("audioFilename", "another.caf" as Any), ("processedThrough", 31 as Any)] {
            var json = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            json[key] = value
            try JSONSerialization.data(withJSONObject: json).write(to: sidecar, options: .atomic)
            try require(try store.load(for: audioURL) == nil, "Incompatible \(key) must never display stale words")
        }
        try Data("{interrupted".utf8).write(to: sidecar, options: .atomic)
        try require(try store.load(for: audioURL) == nil, "Corrupt checkpoint is ignored without touching audio")
        try valid.write(to: sidecar, options: .atomic)
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let modified = attributes[.modificationDate] as! Date
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(1)], ofItemAtPath: audioURL.path)
        try require(try store.load(for: audioURL) == nil, "Finalized source modification invalidates its checkpoint")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: audioURL.path)
        // Replace the same filename and content with a different file identity.
        try Data(contentsOf: audioURL).write(to: audioURL, options: .atomic)
        try require(try store.load(for: audioURL) == nil, "Replacing audio cannot borrow the previous take's words")
        var replacement = TakeTranscript(audioURL: audioURL, duration: 30, isFinal: false)
        replacement = store.merging([phrase([word(1, 2, " original")])],
                                    window: try window(0, 30, final: false), into: replacement)
        try store.save(replacement, for: audioURL)
        let file = try FileHandle(forWritingTo: audioURL)
        try file.seek(toOffset: 68)
        try file.write(contentsOf: Data([1, 2, 3, 4]))
        try file.close()
        try require(try store.load(for: audioURL) == nil,
                    "Unfinished source accepts append, not overwritten committed payload")
        try FileManager.default.removeItem(at: audioURL)
        try require(try store.load(for: audioURL) == nil, "Orphan sidecars cannot resurrect deleted audio")
    }

    private static func deletionAndPending(in directory: URL) throws {
        let store = TranscriptStore()
        let names = ["z.caf", "a.caf", "complete.caf", "unrequested.caf", "legacy-complete.caf", "legacy-pending.caf"]
        for name in names { try makeAudio(at: directory.appendingPathComponent(name), seconds: 2) }
        for name in names.prefix(2) {
            let url = directory.appendingPathComponent(name)
            try store.save(TakeTranscript(audioURL: url, duration: 2, isFinal: true), for: url)
        }
        let completeURL = directory.appendingPathComponent("complete.caf")
        let complete = store.merging([], window: try window(0, 2, final: true),
                                     into: TakeTranscript(audioURL: completeURL, duration: 2, isFinal: true))
        try store.save(complete, for: completeURL)
        let legacyCompleteURL = directory.appendingPathComponent("legacy-complete.caf")
        var legacyComplete = TakeTranscript(audioURL: legacyCompleteURL, duration: 2, isFinal: true)
        legacyComplete.processedThrough = 2
        legacyComplete.status = .complete
        try saveLegacy(legacyComplete, for: legacyCompleteURL)
        let legacyPendingURL = directory.appendingPathComponent("legacy-pending.caf")
        try saveLegacy(TakeTranscript(audioURL: legacyPendingURL, duration: 2, isFinal: true), for: legacyPendingURL)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("broken.transcript.json"))
        try require(try store.pending(in: directory).map { $0.0.lastPathComponent } == ["a.caf", "legacy-pending.caf", "z.caf"],
                    "Pending enumeration skips completed v1/v2, corrupt, and unrequested takes but includes unfinished legacy work")
        let audioURL = directory.appendingPathComponent("a.caf")
        let audio = try Data(contentsOf: audioURL)
        let metadataURL = audioURL.deletingPathExtension().appendingPathExtension("metadata.json")
        let metadata = Data("{\"title\":\"Renamed\"}".utf8)
        try metadata.write(to: metadataURL)
        try require(try store.load(for: audioURL) != nil, "Title-only metadata rename must not invalidate a transcript")
        try store.delete(for: audioURL)
        try store.delete(for: audioURL)
        try require(try store.load(for: audioURL) == nil && store.pending(in: directory).map { $0.0.lastPathComponent } == ["legacy-pending.caf", "z.caf"],
                    "Deletion removes only its checkpoint and is safe to repeat")
        try require(try Data(contentsOf: audioURL) == audio && Data(contentsOf: metadataURL) == metadata,
                    "Transcript deletion leaves original audio and title/pitch sidecars untouched")
    }

    private static func word(_ start: Double, _ end: Double, _ text: String) -> RecognizedWord {
        RecognizedWord(start: start, end: end, text: text)
    }

    private static func phrase(_ words: [RecognizedWord]) -> RecognizedPhrase {
        RecognizedPhrase(start: words.first?.start ?? 0, end: words.last?.end ?? 0,
                         text: words.map(\.text).joined(), words: words)
    }

    private static func window(_ cursor: Double, _ duration: Double, final: Bool) throws -> TranscriptWindow {
        guard let window = TranscriptWindow.next(processedThrough: cursor, availableDuration: duration, isFinal: final) else {
            throw failure("Expected a window at \(cursor) / \(duration)")
        }
        return window
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TranscriptModelsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func sidecarURL(_ audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    private static func saveLegacy(_ transcript: TakeTranscript, for audioURL: URL) throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript)) as! [String: Any]
        json["version"] = 1
        json.removeValue(forKey: "words")
        json.removeValue(forKey: "previousPhrases")
        try JSONSerialization.data(withJSONObject: json).write(to: sidecarURL(audioURL), options: .atomic)
    }

    // Valid mono Float32 PCM CAF, with an optional unknown data length while recording.
    // Keeping its payload offset explicit also allows deterministic append/header-close checks.
    private static func makeAudio(at url: URL, seconds: Int, growing: Bool = false) throws {
        var data = Data([0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0])
        data.append(Data("desc".utf8))
        data.append(bigEndian(UInt64(32)))
        data.append(bigEndian(Double(16_000).bitPattern))
        data.append(Data("lpcm".utf8))
        for value in [UInt32(9), 4, 1, 1, 32] { data.append(bigEndian(value)) }
        data.append(Data("data".utf8))
        data.append(bigEndian(growing ? UInt64.max : UInt64(seconds * 64_000 + 4)))
        data.append(bigEndian(UInt32(0)))
        data.append(Data(repeating: 0, count: seconds * 64_000))
        try data.write(to: url)
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
