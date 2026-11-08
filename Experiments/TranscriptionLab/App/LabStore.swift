import AVFoundation
import SwiftUI
import TranscriptionEngines

@MainActor
final class LabStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var model = LabModel.whisperTurbo
    @Published var selectedFile = "all"
    @Published var recordings: [LabRecording] = []
    @Published var reports: [LabReport] = []
    @Published var status = "Ready"
    @Published var isRunning = false
    @Published var playingFile: String?
    @Published var isPlaying = false
    @Published var error: String?

    private var job: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let documents = URL.documentsDirectory
    var position: Double { player?.currentTime ?? 0 }

    override init() {
        super.init()
        do {
            for name in ["Recordings", "Models", "Reports"] {
                try FileManager.default.createDirectory(at: documents.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            recordings = try LabRecording.load(from: documents.appendingPathComponent("Recordings"))
            reports = try LabReport.load(from: documents.appendingPathComponent("Reports"))
        } catch { self.error = error.localizedDescription }
    }

    func run() {
        guard !isRunning else { return }
        stopAudio()
        isRunning = true
        error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let files = selectedFile == "all" ? recordings : recordings.filter { $0.filename == selectedFile }
        let selectedModel = model
        job = Task {
            defer {
                isRunning = false
                UIApplication.shared.isIdleTimerDisabled = false
                job = nil
            }
            do {
                let report = try await BenchmarkRunner.run(
                    model: selectedModel, recordings: files,
                    modelsDirectory: documents.appendingPathComponent("Models"),
                    reportsDirectory: documents.appendingPathComponent("Reports")
                ) { [weak self] message in
                    print(message)
                    Task { @MainActor in self?.status = message }
                }
                reports.insert(report, at: 0)
                status = report.status
                if let failure = report.error { error = failure }
            } catch {
                self.error = error.localizedDescription
                status = "Failed to save benchmark"
            }
        }
    }

    func cancel() { job?.cancel() }

    func play(_ recording: LabRecording) {
        guard !isRunning else { return }
        if playingFile == recording.filename, let player {
            if player.isPlaying { player.pause(); isPlaying = false }
            else { isPlaying = player.play() }
            return
        }
        stopAudio()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let audio = try AVAudioPlayer(contentsOf: recording.url)
            audio.delegate = self
            guard audio.play() else {
                throw NSError(domain: "TranscriptionLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start audio playback."])
            }
            player = audio
            playingFile = recording.filename
            isPlaying = true
        } catch { self.error = error.localizedDescription }
    }

    func seek(_ time: Double) { player?.currentTime = time }

    func stopAudio() {
        player?.stop()
        player = nil
        playingFile = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stopAudio() }
    }
}
