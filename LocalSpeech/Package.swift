// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalSpeech",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LocalSpeech", targets: ["LocalSpeech"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "LocalSpeech", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift")
        ])
    ],
    swiftLanguageModes: [.v5]
)
