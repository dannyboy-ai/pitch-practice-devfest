import SwiftUI

struct ContentView: View {
    private enum Route: Hashable {
        case recordings
        case review(PracticeTake)

        var reviewID: String? {
            guard case let .review(take) = self else { return nil }
            return take.id
        }
    }

    @State private var detector = PitchDetector()
    @State private var routes: [Route] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var statusHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var feedbackHeight: CGFloat = 78

    private var controlsBusy: Bool {
        detector.isStarting || detector.isSaving
    }

    private var noteColor: Color {
        guard let midi = detector.pitchMIDI else { return .secondary }
        return PitchTuning(midi: midi).color
    }

    private var navigationPath: Binding<[Route]> {
        Binding(
            get: { routes },
            set: { newRoutes in
                let previousReviewID = routes.last?.reviewID
                routes = newRoutes
                if let previousReviewID, previousReviewID != newRoutes.last?.reviewID {
                    detector.closeReview()
                }
            }
        )
    }

    var body: some View {
        NavigationStack(path: navigationPath) {
            GeometryReader { geometry in
                ScrollView {
                    pitchSurface
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .bottom) {
                controls
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle("Pitch Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        routes.append(.recordings)
                    } label: {
                        Label("Recordings", systemImage: "waveform")
                    }
                    .disabled(detector.isRunning || controlsBusy)
                    .accessibilityIdentifier("recordingsButton")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .recordings:
                    recordingsList
                case let .review(take):
                    TakeReviewView(detector: detector, take: take, onNewTake: prepareNewTake)
                }
            }
        }
        .alert("Pitch Practice", isPresented: Binding(
            get: { detector.errorMessage != nil && detector.reviewTake == nil },
            set: { if !$0 { detector.errorMessage = nil } }
        )) {
            Button("OK") { detector.errorMessage = nil }
        } message: {
            Text(detector.errorMessage ?? "")
        }
        .onAppear {
            detector.transcription.setAppActive(scenePhase != .background)
        }
        .onChange(of: detector.reviewTake?.id, initial: true) { _, _ in
            synchronizeReviewNavigation()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { detector.handleBackground() }
            detector.transcription.setAppActive(phase != .background)
        }
    }

    private func synchronizeReviewNavigation() {
        let reviewIndex = routes.firstIndex { $0.reviewID != nil }
        guard let take = detector.reviewTake else {
            if let reviewIndex { routes.removeSubrange(reviewIndex...) }
            return
        }
        guard routes.last?.reviewID != take.id else { return }
        if let reviewIndex { routes.removeSubrange(reviewIndex...) }
        routes.append(.review(take))
    }

    private func prepareNewTake() {
        detector.prepareNewTake()
        routes.removeAll()
    }

