import AVFoundation
import AudioToolbox

enum PlaybackRate: Float, CaseIterable, Sendable {
    case quarter = 0.25
    case half = 0.5
    case threeQuarter = 0.75
    case normal = 1

    var label: String {
        switch self {
        case .quarter: "¼×"
        case .half: "½×"
        case .threeQuarter: "¾×"
        case .normal: "1×"
        }
    }
}

// Shared by playback and offline rendering: gain is applied inside Apple's peak
// limiter, never to the saved recording or to the system's output volume.
@MainActor
final class RecordingPlaybackLimiter {
    let unit: AVAudioUnitEffect

    init() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &description) != nil else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidProperty), userInfo: [
                NSLocalizedDescriptionKey: "The audio peak limiter is unavailable."
            ])
        }
        unit = AVAudioUnitEffect(audioComponentDescription: description)
        try setBoost(false)
    }

    func setBoost(_ enabled: Bool) throws {
        let result = AudioUnitSetParameter(unit.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, enabled ? 12 : 0, 0)
        guard result == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "Could not set the playback limiter's gain."
            ])
        }
    }
}

// AVAudioPlayerNode streams file segments. The only timeline is its rendered
// sample clock plus the file-frame offset of the current segment.
@MainActor
final class RecordingPlayback {
    let duration: TimeInterval
    private(set) var isPlaying = false
    private(set) var boostEnabled = false
    private(set) var rate = PlaybackRate.normal
    var onFinish: (() -> Void)?
    var onOutputInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let file: AVAudioFile
    private let limiter: RecordingPlaybackLimiter
    private let sampleRate: Double
    private let frameCount: AVAudioFramePosition
    private var positionFrame: AVAudioFramePosition = 0
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var segmentID: UUID?
    private var configurationObserver: NSObjectProtocol?

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0, file.length > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "This recording contains no playable audio."
            ])
        }
        sampleRate = format.sampleRate
        frameCount = file.length
        duration = Double(frameCount) / sampleRate
        limiter = try RecordingPlaybackLimiter()
        engine.attach(player)
        timePitch.pitch = 0
        timePitch.bypass = true
        engine.attach(timePitch)
        engine.attach(limiter.unit)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: limiter.unit, format: format)
        engine.connect(limiter.unit, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, !self.engine.isRunning else { return }
                self.pause()
                self.onOutputInterrupted?()
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    var currentTime: TimeInterval {
        if isPlaying,
           let renderTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: renderTime),
           playerTime.isSampleTimeValid, playerTime.sampleRate > 0 {
            // This is the source-frame clock: time stretching already changes its
            // advance rate. Multiplying by the selected speed would apply it twice.
            let elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
            let remaining = frameCount - segmentStartFrame
            let rendered = AVAudioFramePosition(min(Double(remaining), elapsed * sampleRate))
            // Retain the last observed position if a route change resets the node.
            positionFrame = max(positionFrame, segmentStartFrame + rendered)
        }
        return Double(positionFrame) / sampleRate
    }

    func setBoost(_ enabled: Bool) throws {
        try limiter.setBoost(enabled)
        boostEnabled = enabled
    }

    func setRate(_ rate: PlaybackRate) throws {
        guard rate != self.rate else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        timePitch.rate = rate.rawValue
        timePitch.bypass = rate == .normal
        self.rate = rate
        if wasPlaying, positionFrame < frameCount { try play() }
    }

    func play() throws {
        guard !isPlaying else { return }
        if positionFrame >= frameCount { positionFrame = 0 }
        let id = UUID()
        segmentID = id
        segmentStartFrame = positionFrame
        do {
            try engine.start()
        } catch {
            segmentID = nil
            engine.stop()
            throw error
        }

        // A segment's frame count is UInt32 even though a file's length is Int64.
        // Queue consecutive segments without allocating sample buffers for long files.
        var start = positionFrame
        let maximumSegment = AVAudioFramePosition(AVAudioFrameCount.max)
        while frameCount - start > maximumSegment {
            player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount.max, at: nil)
            start += maximumSegment
        }
        player.scheduleSegment(
            file, startingFrame: start, frameCount: AVAudioFrameCount(frameCount - start),
            at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.segmentID == id, self.isPlaying else { return }
                self.pause()
                self.positionFrame = self.frameCount
                self.onFinish?()
            }
        }
        isPlaying = true
        player.play()
    }

    func pause() {
        _ = currentTime
        // stop() can deliver a completion for cancelled audio; invalidate first.
        segmentID = nil
        isPlaying = false
        player.stop()
        engine.pause()
        engine.reset()
    }

    func seek(to time: TimeInterval) throws {
        guard time.isFinite else { return }
        let wasPlaying = isPlaying
        pause()
        let clamped = min(duration, max(0, time))
        // The first frame at or after the requested boundary, not just before it.
        // Model timestamps can fall between samples even when displayed identically.
        positionFrame = clamped >= duration ? frameCount : AVAudioFramePosition((clamped * sampleRate).rounded(.up))
        if wasPlaying, positionFrame < frameCount { try play() }
    }
}
