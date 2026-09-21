// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Stillnote",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Vendor/MossTranscribeDiarize"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
    ],
    targets: [
        .executableTarget(
            name: "StillnoteSpeechWorker",
            dependencies: ["StillnoteCore", .product(name: "MossTranscribeDiarize", package: "MossTranscribeDiarize"),
                           .product(name: "MLX", package: "mlx-swift")]
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
        .testTarget(
            name: "StillnoteCoreTests",
            dependencies: ["StillnoteCore", .product(name: "MossTranscribeDiarize", package: "MossTranscribeDiarize"),
                           .product(name: "MLX", package: "mlx-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
