import Darwin
import Foundation

public enum BenchmarkRunner {
    // Report files are checkpointed before loading and after each take, so a
    // device memory termination leaves evidence rather than a fake empty result.
    public static func run(
        model: LabModel, recordings: [LabRecording], modelsDirectory: URL,
        reportsDirectory: URL, repeatFirst: Bool = true,
        progress: @escaping @Sendable (String) -> Void = { print($0) }
    ) async throws -> LabReport {
        var report = LabReport(
            id: UUID(), model: model, device: hardwareName(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startedAt: .now, status: "preparing", measurements: []
        )
        report.modelAssetBytes = model.assetDirectory.flatMap {
            directoryBytes(modelsDirectory.appendingPathComponent($0))
        }
        try report.save(in: reportsDirectory)
        let memory = MemorySampler()
        let sampling = Task {
            while !Task.isCancelled {
                await memory.sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampling.cancel() }
        do {
            guard !recordings.isEmpty else {
                throw NSError(domain: "TranscriptionLab", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No CAF recordings in the lab's Recordings directory."
                ])
            }
            let engine = model.makeEngine()
            progress("Preparing \(model.title)")
            let loadStart = ProcessInfo.processInfo.systemUptime
            do {
                report.preparationNotes = try await engine.prepare(modelsDirectory: modelsDirectory)
            } catch {
                report.preparationSeconds = ProcessInfo.processInfo.systemUptime - loadStart
                throw error
            }
            report.preparationSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            var jobs = recordings.map { ($0, 1) }
            if repeatFirst, let first = recordings.first { jobs.append((first, 2)) }
            for (index, job) in jobs.enumerated() {
                try Task.checkCancellation()
                let (recording, pass) = job
                report.status = "transcribing \(recording.filename), pass \(pass)"
                try report.save(in: reportsDirectory)
                progress("\(index + 1)/\(jobs.count) · \(recording.filename) · pass \(pass)")
                let thermal = String(describing: ProcessInfo.processInfo.thermalState)
                let started = ProcessInfo.processInfo.systemUptime
                var transcript: LabTranscript?
                var failure: String?
                do {
                    transcript = try await engine.transcribe(file: recording.url)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    failure = error.localizedDescription
                }
                try Task.checkCancellation()
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                report.measurements.append(LabMeasurement(
                    filename: recording.filename, recordingTitle: recording.title,
                    audioSeconds: recording.duration, pass: pass, processingSeconds: elapsed,
                    thermalState: thermal, transcript: transcript, error: failure
                ))
                await memory.sample()
                report.peakAppMemoryMB = await memory.peakMB
                try report.save(in: reportsDirectory)
                progress(String(format: "Finished %.1fs audio in %.2fs (RTF %.3f)%@",
                                recording.duration, elapsed, elapsed / recording.duration,
                                failure.map { " · ERROR: \($0)" } ?? ""))
            }
            report.status = report.measurements.contains { $0.error != nil } ? "completed with errors" : "completed"
        } catch {
            report.status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            report.error = error.localizedDescription
        }
        await memory.sample()
        report.peakAppMemoryMB = await memory.peakMB
        try report.save(in: reportsDirectory)
        progress("LAB_FINISHED \(model.rawValue) \(report.status) \(report.id.uuidString)")
        return report
    }

    private static func hardwareName() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    private static func directoryBytes(_ url: URL) -> Int64? {
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return nil }
        var bytes: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return nil }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
}

private actor MemorySampler {
    private(set) var peakMB: Double?

    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let mb = Double(info.phys_footprint) / 1_000_000
            peakMB = max(peakMB ?? mb, mb)
        }
    }
}