    private var pitchSurface: some View {
        VStack(spacing: 18) {
            StaffPair(
                pitch: detector.pitchMIDI ?? (detector.isRunning ? nil : detector.referenceMIDI),
                noteColor: noteColor,
                isInteractive: !detector.isRunning && !controlsBusy,
                onPitchChange: detector.selectPitch
            )
            .frame(height: 236)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pitch staff")
            .accessibilityValue(detector.pitchMIDI.map { PitchNote.name(Int($0.rounded())) } ?? "No detected pitch")
            .accessibilityIdentifier("practiceStaff")

            liveReadout

            PitchLane(
                pitch: detector.pitchMIDI ?? (detector.isRunning ? nil : detector.referenceMIDI),
                markerColor: noteColor,
                isInteractive: !detector.isRunning && !controlsBusy,
                onPitchChange: detector.selectPitch
            )
            .frame(height: 100)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if detector.isRecording || detector.isSaving {
                recordingControls
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    idleControls
                }
            } else {
                HStack(spacing: 8) {
                    idleControls
                }
            }
        }
        .overlay(alignment: .top) {
            if controlsBusy {
                ProgressView()
                    .accessibilityLabel(detector.isSaving ? "Saving audio and pitch" : "Starting microphone")
                    .offset(y: -24)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var idleControls: some View {
        Button {
            detector.playReference()
        } label: {
            Label("Listen", systemImage: "speaker.wave.2.fill")
                .frame(maxWidth: .infinity)
        }
        .labelStyle(.titleOnly)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .buttonStyle(.bordered)
        .disabled(controlsBusy)
        .accessibilityIdentifier("listenReferenceButton")
        .accessibilityHint("Play the reference selected on the pitch lane")

        Button {
            if detector.isRunning { detector.stop() } else { detector.startListening() }
        } label: {
            Label(detector.isRunning ? "Stop" : "Tune",
                  systemImage: detector.isRunning ? "stop.fill" : "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .labelStyle(.titleOnly)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .buttonStyle(.borderedProminent)
        .tint(detector.isRunning ? .red : .accentColor)
        .disabled(controlsBusy)
        .accessibilityIdentifier("tuneButton")
        .accessibilityHint(detector.isRunning ? "Stop unsaved pitch detection" : "Detect pitch without saving a recording")

        Button {
            detector.startRecording()
        } label: {
            Label("Practice", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .labelStyle(.titleOnly)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(controlsBusy)
        .accessibilityIdentifier("practiceButton")
    }

    private var recordingControls: some View {
        HStack(spacing: 16) {
            Text(practiceTime(detector.recordingDuration))
                .font(.title2.monospacedDigit())
                .accessibilityLabel("Recording time")
                .accessibilityValue(practiceTime(detector.recordingDuration))
                .accessibilityIdentifier("recordingTime")
            Button {
                detector.stop()
            } label: {
                Label("Stop & Review", systemImage: "stop.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(controlsBusy)
            .accessibilityIdentifier("stopAndReviewButton")
        }
    }

    private var liveReadout: some View {
        VStack(spacing: 6) {
            Text(detector.pitchMIDI == nil ? "—" : detector.note)
                .font(.system(size: 68, weight: .bold, design: .rounded))
                .foregroundStyle(noteColor)
                .accessibilityLabel("Current note")
                .accessibilityValue(detector.pitchMIDI == nil ? "No detected pitch" : detector.note)
            Text(detector.isRunning ? (detector.isRecording ? "Recording" : "Tuning") : detector.status)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: statusHeight)
            TuningIndicator(midi: detector.pitchMIDI)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: feedbackHeight, alignment: .top)
                .opacity(detector.pitchMIDI != nil || detector.isRunning ? 1 : 0)
                .accessibilityHidden(detector.pitchMIDI == nil && !detector.isRunning)
        }
    }

    private var recordingsList: some View {
        List {
            if detector.recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform",
                                       description: Text("Record a Practice take to save audio and pitch on this iPhone."))
            } else {
                ForEach(detector.recordings) { take in
                    Button {
                        guard detector.reviewTake?.id != take.id else { return }
                        detector.openReview(take)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(take.title) · \(take.timeLabel)")
                                    .font(.headline).foregroundStyle(.primary)
                                Text(take.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(practiceTime(take.duration))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Open recording for playback, pitch and transcript review, rename, or delete")
                }
            }
        }
        .navigationTitle("Recordings")
    }
}


private struct PitchLane: View {
    let pitch: Double?
    let markerColor: Color
    let isInteractive: Bool
    let onPitchChange: (Double) -> Void
    @State private var dragStartPitch: Double?
    @State private var momentumTask: Task<Void, Never>?
    @State private var selectedDetent = 69

    var body: some View {
        GeometryReader { geometry in
            let livePitch = pitch ?? 69
            let nearest = Int(livePitch.rounded())
            let spacing = geometry.size.width / 4

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.secondary.opacity(0.14))
                    .frame(height: 12)
                    .offset(y: 37)

                ForEach((nearest - 3)...(nearest + 3), id: \.self) { midi in
                    let x = geometry.size.width / 2 + CGFloat(Double(midi) - livePitch) * spacing
                    Rectangle()
                        .fill(.green.opacity(0.22))
                        .frame(width: spacing * 0.2, height: 28)
                        .position(x: x, y: 43)
                    Rectangle()
                        .fill(.secondary.opacity(0.65))
                        .frame(width: 2, height: 30)
                        .position(x: x, y: 43)
                    Text(noteName(midi))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .position(x: x, y: 78)
                }

                Rectangle()
                    .fill(markerColor)
                    .frame(width: 3, height: 50)
                    .position(x: geometry.size.width / 2, y: 31)
                Image(systemName: "triangle.fill")
                    .font(.caption)
                    .foregroundStyle(markerColor)
                    .position(x: geometry.size.width / 2, y: 5)
            }
            .animation(.linear(duration: 0.06), value: pitch)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard isInteractive else { return }
                        momentumTask?.cancel()
                        momentumTask = nil
                        if dragStartPitch == nil { dragStartPitch = livePitch }
                        guard let start = dragStartPitch else { return }
                        let detent = min(84, max(36, Int((start - 1.5 * Double(value.translation.width / spacing)).rounded())))
                        if detent != selectedDetent {
                            selectedDetent = detent
                            onPitchChange(Double(detent))
                        }
                    }
                    .onEnded { value in
                        guard isInteractive else {
                            dragStartPitch = nil
                            return
                        }
                        let extraTranslation = value.predictedEndTranslation.width - value.translation.width
                        var velocity = -1.5 * Double(extraTranslation / spacing) * 0.19
                        var currentPitch = pitch ?? livePitch
                        dragStartPitch = nil
                        momentumTask?.cancel()
                        momentumTask = Task { @MainActor in
                            while !Task.isCancelled && abs(velocity) > 0.002 {
                                currentPitch += velocity
                                let detent = min(84, max(36, Int(currentPitch.rounded())))
                                if detent != selectedDetent {
                                    selectedDetent = detent
                                    onPitchChange(Double(detent))
                                }
                                velocity *= 0.88
                                try? await Task.sleep(for: .milliseconds(16))
                            }
                            if !Task.isCancelled { onPitchChange(Double(selectedDetent)) }
                        }
                    }
            )
        }
        .accessibilityLabel("Pitch scale moving beneath a fixed center marker")
        .sensoryFeedback(.selection, trigger: selectedDetent)
        .onChange(of: isInteractive) { _, interactive in
            if !interactive {
                momentumTask?.cancel()
                momentumTask = nil
                dragStartPitch = nil
            }
        }
        .onDisappear {
            momentumTask?.cancel()
            momentumTask = nil
        }
    }
}


func practiceTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}

private func noteName(_ midi: Int) -> String {
    PitchNote.name(midi)
}

