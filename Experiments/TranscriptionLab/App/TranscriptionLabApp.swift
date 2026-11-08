import SwiftUI
import TranscriptionEngines

@main
struct TranscriptionLabApp: App {
    @StateObject private var store = LabStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        Text("A separate experiment using copies of your takes. Pitch Practice is unchanged.")
                        Text("Recognition runs locally. Apple may download language assets during setup; the other models are preloaded.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Benchmark") {
                        Picker("Model", selection: $store.model) {
                            ForEach(LabModel.allCases) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("labModelPicker")
                        .disabled(store.isRunning)
                        Picker("Audio", selection: $store.selectedFile) {
                            Text("All saved takes").tag("all")
                            ForEach(store.recordings) { recording in
                                Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.duration, specifier: "%.1f")s")
                                    .tag(recording.filename)
                            }
                        }
                        .disabled(store.isRunning)
                        if store.isRunning {
                            ProgressView(store.status)
                            Button("Cancel", role: .destructive) { store.cancel() }
                        } else {
                            Button("Run transcription benchmark") { store.run() }
                                .disabled(store.recordings.isEmpty)
                                .accessibilityIdentifier("labRunButton")
                            Text(store.status).font(.caption).textSelection(.enabled)
                        }
                        Text("Model setup and file processing are timed separately. The first selected take is repeated last to check warm performance.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Listen and compare") {
                        ForEach(store.recordings) { recording in
                            NavigationLink {
                                RecordingComparison(recording: recording, store: store)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(recording.title) · \(recording.duration, specifier: "%.1f") seconds")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("labRecording-\(recording.filename)")
                        }
                    }
                    Section("Run history") {
                        ForEach(store.reports) { report in
                            NavigationLink {
                                ReportDetails(report: report)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.model.title)
                                    Text("\(report.status) · \(report.measurements.count) file runs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let error = store.error {
                        Section("Error") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }
                .navigationTitle("Transcription Lab")
            }
            .task {
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--model"), args.indices.contains(index + 1),
                   let model = LabModel(rawValue: args[index + 1]) { store.model = model }
                if let index = args.firstIndex(of: "--file"), args.indices.contains(index + 1) { store.selectedFile = args[index + 1] }
                if args.contains("--run-benchmark") { store.run() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.cancel(); store.stopAudio() }
            }
        }
    }
}

private struct RecordingComparison: View {
    let recording: LabRecording
    @ObservedObject var store: LabStore

    var body: some View {
        List {
            Section("Original audio") {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Button(store.playingFile == recording.filename && store.isPlaying ? "Pause original" : "Play original") {
                    store.play(recording)
                }
                .disabled(store.isRunning)
                .accessibilityIdentifier("labPlayOriginal")
                if store.playingFile == recording.filename {
                    TimelineView(.animation(minimumInterval: 0.25, paused: !store.isPlaying)) { _ in
                        Slider(value: Binding(get: { store.position }, set: { store.seek($0) }), in: 0...max(recording.duration, 0.001))
                            .accessibilityLabel("Original audio position")
                        Text("\(store.position, specifier: "%.1f") / \(recording.duration, specifier: "%.1f") seconds")
                            .font(.caption.monospacedDigit())
                    }
                }
                Text("These are raw model guesses, not verified lyrics. Listen for missed/repeated words and text invented over vowels or silence.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(LabModel.allCases) { model in
                Section(model.title) {
                    if let result = store.reports.first(where: {
                        $0.model == model && $0.measurements.contains { $0.filename == recording.filename && $0.pass == 1 }
                    })?.measurements.first(where: { $0.filename == recording.filename && $0.pass == 1 }) {
                        if let transcript = result.transcript {
                            Text(transcript.text.isEmpty ? "No words detected" : transcript.text)
                                .textSelection(.enabled)
                            Text("\(result.processingSeconds, specifier: "%.2f")s to process · RTF \(result.realTimeFactor, specifier: "%.3f")")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let language = transcript.language { Text("Language: \(language)").font(.caption) }
                        } else {
                            Text(result.error ?? "No result").foregroundStyle(.red)
                        }
                    } else {
                        Text("Not run on this take").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Compare transcripts")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { store.stopAudio() }
    }
}

private struct ReportDetails: View {
    let report: LabReport
    var body: some View {
        List {
            Section("Device and setup") {
                Text("\(report.device) · \(report.osVersion)")
                Text(report.status)
                if let value = report.preparationSeconds { Text("Setup: \(value, specifier: "%.2f") seconds") }
                if let value = report.modelAssetBytes { Text("Model assets: \(Double(value) / 1e6, specifier: "%.1f") MB") }
                if let value = report.peakAppMemoryMB { Text("Sampled peak app footprint: \(value, specifier: "%.0f") MB") }
                Text("App footprint is not total system memory. Apple's model runs in a separate system service.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let notes = report.preparationNotes { Text(notes).font(.footnote).textSelection(.enabled) }
                if let error = report.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            ForEach(report.measurements) { result in
                Section("\(result.recordingTitle) · \(result.audioSeconds, specifier: "%.1f")s · pass \(result.pass)") {
                    Text("\(result.processingSeconds, specifier: "%.2f")s processing · RTF \(result.realTimeFactor, specifier: "%.3f")")
                    Text("Thermal state: \(result.thermalState)").font(.caption)
                    Text(result.transcript?.text ?? result.error ?? "").textSelection(.enabled)
                    Text(result.filename).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(report.model.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
