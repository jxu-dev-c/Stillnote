// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Stillnote",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        // Vendor/NemotronSpeech's AudioCommon needs `Hub`; already in the resolved graph.
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMajor(from: "1.1.6")),
        // Silero VAD, used for the silence trim and non-speech suppression. It is the one
        // remaining MLX model, which is why the worker still ships mlx.metallib.
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"
        ),
    ],
    targets: [
        .executableTarget(
            name: "StillnoteSpeechWorker",
            dependencies: ["StillnoteCore", "NemotronStreamingASR", "SpeechVAD",
                           .product(name: "MLX", package: "mlx-swift"),
                           .product(name: "MLXAudioVAD", package: "mlx-audio-swift")]
        ),
        .target(
            name: "StillnoteCore",
            resources: [.copy("Resources/speech_models.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Stillnote",
            dependencies: ["StillnoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // SwiftUI's VideoPlayer needs AVPlayerView at runtime, even when the linker
            // sees only the _AVKit_SwiftUI overlay's symbols.
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        // Ships inside the app bundle as `stillnote`, beside StillnoteSpeechWorker.
        .executableTarget(
            name: "StillnoteCLI",
            dependencies: ["StillnoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Vendored from soniqo/speech-swift; see Vendor/NemotronSpeech/UPSTREAM.md for the
        // pinned revision and patches. Upstream is swift-tools-version 5.10, so these keep
        // Swift 5 language mode rather than being patched for strict concurrency.
        .target(
            name: "AudioCommon",
            dependencies: [.product(name: "Hub", package: "swift-transformers")],
            path: "Vendor/NemotronSpeech/Sources/AudioCommon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MLXCommon",
            dependencies: [
                "AudioCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ],
            path: "Vendor/NemotronSpeech/Sources/MLXCommon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Nemotron 3 Diarization CoreML/MLX backends, plus the Sortformer mel extraction
        // and streaming-state machinery Nemotron 3 reuses.
        .target(
            name: "SpeechVAD",
            dependencies: [
                "AudioCommon", "MLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Vendor/NemotronSpeech/Sources/SpeechVAD",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "NemotronStreamingASR",
            dependencies: [
                "AudioCommon", "MLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ],
            path: "Vendor/NemotronSpeech/Sources/NemotronStreamingASR",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StillnoteCoreTests",
            dependencies: ["StillnoteCore", .product(name: "MLX", package: "mlx-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
