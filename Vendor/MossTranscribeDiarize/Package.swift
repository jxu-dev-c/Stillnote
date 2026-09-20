// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MossTranscribeDiarize",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "MossTranscribeDiarize",
            targets: ["MossTranscribeDiarize"]
        ),
        .executable(
            name: "moss-transcribe",
            targets: ["MossTranscribeCLI"]
        ),
        .executable(
            name: "MossTranscribeDemo",
            targets: ["MossTranscribeDemo"]
        ),
    ],
    dependencies: [
        // Architecture mirrors Blaizzy/mlx-audio-swift (MLX + HF + transformers).
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMajor(from: "1.1.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
        // Shared audio helpers (mel filters, loadAudioArray, HF model download).
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"),
    ],
    targets: [
        .target(
            name: "MossTranscribeDiarize",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ],
            path: "Sources/MossTranscribeDiarize"
        ),
        .executableTarget(
            name: "MossTranscribeCLI",
            dependencies: [
                "MossTranscribeDiarize",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ],
            path: "Sources/MossTranscribeCLI"
        ),
        // Minimal macOS SwiftUI demo (WindowGroup + TranscribeView).
        .executableTarget(
            name: "MossTranscribeDemo",
            dependencies: [
                "MossTranscribeDiarize",
            ],
            path: "Examples/MossTranscribeDemo",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "MossTranscribeDiarizeTests",
            dependencies: ["MossTranscribeDiarize"],
            path: "Tests/MossTranscribeDiarizeTests"
        ),
    ]
)
