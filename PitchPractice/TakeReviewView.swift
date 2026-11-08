import SwiftUI

struct TakeReviewView: View {
    let detector: PitchDetector
    let take: PracticeTake
    let onNewTake: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var trace: ReviewTrace?
    @State private var isDraggingTimeline = false
    @GestureState private var globalGestureActive = false
    @State private var window = ReviewWindow(duration: 0)
    @State private var pinchStart: ReviewWindow?
    @State private var dragStart: ReviewWindow?
    @State private var dragStartTime: Double?
    @GestureState private var timelineGestureActive = false
    @AppStorage("replayClef") private var replayClef = ReplayClef.tenor
    @ScaledMetric(relativeTo: .body) private var badgeWidth: CGFloat = 246
    @ScaledMetric(relativeTo: .body) private var badgeHeight: CGFloat = 110
    @State private var showRename = false
    @State private var showDelete = false
    @State private var editedTitle = ""
    @State private var showAudioOutput = false
    @State private var showRecognition = false

    private var currentTake: PracticeTake { detector.reviewTake ?? take }
    private var duration: Double { max(0, detector.playbackDuration) }
    private var isInteracting: Bool { isDraggingTimeline || globalGestureActive || pinchStart != nil || timelineGestureActive }
    private var currentPitch: Double? { detector.reviewAnalysis?.frame(at: detector.playbackTime)?.midi }
    private var playheadIsVisible: Bool {
        detector.playbackTime >= window.start && detector.playbackTime <= window.end
    }

