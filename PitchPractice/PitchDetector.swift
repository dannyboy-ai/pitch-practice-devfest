import AVFoundation
import Observation

@Observable
@MainActor
final class PitchDetector: NSObject {
    private(set) var frequency: Double?
    private(set) var pitchMIDI: Double?
    private(set) var note = "—"
    private(set) var cents = 0.0
    private(set) var status = "Ready"
    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var isSaving = false
    private(set) var recordingDuration = 0.0
    private(set) var referenceMIDI = 60.0
    private(set) var recordings: [PracticeTake] = []
    var reviewTake: PracticeTake?
    private(set) var reviewAnalysis: TakeAnalysis?
    private(set) var isLoadingReview = false
    private(set) var reviewError: String?
    private(set) var isPlaying = false
    private(set) var playbackTime = 0.0
    private(set) var playbackDuration = 0.0
    private(set) var playbackBoost = false
    private(set) var playbackRate = PlaybackRate.normal
    private(set) var playbackRouteName = "Audio output"
    private(set) var canPlayReview = false
    var errorMessage: String?
    let transcription = TranscriptionCoordinator()

    private let engine = AVAudioEngine()
    private let store = RecordingStore()
    private let referencePlayer = PitchPlayer()
    @ObservationIgnored private var capture: PitchCapture?
    @ObservationIgnored private var captureID: UUID?
    @ObservationIgnored private var permissionID: UUID?
    @ObservationIgnored private var recordingPlayback: RecordingPlayback?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var reviewID: UUID?
    @ObservationIgnored private var resumeAfterScrubbing = false
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        reloadRecordings()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let began = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue
            if began {
                Task { @MainActor [weak self] in self?.handleBackground() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updatePlaybackRoute()
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                    self.handleBackground()
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.stop()
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        playbackTask?.cancel()
        reviewTask?.cancel()
    }

    func startListening() { requestStart(recording: false) }
    func startRecording() { requestStart(recording: true) }

    private func requestStart(recording: Bool) {
        guard !isStarting, !isSaving, !isRecording else { return }
        if isRunning {
            guard recording else { return }
            stop()
        }
        closeReview()
        referencePlayer.stop()
        let id = UUID()
        permissionID = id
        isStarting = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.permissionID == id else { return }
                self.permissionID = nil
                self.isStarting = false
                if granted { self.start(recording: recording) }
                else { self.errorMessage = "Allow microphone access in Settings to tune or practice." }
            }
        }
    }

    private func start(recording: Bool) {
        var newURL: URL?
        var tapInstalled = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
            }
            newURL = recording ? try store.newRecordingURL() : nil
            let capture = try PitchCapture(format: format, url: newURL)
            let id = UUID()
            self.capture = capture
            captureID = id
            recordingDuration = 0
            clearReadout()
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self, capture] buffer, _ in
                let update = capture.consume(buffer)
                Task { @MainActor [weak self] in
                    guard let self, self.captureID == id else { return }
                    if let failure = update.error {
                        self.errorMessage = "Recording stopped: \(failure)"
                        self.stop()
                        return
                    }
                    if self.isRecording {
                        self.recordingDuration = update.duration
                        self.transcription.updateRecording(duration: update.duration)
                    }
                    self.apply(update.estimate)
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRecording = recording
            isRunning = true
            status = recording ? "Recording · sing any note" : "Tuning · sing any note"
            if let newURL { transcription.beginRecording(at: newURL) }
        } catch {
            captureID = nil
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            capture = nil
            if let newURL { try? FileManager.default.removeItem(at: newURL) }
            try? AVAudioSession.sharedInstance().setActive(false)
            errorMessage = "Could not start microphone: \(error.localizedDescription)"
        }
    }

    func stop() {
        permissionID = nil
        isStarting = false
        guard isRunning else { return }
        captureID = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let completed = capture?.finish()
        capture = nil
        isRunning = false
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        status = "Ready"
        guard let completed, let url = completed.url else { return }
        transcription.finishRecording(at: url, duration: completed.analysis.duration)
        isSaving = true
        let store = store
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try store.saveAnalysis(completed.analysis, for: url)
                    return try store.recordings()
                }.value
                recordings = result
                isSaving = false
                if let take = result.first(where: { $0.id == url.lastPathComponent }) { openReview(take) }
            } catch {
                isSaving = false
                reloadRecordings()
                errorMessage = "Audio was saved, but its pitch data could not be saved: \(error.localizedDescription)"
                if let take = recordings.first(where: { $0.id == url.lastPathComponent }) { openReview(take) }
            }
        }
    }

    func selectPitch(_ midi: Double) {
        guard !isRunning, !isStarting, !isSaving else { return }
        referenceMIDI = min(PitchNote.supportedRange.upperBound, max(PitchNote.supportedRange.lowerBound, midi.rounded()))
        updateReadout(referenceMIDI)
        status = "Reference · \(PitchNote.name(Int(referenceMIDI)))"
    }

    func playReference() {
        guard !isRecording, !isStarting, !isSaving else { return }
        if isRunning { stop() }
        pausePlayback()
        resumeAfterScrubbing = false
        do {
            try referencePlayer.play(midi: referenceMIDI)
            updateReadout(referenceMIDI)
            status = "Reference · \(PitchNote.name(Int(referenceMIDI)))"
        }
        catch { errorMessage = "Could not play reference: \(error.localizedDescription)" }
    }

    private func apply(_ estimate: PitchEstimate) {
        guard let midi = estimate.midi else {
            clearReadout()
            status = "No clear pitch"
            return
        }
        updateReadout(midi)
        let name = PitchNote.name(Int(midi.rounded()))
        status = abs(cents) <= 10 ? "Near \(name)" : "\(Int(abs(cents).rounded()))¢ \(cents < 0 ? "below" : "above") \(name)"
    }

    private func clearReadout() {
        frequency = nil
        pitchMIDI = nil
        note = "—"
        cents = 0
    }

    private func updateReadout(_ midi: Double) {
        pitchMIDI = midi
        frequency = PitchNote.frequency(midi)
        let nearest = Int(midi.rounded())
        note = PitchNote.name(nearest)
        cents = (midi - Double(nearest)) * 100
    }

    func openReview(_ take: PracticeTake) {
        guard !isRunning, !isStarting, !isSaving else { return }
        closeReview()
        referencePlayer.stop()
        reviewTake = take
        transcription.loadTranscript(for: take)
        playbackDuration = take.duration
        isLoadingReview = true
        let id = UUID()
        reviewID = id
        do {
            let playback = try RecordingPlayback(url: take.audioURL)
            recordingPlayback = playback
            playbackDuration = playback.duration
            canPlayReview = true
            playback.onFinish = { [weak self] in
                guard let self, self.reviewID == id else { return }
                self.pausePlayback()
                self.playbackTime = self.playbackDuration
            }
            playback.onOutputInterrupted = { [weak self] in
                guard let self, self.reviewID == id else { return }
                self.pausePlayback()
                self.resumeAfterScrubbing = false
                self.isScrubbing = false
                self.updatePlaybackRoute()
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            updatePlaybackRoute()
        } catch {
            reviewError = "Could not prepare recording playback: \(error.localizedDescription)"
        }
        let store = store
        reviewTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try store.analysis(for: take) }
            do {
                let analysis = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, reviewID == id else { return }
                reviewAnalysis = analysis
                isLoadingReview = false
            } catch {
                guard !Task.isCancelled, reviewID == id else { return }
                isLoadingReview = false
                let message = "Pitch analysis unavailable: \(error.localizedDescription)"
                reviewError = [reviewError, message].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    func prepareNewTake() {
        guard !isRunning, !isStarting, !isSaving else { return }
        closeReview()
        clearReadout()
        recordingDuration = 0
        status = "Ready"
    }

    func closeReview() {
        let hadReview = reviewTake != nil || recordingPlayback != nil
        pausePlayback()
        resumeAfterScrubbing = false
        isScrubbing = false
        reviewTask?.cancel()
        reviewTask = nil
        reviewID = nil
        recordingPlayback = nil
        reviewTake = nil
        reviewAnalysis = nil
        reviewError = nil
        isLoadingReview = false
        playbackTime = 0
        playbackDuration = 0
        playbackBoost = false
        playbackRate = .normal
        playbackRouteName = "Audio output"
        canPlayReview = false
        if hadReview {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func togglePlayback() {
        if isPlaying { pausePlayback() }
        else { play() }
    }

    private func play() {
        guard let recordingPlayback, canPlayReview, !isRunning else { return }
        referencePlayer.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            try recordingPlayback.play()
            isPlaying = recordingPlayback.isPlaying
            playbackTime = recordingPlayback.currentTime
            updatePlaybackRoute()
            playbackTask?.cancel()
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isPlaying else { return }
                    self.playbackTime = self.recordingPlayback?.currentTime ?? self.playbackTime
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } catch {
            pausePlayback()
            errorMessage = "Could not play recording: \(error.localizedDescription)"
        }
    }

    private func pausePlayback() {
        recordingPlayback?.pause()
        playbackTime = recordingPlayback?.currentTime ?? playbackTime
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        guard let recordingPlayback else {
            playbackTime = min(playbackDuration, max(0, time))
            return
        }
        do {
            try recordingPlayback.seek(to: time)
            playbackTime = recordingPlayback.currentTime
            isPlaying = recordingPlayback.isPlaying
        } catch {
            pausePlayback()
            errorMessage = "Could not seek in recording: \(error.localizedDescription)"
        }
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrubbing = isPlaying
        pausePlayback()
    }

    func endScrubbing() {
        let resume = resumeAfterScrubbing
        resumeAfterScrubbing = false
        isScrubbing = false
        if resume, playbackTime < playbackDuration { play() }
    }

    func setPlaybackRate(_ rate: PlaybackRate) {
        guard let recordingPlayback else { return }
        do {
            try recordingPlayback.setRate(rate)
        } catch {
            pausePlayback()
            errorMessage = "Could not change playback speed: \(error.localizedDescription)"
        }
        playbackRate = recordingPlayback.rate
        playbackTime = recordingPlayback.currentTime
        isPlaying = recordingPlayback.isPlaying
    }

    func setPlaybackBoost(_ enabled: Bool) {
        guard let recordingPlayback else { return }
        do {
            try recordingPlayback.setBoost(enabled)
            playbackBoost = recordingPlayback.boostEnabled
        } catch {
            errorMessage = "Could not adjust playback boost: \(error.localizedDescription)"
        }
    }

    private func updatePlaybackRoute() {
        guard reviewTake != nil else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        playbackRouteName = outputs.isEmpty ? "Audio output" : outputs.map {
            $0.portType == .builtInSpeaker ? "iPhone speaker" : $0.portName
        }.joined(separator: ", ")
    }

    func renameRecording(_ take: PracticeTake, title: String) {
        do {
            try store.rename(take, to: title)
            reloadRecordings()
            if reviewTake?.id == take.id, let updated = recordings.first(where: { $0.id == take.id }) {
                reviewTake = updated
                reviewAnalysis?.title = updated.title
            }
        } catch { errorMessage = "Could not rename recording: \(error.localizedDescription)" }
    }

    func deleteRecording(_ take: PracticeTake) {
        guard !isLoadingReview else { return }
        do {
            try store.delete(take)
            transcription.deleteTranscript(for: take)
            if reviewTake?.id == take.id { closeReview() }
            reloadRecordings()
        } catch { errorMessage = "Could not delete recording: \(error.localizedDescription)" }
    }

    private func reloadRecordings() {
        do { recordings = try store.recordings() }
        catch { errorMessage = "Could not load recordings: \(error.localizedDescription)" }
    }

    func handleBackground() {
        stop()
        pausePlayback()
        resumeAfterScrubbing = false
        isScrubbing = false
        referencePlayer.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// The tap owns sample access; no sample buffers are copied or retained after it returns.
// The lock also serializes finalization with an in-flight tap when capture stops.
private final class PitchCapture: @unchecked Sendable {
    struct Update {
        let estimate: PitchEstimate
        let duration: Double
        let error: String?
    }

    struct Completed: Sendable {
        let url: URL?
        let analysis: TakeAnalysis
    }

    private let lock = NSLock()
    private let analyzer: PitchAnalyzer
    private let sampleRate: Double
    private let url: URL?
    private let createdAt = Date()
    private var file: AVAudioFile?
    private var frames: [PitchFrame] = []
    private var sampleCount: AVAudioFramePosition = 0
    private var finished = false

    init(format: AVAudioFormat, url: URL?) throws {
        self.sampleRate = format.sampleRate
        self.url = url
        analyzer = PitchAnalyzer(sampleRate: format.sampleRate, maximumFrameCount: 16384)
        if let url {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
            frames.reserveCapacity(3600)
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) -> Update {
        lock.lock()
        defer { lock.unlock() }
        let noPitch = PitchEstimate(midi: nil, confidence: 0)
        guard !finished, let samples = buffer.floatChannelData?.pointee else {
            return Update(estimate: noPitch, duration: Double(sampleCount) / sampleRate, error: nil)
        }
        do { try file?.write(from: buffer) }
        catch {
            finished = true
            return Update(estimate: noPitch, duration: Double(sampleCount) / sampleRate, error: error.localizedDescription)
        }
        let count = Int(buffer.frameLength)
        let duration = Double(count) / sampleRate
        let estimate = analyzer.analyze(samples, count: count)
        if file != nil {
            frames.append(PitchFrame(time: Double(sampleCount) / sampleRate, duration: duration, midi: estimate.midi, confidence: estimate.confidence))
        }
        sampleCount += AVAudioFramePosition(count)
        return Update(estimate: estimate, duration: Double(sampleCount) / sampleRate, error: nil)
    }

    func finish() -> Completed {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        file = nil
        return Completed(url: url, analysis: TakeAnalysis(title: "Take", createdAt: createdAt, duration: Double(sampleCount) / sampleRate, frames: frames))
    }
}

@MainActor
private final class PitchPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private let buffer: AVAudioPCMBuffer
    private var bufferedMIDI: Double?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 3))!
        buffer.frameLength = buffer.frameCapacity
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(midi: Double) throws {
        stop()
        if bufferedMIDI != midi, let samples = buffer.floatChannelData?.pointee {
            let frequency = PitchNote.frequency(midi)
            for frame in 0..<Int(buffer.frameLength) {
                let time = Double(frame) / sampleRate
                let envelope = min(1, time / 0.012) * min(1, (3 - time) / 0.03)
                let phase = 2 * Double.pi * frequency * time
                // This harmonic mix peaks below 1.28; 0.75 keeps it below full scale.
                samples[frame] = Float(0.75 * envelope * (sin(phase) + 0.42 * sin(phase * 2) + 0.20 * sin(phase * 3)))
            }
            bufferedMIDI = midi
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        try engine.start()
        player.scheduleBuffer(buffer)
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
