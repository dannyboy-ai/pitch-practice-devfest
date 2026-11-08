import Foundation
import TranscriptionEngines

@main
struct BenchmarkMain {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 8, args.count.isMultiple(of: 2) else {
                throw CLIError.usage
            }
            var options = [String: String]()
            for index in stride(from: 0, to: args.count, by: 2) { options[args[index]] = args[index + 1] }
            guard let model = options["--model"].flatMap(LabModel.init(rawValue:)),
                  let models = options["--models"], let files = options["--recordings"], let reports = options["--reports"] else {
                throw CLIError.usage
            }
            var recordings = try LabRecording.load(from: URL(fileURLWithPath: files, isDirectory: true))
            if let filename = options["--file"] { recordings = recordings.filter { $0.filename == filename } }
            let report = try await BenchmarkRunner.run(
                model: model, recordings: recordings,
                modelsDirectory: URL(fileURLWithPath: models, isDirectory: true),
                reportsDirectory: URL(fileURLWithPath: reports, isDirectory: true)
            )
            for result in report.measurements {
                print("\n\(result.filename) [pass \(result.pass)]\n\(result.transcript?.text ?? result.error ?? "")")
            }
            if report.status != "completed" { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private enum CLIError: LocalizedError {
    case usage
    var errorDescription: String? {
        "Usage: transcription-bench --model apple|whisper-base|whisper-turbo|parakeet-ultra --models DIR --recordings DIR --reports DIR [--file NAME.caf]"
    }
}