    var body: some View {
        GeometryReader { geometry in
            if dynamicTypeSize > .large || geometry.size.height < 560 {
                ScrollView {
                    reviewContent
                        .frame(minHeight: 560)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            } else {
                reviewContent
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                playbackControls
                Button("Done", action: onNewTake)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Returns to a ready screen without starting a recording")
                    .accessibilityIdentifier("newTakeButton")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Audio output", systemImage: "speaker.wave.2") {
                        showAudioOutput = true
                    }
                    .accessibilityIdentifier("showAudioOutputButton")
                    Button("Recognition status", systemImage: "text.quote") {
                        showRecognition = true
                    }
                    .accessibilityIdentifier("showRecognitionStatusButton")
                    Divider()
                    Button("Rename", systemImage: "pencil") {
                        editedTitle = currentTake.title
                        showRename = true
                    }
                    .disabled(detector.isLoadingReview)
                    Button("Delete Recording", systemImage: "trash", role: .destructive) {
                        showDelete = true
                    }
                    .disabled(detector.isLoadingReview)
                } label: {
                    Label("Recording actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("recordingActions")
            }
        }
        .sheet(isPresented: $showAudioOutput) {
            NavigationStack {
                ScrollView {
                    PlaybackOutputControls(detector: detector)
                        .padding()
                }
                .navigationTitle("Audio output")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showAudioOutput = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRecognition) {
            NavigationStack {
                ScrollView { recognitionDetails.padding() }
                    .navigationTitle("Recognition")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showRecognition = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Rename Recording", isPresented: $showRename) {
            TextField("Name", text: $editedTitle)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                detector.renameRecording(currentTake, title: editedTitle.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete this recording?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                detector.deleteRecording(currentTake)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The saved audio, pitch analysis, and transcript will be permanently deleted.")
        }
        .alert("Pitch Practice", isPresented: Binding(
            get: { detector.errorMessage != nil },
            set: { if !$0 { detector.errorMessage = nil } }
        )) {
            Button("OK") { detector.errorMessage = nil }
        } message: {
            Text(detector.errorMessage ?? "")
        }
        .onChange(of: detector.isLoadingReview, initial: true) { _, loading in
            if !loading, let analysis = detector.reviewAnalysis {
                trace = ReviewTrace(analysis: analysis)
                window = ReviewWindow(duration: duration)
                window.follow(detector.playbackTime)
            }
        }
        .onChange(of: duration) { _, duration in
            window = ReviewWindow(duration: duration)
            window.follow(detector.playbackTime)
        }
        .onChange(of: detector.playbackTime) { _, time in
            if detector.isPlaying, !isInteracting { window.follow(time) }
        }
        .onChange(of: timelineGestureActive) { _, active in
            if !active { finishTimelineGesture() }
        }
        .onChange(of: globalGestureActive) { _, active in
            if !active { finishGlobalGesture() }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTake.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text(currentTake.timeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !detector.isLoadingReview, detector.reviewError == nil, detector.canPlayReview {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("takeSavedStatus")
                }
            }
            if detector.isLoadingReview {
                ProgressView("Loading pitch analysis…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = detector.reviewError {
                ContentUnavailableView("Recording could not be fully loaded",
                                       systemImage: "waveform.badge.exclamationmark",
                                       description: Text(error))
            } else if let trace {
                timeline(trace)
                viewportControls
            }
        }
    }

    private var recognitionDetails: some View {
        let transcript = detector.transcription.transcript(for: currentTake)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Approximate on-device recognition, not verified lyrics. Tap a phrase to seek in the recording.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let transcript {
                transcriptStatus(transcript)
                if transcript.requiresWordTimings {
                    transcribeButton("Add word timing")
                }

                if transcript.displayPhrases.isEmpty {
                    Text(transcript.status == .complete
                         ? "No recognizable words were found. This does not mean the recording is silent."
                         : "No recognized phrases saved yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(transcript.displayPhrases) { phrase in
                            transcriptPhrase(phrase)
                        }
                    }
                }
            } else {
                Text("No saved transcript")
                    .font(.subheadline.weight(.medium))
                Text(detector.transcription.modelStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcriptionStatus")
                Text("Recognition is optional. Audio and pitch review remain available without it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                transcribeButton("Analyze on iPhone")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcriptSection")
    }

    private func transcriptStatus(_ transcript: TakeTranscript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if transcript.status == .transcribing ||
                    (transcript.status == .queued && detector.transcription.isPreparing) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(transcriptStatusTitle(transcript.status))
                    .font(.subheadline.weight(.medium))
            }
            if transcript.status != .complete {
                Text(transcript.message ?? detector.transcription.modelStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Analyzed \(practiceTime(transcript.processedThrough)) of \(practiceTime(transcript.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if transcript.previousPhrases != nil {
                Text("Adding word timing. Your saved phrases remain available until the new analysis finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if transcript.status == .paused {
                transcribeButton("Resume")
            } else if transcript.status == .failed {
                transcribeButton("Retry")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcriptionStatus")
    }

    private func transcriptStatusTitle(_ status: TranscriptStatus) -> String {
        switch status {
        case .recording: return "Analysis follows the recording"
        case .queued: return "Analysis pending"
        case .transcribing: return "Recognizing phrases…"
        case .paused: return "Analysis paused"
        case .complete: return "Saved transcript"
        case .failed: return "Analysis could not finish"
        }
    }

    private func transcribeButton(_ title: String) -> some View {
        Button(title) {
            detector.transcription.requestTranscript(for: currentTake)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Recognizes phrases on this iPhone without changing your recording")
        .accessibilityIdentifier("transcribeTakeButton")
    }

    private func transcriptPhrase(_ phrase: TranscriptPhrase) -> some View {
        let isCurrent = detector.playbackTime >= phrase.start && detector.playbackTime < phrase.end
        return Button {
            detector.seek(to: phrase.start)
            window.follow(detector.playbackTime)
            showRecognition = false
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(timelineTime(phrase.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(phrase.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isCurrent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!detector.canPlayReview || isInteracting)
        .accessibilityLabel(phrase.text)
        .accessibilityValue("\(timelineTime(phrase.start))\(isCurrent ? ", current phrase" : "")")
        .accessibilityHint("Seek to this phrase, keeping playback speed and whether audio is playing or paused")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("transcriptPhrase-\(phrase.id.uuidString)")
    }

    private var playbackControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button {
                detector.togglePlayback()
            } label: {
                Label(detector.isPlaying ? "Pause" : "Play",
                      systemImage: detector.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!detector.canPlayReview)
            .accessibilityIdentifier("playbackButton")

            Picker("Playback speed", selection: Binding(
                get: { detector.playbackRate },
                set: { detector.setPlaybackRate($0) }
            )) {
                ForEach(PlaybackRate.allCases, id: \.self) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 64)
            .disabled(!detector.canPlayReview || isInteracting)
            .accessibilityHint("Slows the recording without changing its pitch")
            .accessibilityIdentifier("playbackRatePicker")

            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { min(duration, max(0, detector.playbackTime)) },
                    set: {
                        detector.seek(to: $0)
                        if !isInteracting { window.follow($0) }
                    }
                ), in: 0...max(duration, 0.001))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in detector.beginScrubbing() }
                        .onEnded { _ in finishGlobalGesture() }
                        .updating($globalGestureActive) { _, active, _ in active = true }
                )
                .disabled(!detector.canPlayReview)
                .accessibilityLabel("Full recording playback position")
                .accessibilityValue("\(practiceTime(detector.playbackTime)) of \(practiceTime(duration))")
                .accessibilityIdentifier("playbackSlider")

                HStack {
                    Text(practiceTime(detector.playbackTime))
                    Spacer()
                    Text(practiceTime(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }


    private var viewportControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sectionNavigation
                Spacer(minLength: 0)
                zoomControls
            }
            VStack(spacing: 4) {
                sectionNavigation
                zoomControls
            }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
    }

    private var sectionNavigation: some View {
        HStack(spacing: 4) {
            Button {
                window.moveSection(by: -1)
                detector.seek(to: window.start)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!window.canMovePrevious || isInteracting)
            .accessibilityLabel("Previous section")
            .accessibilityIdentifier("reviewPreviousSection")
            Button {
                window.moveSection(by: 1)
                detector.seek(to: window.start)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!window.canMoveNext || isInteracting)
            .accessibilityLabel("Next section")
            .accessibilityIdentifier("reviewNextSection")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                window.zoom(by: 0.5, anchorFraction: zoomAnchor)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!window.canZoomOut || isInteracting)
            .accessibilityLabel("Zoom out")
            .accessibilityIdentifier("reviewZoomOut")
            Button {
                window.zoom(by: 2, anchorFraction: zoomAnchor)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!window.canZoomIn || isInteracting)
            .accessibilityLabel("Zoom in")
            .accessibilityIdentifier("reviewZoomIn")
            Button("10 sec") { window.reset(around: detector.playbackTime) }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Reset to ten-second view")
                .accessibilityIdentifier("reviewResetWindow")
            Button("Full take") { window.showFullTake() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reviewFullTake")
        }
        .disabled(duration <= 0 || isInteracting)
    }

    private var zoomAnchor: Double {
        if detector.playbackTime >= window.start, detector.playbackTime <= window.end {
            return window.fraction(at: detector.playbackTime)
        }
        return 0.5
    }

    private func timelineTime(_ time: Double) -> String {
        let tenths = Int((max(0, time) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private func finishGlobalGesture() {
        window.follow(detector.playbackTime)
        detector.endScrubbing()
    }

    private func finishTimelineGesture() {
        if isDraggingTimeline, pinchStart == nil { window.follow(detector.playbackTime) }
        pinchStart = nil
        dragStart = nil
        dragStartTime = nil
        if isDraggingTimeline {
            isDraggingTimeline = false
            detector.endScrubbing()
        }
    }

    private var wordTimeline: some View {
        let transcript = detector.transcription.transcript(for: currentTake)
        return VStack(alignment: .leading, spacing: 2) {
            if let transcript, !transcript.words.isEmpty {
                WordTimelineView(words: transcript.words, window: window,
                                 playbackTime: detector.playbackTime,
                                 canSeek: detector.canPlayReview && !isInteracting) { time in
                    detector.seek(to: time)
                    window.follow(detector.playbackTime)
                }
            }
            if transcript == nil || transcript?.requiresWordTimings == true || transcript?.status != .complete {
                Button {
                    showRecognition = true
                } label: {
                    HStack(spacing: 4) {
                        Text(recognitionSummary(transcript))
                            .multilineTextAlignment(.leading)
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.leading, WordTimeline.plotLeftInset)
                .accessibilityHint("Opens recognition details and recovery controls")
                .accessibilityIdentifier("recognitionSummary")
            } else if transcript?.words.isEmpty == true {
                Text("No recognized words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, WordTimeline.plotLeftInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wordTimingSection")
    }

    private func recognitionSummary(_ transcript: TakeTranscript?) -> String {
        guard let transcript else { return "Recognition not started" }
        if transcript.requiresWordTimings { return "Word timing available to add" }
        switch transcript.status {
        case .complete: return "Recognition complete"
        case .failed: return "Recognition failed · Retry"
        case .paused: return "Recognition paused · Resume"
        case .recording, .queued:
            return detector.transcription.isPreparing ? "Preparing recognition…" : "Recognition pending"
        case .transcribing: return "Recognizing words…"
        }
    }

    private func timeline(_ trace: ReviewTrace) -> some View {
        let section = trace.section(in: window)
        return VStack(spacing: 8) {
            Picker("Staff", selection: $replayClef) {
                ForEach(ReplayClef.allCases, id: \.self) { clef in
                    Text(clef.rawValue).tag(clef)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("replayClefPicker")
            VStack(spacing: 0) {
                ReplayPitchBadge(midi: playheadIsVisible ? currentPitch : nil,
                                 clef: replayClef,
                                 emptyLabel: !playheadIsVisible ? "Playhead offscreen" :
                                    detector.playbackTime >= duration ? "End of take" : "No clear pitch")
                    .frame(maxWidth: badgeWidth)
                    .frame(height: badgeHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                wordTimeline
                timelinePlot(trace, section: section)
            }
            .background(.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Text(timelineTime(window.start))
                Spacer()
                Text(timelineTime(window.time(atFraction: 0.5)))
                Spacer()
                Text(timelineTime(window.end))
            }
            .padding(.leading, 38)
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reviewWindowRange")
        }
    }

    private func timelinePlot(_ trace: ReviewTrace, section: ReviewPitchSection) -> some View {
        GeometryReader { geometry in
            let plot = reviewPlotRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                StaticPitchTrace(trace: trace, window: window, section: section).equatable()
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                if pinchStart == nil {
                                    pinchStart = window
                                    // A first finger may start a scrub before the second
                                    // arrives. Pinching zooms without changing that position.
                                    if let dragStartTime { detector.seek(to: dragStartTime) }
                                }
                                guard var zoomed = pinchStart else { return }
                                zoomed.zoom(by: Double(value.magnification),
                                            anchorFraction: Double((value.startAnchor.x * geometry.size.width - plot.minX) / plot.width))
                                window = zoomed
                            }
                            .simultaneously(with: DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard pinchStart == nil else { return }
                                    if !isDraggingTimeline {
                                        isDraggingTimeline = true
                                        dragStart = window
                                        dragStartTime = detector.playbackTime
                                        detector.beginScrubbing()
                                    }
                                    let fraction = Double((value.location.x - plot.minX) / plot.width)
                                    detector.seek(to: (dragStart ?? window).time(atFraction: fraction))
                                })
                            .onEnded { _ in finishTimelineGesture() }
                            .updating($timelineGestureActive) { _, active, _ in active = true }
                    )
                    .disabled(!detector.canPlayReview)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pitch timeline")
                    .accessibilityValue("\(timelineTime(detector.playbackTime)); visible \(timelineTime(window.start)) to \(timelineTime(window.end))")
                    .accessibilityHint("Adjust to seek within this section, or use the full recording playback position slider")
                    .accessibilityAdjustableAction { direction in
                        let step = min(1, window.visibleDuration / 10)
                        let position = min(window.end, max(window.start, detector.playbackTime))
                        detector.beginScrubbing()
                        switch direction {
                        case .increment: detector.seek(to: min(window.end, position + step))
                        case .decrement: detector.seek(to: max(window.start, position - step))
                        @unknown default: break
                        }
                        window.follow(detector.playbackTime)
                        detector.endScrubbing()
                    }
                    .accessibilityIdentifier("pitchTimeline")
                if playheadIsVisible {
                    ReplayPlayhead(midi: currentPitch, section: section,
                                   fraction: window.fraction(at: detector.playbackTime))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minHeight: 100, maxHeight: .infinity)
    }
}

private func reviewPlotRect(in size: CGSize) -> CGRect {
    CGRect(x: WordTimeline.plotLeftInset, y: 14,
           width: WordTimeline.plotWidth(viewWidth: Double(size.width)), height: max(1, size.height - 28))
}

// Cache by viewport, not by playback time. Both range fitting and Canvas paths
// stay unchanged during playhead ticks within a section.
private final class ReviewTrace {
    let frames: [PitchFrame]
    private var cachedWindow: ReviewWindow?
    private var cachedSection: ReviewPitchSection?

    init(analysis: TakeAnalysis) {
        frames = analysis.frames
    }

    func section(in window: ReviewWindow) -> ReviewPitchSection {
        if cachedWindow == window, let cachedSection { return cachedSection }
        let section = ReviewPitchSection(frames: frames, window: window)
        cachedWindow = window
        cachedSection = section
        return section
    }

    func path(in window: ReviewWindow, section: ReviewPitchSection, rect: CGRect) -> Path {
        var result = Path()
        guard window.visibleDuration > 0 else { return result }
        var previousEnd: Double?
        for index in section.frameRange {
            let frame = frames[index]
            guard let midi = frame.midi else {
                previousEnd = nil
                continue
            }
            let start = max(window.start, frame.time)
            let end = min(window.end, frame.time + frame.duration)
            guard end > start else { previousEnd = nil; continue }
            let y = rect.minY + section.verticalFraction(for: midi) * rect.height
            let point = CGPoint(x: rect.minX + window.fraction(at: start) * rect.width, y: y)
            if let previousEnd, abs(start - previousEnd) < 0.0001 {
                result.addLine(to: point)
            } else {
                result.move(to: point)
            }
            result.addLine(to: CGPoint(x: rect.minX + window.fraction(at: end) * rect.width, y: y))
            previousEnd = end
        }
        return result
    }
}

private struct StaticPitchTrace: View, Equatable {
    let trace: ReviewTrace
    let window: ReviewWindow
    let section: ReviewPitchSection

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trace === rhs.trace && lhs.window == rhs.window
    }

    var body: some View {
        Canvas { context, size in
            let plot = reviewPlotRect(in: size)
            for midi in section.lowerMIDI...section.upperMIDI {
                let y = plot.minY + section.verticalFraction(for: Double(midi)) * plot.height
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            }
            if section.hasPitch {
                let labelFont = Font.caption.weight(.semibold)
                let labelHeight = context.resolve(Text("C♯").font(labelFont))
                    .measure(in: CGSize(width: plot.minX - 8, height: .greatestFiniteMagnitude)).height
                var previousY = -CGFloat.infinity
                // Dense word rows can shorten the graph; thin labels, never pitch data.
                for midi in section.labels.reversed() {
                    let y = plot.minY + section.verticalFraction(for: Double(midi)) * plot.height
                    guard y - previousY >= labelHeight + 4 else { continue }
                    let label = Text(PitchNote.name(midi)).font(labelFont).foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
                    previousY = y
                }
            }
            context.stroke(trace.path(in: window, section: section, rect: plot), with: .color(.primary.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct ReplayPlayhead: View {
    let midi: Double?
    let section: ReviewPitchSection
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            let plot = reviewPlotRect(in: geometry.size)
            let color = midi.map { PitchTuning(midi: $0).color } ?? .secondary
            let x = plot.minX + fraction * plot.width
            let y = plot.minY + (midi.map { section.verticalFraction(for: $0) } ?? 0.5) * plot.height

            Canvas { context, _ in
                if let midi {
                    let ideal = midi.rounded()
                    let idealY = plot.minY + section.verticalFraction(for: ideal) * plot.height
                    if (plot.minY...plot.maxY).contains(idealY) {
                        let tolerance = 0.1 / Double(section.upperMIDI - section.lowerMIDI) * plot.height
                        context.fill(Path(CGRect(x: plot.minX, y: idealY - tolerance,
                                                 width: plot.width, height: tolerance * 2)),
                                     with: .color(color.opacity(0.12)))
                    }
                }
                var playhead = Path()
                playhead.move(to: CGPoint(x: x, y: plot.minY))
                playhead.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(playhead, with: .color(.primary.opacity(0.35)), lineWidth: 1.5)
            }
            .accessibilityHidden(true)

            if midi != nil {
                Circle().fill(color)
                    .frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                    .position(x: x, y: y)
                    .accessibilityHidden(true)
            }
        }
    }
}
