// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Stillnote",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Vendor/MossTranscribeDiarize"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        // Same revision Vendor/MossTranscribeDiarize already pins; referenced directly here
        // so the worker can link MLXAudioVAD (Silero VAD) for silence detection.
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"
        ),
    ],
    targets: [
        .executableTarget(
            name: "StillnoteSpeechWorker",
            dependencies: ["StillnoteCore", .product(name: "MossTranscribeDiarize", package: "MossTranscribeDiarize"),
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
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Ships inside the app bundle as `stillnote`, beside StillnoteSpeechWorker.
        .executableTarget(
            name: "StillnoteCLI",
            dependencies: ["StillnoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StillnoteCoreTests",
            dependencies: ["StillnoteCore", .product(name: "MossTranscribeDiarize", package: "MossTranscribeDiarize"),
                           .product(name: "MLX", package: "mlx-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
