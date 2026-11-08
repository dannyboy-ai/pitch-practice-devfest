import BackgroundTasks
import Foundation
import OSLog

@MainActor
final class ContinuedTranscriptionTask {
    static let shared = ContinuedTranscriptionTask()
    private static let prefix = "ai.dannyboy.pitchpractice.transcription."
    private let logger = Logger(subsystem: "ai.dannyboy.pitchpractice", category: "TranscriptionBackground")
    private var requestID: String?
    private var task: BGContinuedProcessingTask?
    private var onExpiration: (() -> Void)?
    private var onStart: (() -> Void)?
    private var lastProgress: (processed: Int64, total: Int64, recording: Bool)?

    var isRunning: Bool { task != nil }
    var hasRequest: Bool { requestID != nil }

    private init() {
        logger.notice("GPU supported=\(BGTaskScheduler.supportedResources.contains(.gpu)); speech uses CPU/Neural Engine, no GPU requested")
    }

    /// Called when Record or an explicit Analyze/Resume action has a ready model and audio window.
    func begin(onStart: @escaping () -> Void, onExpiration: @escaping () -> Void) {
        self.onStart = onStart
        self.onExpiration = onExpiration
        guard requestID == nil else { return }
        let identifier = Self.prefix + UUID().uuidString
        // The plist advertises a wildcard, but registration and submission both
        // use the same concrete identifier. Each launch handler is registered once.
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.accept(continued)
            }
        }) else {
            logger.error("Continued speech task registration was rejected")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Analyzing your singing", subtitle: "Recognizing recorded audio"
        )
        request.strategy = .fail
        // The fixed model configuration never schedules GPU work, including mel.
        request.requiredResources = []
        requestID = identifier
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.notice("Continued speech task submitted")
        } catch {
            requestID = nil
            logger.notice("Continued speech task unavailable: \(error.localizedDescription, privacy: .public)")
            // Foreground analysis still works. If backgrounded without a grant,
            // the coordinator checkpoints and resumes when foregrounded again.
        }
    }

    private func accept(_ continued: BGContinuedProcessingTask) {
        guard continued.identifier == requestID else {
            continued.setTaskCompleted(success: false)
            return
        }
        task = continued
        continued.progress.totalUnitCount = 1
        continued.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.task?.identifier == continued.identifier else { return }
                let callback = self.onExpiration
                self.finish(success: false)
                callback?()
            }
        }
        logger.notice("Continued speech task running")
        onStart?()
    }

    func update(processed: Double, duration: Double, recording: Bool) {
        guard let task else { return }
        let total = max(1, Int64(duration.rounded(.up)))
        let completed = min(total, max(0, Int64(processed)))
        if let lastProgress, lastProgress.processed == completed,
           lastProgress.total == total, lastProgress.recording == recording { return }
        lastProgress = (completed, total, recording)
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
        task.updateTitle("Analyzing your singing", subtitle: recording
                         ? "Recognized through \(Int(processed))s while recording"
                         : "Recognized \(Int(processed)) of \(Int(duration)) seconds")
    }

    func finish(success: Bool) {
        if let task {
            task.expirationHandler = nil
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
            logger.notice("Continued speech task completed success=\(success)")
        } else if let requestID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID)
        }
        task = nil
        requestID = nil
        onStart = nil
        onExpiration = nil
        lastProgress = nil
    }
}
