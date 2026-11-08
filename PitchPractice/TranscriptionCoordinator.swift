import AVFoundation
import LocalSpeech
import Observation
import OSLog
import UIKit

/// One model and one inference operation across all takes. Audio capture never
/// waits for this owner: it publishes only the URL and committed sample duration.
@Observable
@MainActor
final class TranscriptionCoordinator {
    private(set) var modelStatus = "Preparing on-device words"
    private(set) var isPreparing = false
    private(set) var modelIsLoaded = false
    private(set) var isTranscribing = false
    private(set) var transcripts: [String: TakeTranscript] = [:]

    private enum PauseReason {
        case background, system, memory, thermal

        var message: String {
            switch self {
            case .background: "Background time ended. Analysis will resume when you return."
            case .system: "Analysis paused by iOS or cancelled. Tap Resume to continue."
            case .memory: "Paused to protect recording memory. Tap Resume to continue."
            case .thermal: "Analysis paused while your iPhone cools. Recording remains available."
            }
        }
    }

    @ObservationIgnored private let recognizer = WhisperTranscriber()
    @ObservationIgnored private let store = TranscriptStore()
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let modelDirectory: URL?
    @ObservationIgnored private let checkpointQueue = DispatchQueue(label: "pitch.transcript.checkpoints", qos: .utility)
    @ObservationIgnored private let logger = Logger(subsystem: "ai.dannyboy.pitchpractice", category: "Transcription")
    @ObservationIgnored private var urls: [String: URL] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private var activeRecording: String?
    @ObservationIgnored private var activeJob: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var releasing: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var appActive = false
    @ObservationIgnored private var warmRequested = false
    @ObservationIgnored private var resourcePause: PauseReason?
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var deleted = Set<String>()
    @ObservationIgnored private var hasRecovered = false
    @ObservationIgnored private var loadingRequests = Set<String>()
    @ObservationIgnored private var backgroundRequestPending = false
    @ObservationIgnored private var backgroundHadFailure = false
    @ObservationIgnored private var background: ContinuedTranscriptionTask { .shared }

