import Foundation

/// Resolves the on-disk layout and moves a pre-existing checkout's data on first launch.
public struct Paths: Sendable {
    public let dataDirectory: URL
    public let modelDirectory: URL

    public var audioDirectory: URL { dataDirectory.appendingPathComponent("audio", isDirectory: true) }
    public var videoDirectory: URL { dataDirectory.appendingPathComponent("video", isDirectory: true) }
    public var recordingsDirectory: URL { dataDirectory.appendingPathComponent("recordings", isDirectory: true) }
    public var databaseURL: URL { dataDirectory.appendingPathComponent("stillnote.sqlite3") }

    public func audioURL(_ meetingID: String) -> URL { audioDirectory.appendingPathComponent(meetingID) }
    public func videoURL(_ meetingID: String) -> URL { videoDirectory.appendingPathComponent(meetingID) }

    public init(dataDirectory: URL, modelDirectory: URL) {
        self.dataDirectory = dataDirectory
        self.modelDirectory = modelDirectory
    }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Paths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Stillnote", isDirectory: true)
        let data = environment["STILLNOTE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("data", isDirectory: true)
        let models = environment["STILLNOTE_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("models", isDirectory: true)
        let paths = Paths(dataDirectory: data, modelDirectory: models)
        try paths.adoptCheckoutContentsIfNeeded()
        try paths.createDirectories()
        return paths
    }

    public func createDirectories() throws {
        let manager = FileManager.default
        for directory in [dataDirectory, audioDirectory, videoDirectory, recordingsDirectory, modelDirectory] {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// One-time adoption of a development checkout's data/ and models/ directories.
    /// Only runs when this app has no database yet, so it can never overwrite newer data.
    func adoptCheckoutContentsIfNeeded() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: databaseURL.path), let checkout = Paths.enclosingCheckout() else { return }
        let sourceData = checkout.appendingPathComponent("data", isDirectory: true)
        if manager.fileExists(atPath: sourceData.appendingPathComponent("stillnote.sqlite3").path),
           !manager.fileExists(atPath: dataDirectory.path) {
            try manager.createDirectory(
                at: dataDirectory.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try manager.moveItem(at: sourceData, to: dataDirectory)
        }
        let sourceModels = checkout.appendingPathComponent("models", isDirectory: true)
        if manager.fileExists(atPath: sourceModels.appendingPathComponent("speech").path),
           !manager.fileExists(atPath: modelDirectory.path) {
            try manager.moveItem(at: sourceModels, to: modelDirectory)
        }
    }

    /// Finds this project's checkout, so a development build can use the `.venv-moss`
    /// runtime and adopt existing data. Looks upward from the running binary — which
    /// covers both `build/Stillnote.app/Contents/MacOS/Stillnote` and a plain
    /// `swift run` binary — and from the working directory, which is the package root
    /// under `swift test`, where the test runner itself lives in the toolchain.
    public static func enclosingCheckout() -> URL? {
        var starts: [URL] = []
        if let executable = Bundle.main.executableURL {
            starts.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let first = CommandLine.arguments.first {
            starts.append(URL(fileURLWithPath: first).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

        for start in starts {
            var directory = start
            for _ in 0..<10 {
                if FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("Package.swift").path
                ) {
                    return directory
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }
}
