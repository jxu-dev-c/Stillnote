// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stillnote",
    platforms: [.macOS(.v15)],
    targets: [
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
            dependencies: ["StillnoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
