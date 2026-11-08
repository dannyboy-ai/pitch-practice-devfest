// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscriptionLab",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TranscriptionEngines", targets: ["TranscriptionEngines"]),
        .executable(name: "transcription-bench", targets: ["TranscriptionBench"])
    ],
    dependencies: [
        .package(path: "../../LocalSpeech"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
    ],
    targets: [
        .target(name: "TranscriptionEngines", dependencies: [
            .product(name: "LocalSpeech", package: "LocalSpeech"),
            .product(name: "FluidAudio", package: "FluidAudio")
        ], path: ".", exclude: ["App", "CLI", "TranscriptionLab.xcodeproj", "download_models.py"],
        sources: ["LabTypes.swift", "BenchmarkRunner.swift", "AppleSpeechEngine.swift", "WhisperEngine.swift", "ParakeetEngine.swift"]),
        .executableTarget(name: "TranscriptionBench", dependencies: ["TranscriptionEngines"], path: "CLI")
    ],
    swiftLanguageModes: [.v5]
)