    init(directory: URL = RecordingStore().directory,
         modelDirectory: URL? = Bundle.main.url(forResource: "SpeechModels", withExtension: nil)) {
        self.directory = directory
        self.modelDirectory = modelDirectory
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseForResources(.memory) }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalStateChanged() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        worker?.cancel()
        releasing?.cancel()
    }


    func setAppActive(_ active: Bool) {
        if active, !hasRecovered { recoverPending() }
        guard active != appActive else { return }
        appActive = active
        if active {
            if resourcePause == .background { resourcePause = nil }
            if resourcePause == nil { resumeRequested() }
            warmRequested = !modelIsLoaded && resourcePause == nil
            kick()
        } else if !background.isRunning {
            pauseForResources(.background)
        }
    }

    func transcript(for take: PracticeTake) -> TakeTranscript? { transcripts[take.id] }

    /// Loading a saved transcript never prepares the model or requests inference.
    func loadTranscript(for take: PracticeTake) {
        urls[take.id] = take.audioURL
        guard transcripts[take.id] == nil, !deleted.contains(take.id) else { return }
        let store = store
        checkpointQueue.async { [weak self] in
            let result = Result { try store.load(for: take.audioURL) }
            Task { @MainActor in
                guard let self, self.transcripts[take.id] == nil, !self.deleted.contains(take.id) else { return }
                switch result {
                case .success(let transcript):
                    if var transcript {
                        if transcript.status != .complete && transcript.status != .failed {
                            transcript.status = .paused
                            transcript.message = "Saved analysis is unfinished. Tap Resume to continue on this iPhone."
                        }
                        self.transcripts[take.id] = transcript
                    }
                case .failure(let error):
                    var transcript = TakeTranscript(audioURL: take.audioURL, duration: take.duration, isFinal: true)
                    transcript.status = .failed
                    transcript.message = "Could not read saved words: \(error.localizedDescription)"
                    self.transcripts[take.id] = transcript
                }
            }
        }
    }

    func requestTranscript(for take: PracticeTake) {
        guard !deleted.contains(take.id), !loadingRequests.contains(take.id) else { return }
        if let transcript = transcripts[take.id] {
            queueTranscript(transcript, for: take)
            return
        }
        // A tap can beat the asynchronous review load. Read the durable cursor
        // before creating a new job so that saved work is never overwritten.
        loadingRequests.insert(take.id)
        let store = store
        checkpointQueue.async { [weak self] in
            let result = Result { try store.load(for: take.audioURL) }
            Task { @MainActor in
                guard let self else { return }
                self.loadingRequests.remove(take.id)
                guard !self.deleted.contains(take.id) else { return }
                switch result {
                case .success(let saved):
                    self.queueTranscript(self.transcripts[take.id] ?? saved ??
                        TakeTranscript(audioURL: take.audioURL, duration: take.duration, isFinal: true), for: take)
                case .failure(let error):
                    var failed = TakeTranscript(audioURL: take.audioURL, duration: take.duration, isFinal: true)
                    failed.status = .failed
                    failed.message = "Could not read saved words: \(error.localizedDescription)"
                    self.transcripts[take.id] = failed
                    self.backgroundHadFailure = true
                    self.settle()
                }
            }
        }
    }

    private func queueTranscript(_ saved: TakeTranscript, for take: PracticeTake) {
        guard saved.status != .complete || saved.requiresWordTimings else { settle(); return }
        resourcePause = nil
        urls[take.id] = take.audioURL
        var transcript = saved.preparingWordTimings()
        transcript.isFinal = true
        transcript.duration = take.duration
        transcript.status = transcript.processedThrough >= transcript.duration ? .complete : .queued
        if transcript.status == .complete { transcript.previousPhrases = nil }
        transcript.message = nil
        transcripts[take.id] = transcript
        checkpoint(transcript, url: take.audioURL)
        guard transcript.status != .complete else { settle(); return }
        enqueue(take.id)
        requestBackgroundTime()
        kick()
    }

    func beginRecording(at url: URL) {
        let key = url.lastPathComponent
        resourcePause = nil
        deleted.remove(key)
        urls[key] = url
        activeRecording = key
        let transcript = TakeTranscript(audioURL: url, duration: 0, isFinal: false)
        transcripts[key] = transcript
        enqueue(key)
        checkpoint(transcript, url: url)
        warmRequested = true
        requestBackgroundTime()
        kick()
    }

    func updateRecording(duration: Double) {
        guard let key = activeRecording, var transcript = transcripts[key] else { return }
        transcript.duration = max(transcript.duration, duration)
        transcripts[key] = transcript
        background.update(processed: transcript.processedThrough, duration: duration, recording: true)
        kick()
    }

    func finishRecording(at url: URL, duration: Double) {
        let key = url.lastPathComponent
        if activeRecording == key { activeRecording = nil }
        guard var transcript = transcripts[key] else { return }
        transcript.duration = max(0, duration)
        transcript.isFinal = true
        if transcript.status != .failed {
            transcript.status = resourcePause == nil ? .queued : .paused
            transcript.message = resourcePause?.message
            if duration <= transcript.processedThrough {
                transcript.status = .complete
                transcript.previousPhrases = nil
            }
        }
        transcripts[key] = transcript
        // The take just opened for review must not wait behind an older backlog.
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        checkpoint(transcript, url: url)
        kick()
        settle()
    }

    func deleteTranscript(for take: PracticeTake) {
        deleted.insert(take.id)
        requested.remove(take.id)
        order.removeAll { $0 == take.id }
        urls.removeValue(forKey: take.id)
        transcripts.removeValue(forKey: take.id)
        if activeJob == take.id { worker?.cancel() }
        let store = store
        checkpointQueue.async { [weak self] in
            do { try store.delete(for: take.audioURL) }
            catch { self?.logger.error("Could not remove transcript: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func enqueue(_ key: String) {
        requested.insert(key)
        if !order.contains(key) { order.append(key) }
    }

    private func requestBackgroundTime() {
        guard !background.hasRequest else { return }
        backgroundRequestPending = true
        backgroundHadFailure = false
    }

    private func beginBackgroundTime() {
        guard backgroundRequestPending, appActive, modelIsLoaded else { return }
        // Consume the user's request once, only with a ready model and audio window.
        // Cold preparation and waiting for live audio must not leave an iOS task stalled.
        backgroundRequestPending = false
        background.begin(onStart: { [weak self] in
            guard let self else { return }
            if let key = self.activeJob, let transcript = self.transcripts[key] {
                self.background.update(processed: transcript.processedThrough,
                                       duration: transcript.duration, recording: !transcript.isFinal)
            }
            self.kick()
        }, onExpiration: { [weak self] in
            self?.pauseForResources(.system)
        })
    }

    private func recoverPending() {
        hasRecovered = true
        let token = UUID()
        recoveryID = token
        let store = store
        let directory = directory
        checkpointQueue.async { [weak self] in
            let result = Result { try store.pending(in: directory) }
            Task { @MainActor in
                guard let self, self.recoveryID == token else { return }
                switch result {
                case .success(let pending):
                    for (url, saved) in pending {
                        let key = url.lastPathComponent
                        guard !self.deleted.contains(key), self.activeRecording != key,
                              !self.requested.contains(key), saved.status != .failed,
                              self.transcripts[key]?.status != .complete else { continue }
                        do {
                            let audio = try AVAudioFile(forReading: url)
                            var transcript = saved.preparingWordTimings()
                            transcript.duration = Double(audio.length) / audio.processingFormat.sampleRate
                            transcript.isFinal = true
                            transcript.status = transcript.processedThrough >= transcript.duration ? .complete : .queued
                            if transcript.status == .complete { transcript.previousPhrases = nil }
                            transcript.message = nil
                            self.urls[key] = url
                            self.transcripts[key] = transcript
                            self.checkpoint(transcript, url: url)
                            if transcript.status != .complete { self.enqueue(key) }
                        } catch {
                            self.logger.error("Could not resume original audio: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    self.kick()
                case .failure(let error):
                    self.modelStatus = "Could not resume saved analysis: \(error.localizedDescription)"
                }
            }
        }
    }

    private func nextWork() -> (String, URL, TranscriptWindow)? {
        // The active take has first priority, then older requested takes.
        let keys = activeRecording.map { current in [current] + order.filter { $0 != current } } ?? order
        for key in keys where requested.contains(key) && !deleted.contains(key) {
            guard let url = urls[key], let transcript = transcripts[key],
                  transcript.status != .failed, transcript.status != .complete,
                  let window = TranscriptWindow.next(processedThrough: transcript.processedThrough,
                                                     availableDuration: transcript.duration, isFinal: transcript.isFinal) else { continue }
            return (key, url, window)
        }
        return nil
    }

    private var canRun: Bool {
        resourcePause == nil && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue &&
            (appActive || background.isRunning)
    }

    private func kick() {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            if resourcePause != .thermal { pauseForResources(.thermal) }
            return
        }
        guard worker == nil, releasing == nil, canRun,
              warmRequested || nextWork() != nil else { return }
        let token = UUID()
        workerID = token
        worker = Task(priority: .utility) { [weak self] in
            await self?.runWorker(token: token)
        }
    }

    private func runWorker(token: UUID) async {
        defer {
            if workerID == token {
                worker = nil
                workerID = nil
                activeJob = nil
                isPreparing = false
                isTranscribing = false
                settle()
            }
        }
        do {
            warmRequested = false
            if !modelIsLoaded {
                guard let modelDirectory else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The bundled speech model is missing. Reinstall this app; your audio remains saved."])
                }
                isPreparing = true
                modelStatus = "Preparing words — keep the app open for setup; recording is ready"
                let started = ProcessInfo.processInfo.systemUptime
                logger.notice("Speech prepare begin")
                _ = try await recognizer.prepare(modelsDirectory: modelDirectory)
                try Task.checkCancellation()
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                modelIsLoaded = true
                isPreparing = false
                modelStatus = "On-device words ready"
                logger.notice("Speech prepare end; seconds=\(elapsed)")
            }
            while canRun, let (key, url, window) = nextWork() {
                try Task.checkCancellation()
                activeJob = key
                isTranscribing = true
                modelStatus = activeRecording == nil ? "Finishing words on this iPhone" : "Recognizing words while you sing"
                beginBackgroundTime()
                if var transcript = transcripts[key] {
                    transcript.status = .transcribing
                    transcript.message = nil
                    transcripts[key] = transcript
                    try await saveCheckpoint(transcript, url: url)
                }
                let recognized = try await recognizer.transcribe(file: url, from: window.inputStart, to: window.inputEnd)
                try Task.checkCancellation()
                guard !deleted.contains(key), requested.contains(key), let current = transcripts[key] else { continue }
                var merged = store.merging(recognized, window: window, into: current)
                if merged.status != .failed {
                    if merged.isFinal && merged.processedThrough >= merged.duration {
                        merged.status = .complete
                        merged.previousPhrases = nil
                    } else {
                        merged.status = merged.isFinal ? .queued : .recording
                    }
                }
                transcripts[key] = merged
                try await saveCheckpoint(merged, url: url)
                background.update(processed: merged.processedThrough, duration: merged.duration, recording: !merged.isFinal)
                logger.notice("Speech chunk committed through=\(merged.processedThrough), duration=\(merged.duration)")
                if merged.status == .complete {
                    requested.remove(key)
                } else if merged.status == .failed {
                    requested.remove(key)
                    backgroundHadFailure = true
                }
                activeJob = nil
            }
            isTranscribing = false
            if modelIsLoaded { modelStatus = "On-device words ready" }
        } catch {
            if Task.isCancelled || error is CancellationError {
                if let key = activeJob, var transcript = transcripts[key], !deleted.contains(key) {
                    transcript.status = .paused
                    transcript.message = resourcePause?.message ?? "Analysis paused. Tap Resume to continue."
                    transcripts[key] = transcript
                    if let url = urls[key] { checkpoint(transcript, url: url) }
                }
            } else {
                backgroundHadFailure = true
                let failedKeys = activeJob.map { [$0] } ?? order.filter { requested.contains($0) }
                for key in failedKeys where !deleted.contains(key) {
                    guard var transcript = transcripts[key] else { continue }
                    transcript.status = .failed
                    transcript.message = "Words could not be analyzed: \(error.localizedDescription)"
                    transcripts[key] = transcript
                    requested.remove(key)
                    if let url = urls[key] { checkpoint(transcript, url: url) }
                }
                modelStatus = "Words unavailable: \(error.localizedDescription)"
                logger.error("Speech operation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func settle() {
        guard worker == nil, releasing == nil else { return }
        if canRun, nextWork() != nil { kick(); return }
        let finished = activeRecording == nil && nextWork() == nil && loadingRequests.isEmpty
        if finished { backgroundRequestPending = false }
        // Keep the continued-processing grant until Core ML has released its
        // resources; iOS may suspend us as soon as the task is marked complete.
        if !appActive, finished { releaseModel(); return }
        if finished { background.finish(success: !backgroundHadFailure) }
        if !appActive && !background.isRunning { releaseModel(); return }
    }

    private func pauseForResources(_ reason: PauseReason) {
        resourcePause = reason
        warmRequested = false
        if reason != .background { backgroundRequestPending = false }
        modelStatus = reason.message
        for key in order where requested.contains(key) {
            guard var transcript = transcripts[key], transcript.status != .complete, transcript.status != .failed else { continue }
            transcript.status = .paused
            transcript.message = reason.message
            transcripts[key] = transcript
            if let url = urls[key] { checkpoint(transcript, url: url) }
        }
        background.finish(success: false)
        releaseModel()
    }

    private func resumeRequested() {
        for key in order where requested.contains(key) {
            guard var transcript = transcripts[key], transcript.status == .paused else { continue }
            transcript.status = transcript.isFinal ? .queued : .recording
            transcript.message = nil
            transcripts[key] = transcript
        }
    }

    private func thermalStateChanged() {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            pauseForResources(.thermal)
        } else if resourcePause == .thermal {
            resourcePause = nil
            resumeRequested()
            warmRequested = appActive && !modelIsLoaded
            kick()
        }
    }

    private func releaseModel() {
        guard releasing == nil else { return }
        guard modelIsLoaded || worker != nil else {
            if activeRecording == nil, nextWork() == nil, loadingRequests.isEmpty {
                backgroundRequestPending = false
                background.finish(success: !backgroundHadFailure)
            }
            return
        }
        let pending = worker
        pending?.cancel()
        releasing = Task { [weak self] in
            guard let self else { return }
            await pending?.value
            await recognizer.unload()
            modelIsLoaded = false
            isPreparing = false
            isTranscribing = false
            logger.notice("Speech unloaded")
            modelStatus = resourcePause?.message ?? "Speech model released — saved words remain available"
            if activeRecording == nil, nextWork() == nil, loadingRequests.isEmpty {
                backgroundRequestPending = false
                background.finish(success: !backgroundHadFailure)
            }
            releasing = nil
            kick()
        }
    }

    private func checkpoint(_ transcript: TakeTranscript, url: URL) {
        let store = store
        checkpointQueue.async { [weak self] in
            do { try store.save(transcript, for: url) }
            catch {
                Task { @MainActor in
                    guard let self, !self.deleted.contains(url.lastPathComponent), var current = self.transcripts[url.lastPathComponent] else { return }
                    current.status = .failed
                    current.message = "Could not save words: \(error.localizedDescription)"
                    self.transcripts[url.lastPathComponent] = current
                    self.requested.remove(url.lastPathComponent)
                }
            }
        }
    }

    private func saveCheckpoint(_ transcript: TakeTranscript, url: URL) async throws {
        let store = store
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            checkpointQueue.async {
                do { try store.save(transcript, for: url); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

}
