import Foundation

public struct SpeechModelFile: Codable, Sendable {
    public let size: Int
    public let sha256: String?
}

public struct SpeechModelSpec: Codable, Sendable {
    public let repo: String
    public let revision: String
    public let name: String
    public let tier: String
    public let files: [String: SpeechModelFile]

    public var downloadBytes: Int { files.values.reduce(0) { $0 + $1.size } }
    public var downloadMegabytes: Int { Int((Double(downloadBytes) / 1_000_000).rounded()) }
    public var infoURL: URL? { URL(string: "https://huggingface.co/\(repo)") }
}

/// The pinned speech model manifest. MOSS 0.9B is the only supported engine.
public enum SpeechCatalog {
    public static let defaultModel = "moss-0.9b"

    public static let models: [String: SpeechModelSpec] = {
        // The app bundle carries the manifest directly in Resources. Creating the
        // SwiftPM resource bundle is avoided here because a nested bundle inside a
        // hand-assembled .app hangs CFBundle when LaunchServices starts the app; it
        // is only consulted when running outside an app bundle, as tests do.
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(manifestName))
        }
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent(manifestName)
        )
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let decoded = decode(url) { return decoded }
        }
        if let url = Bundle.module.url(forResource: manifestName, withExtension: nil),
           let decoded = decode(url) {
            return decoded
        }
        assertionFailure("\(manifestName) is missing from the bundle")
        return [:]
    }()

    static let manifestName = "speech_models.json"

    private static func decode(_ url: URL) -> [String: SpeechModelSpec]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: SpeechModelSpec].self, from: data)
    }

    public static func spec(_ model: String) throws -> SpeechModelSpec {
        guard let spec = models[model] else {
            throw SpeechError.message(
                "Unsupported transcription model. Choose one of: \(models.keys.sorted().joined(separator: ", "))."
            )
        }
        return spec
    }

    public static func directory(modelDirectory: URL, model: String) -> URL {
        modelDirectory.appendingPathComponent("speech", isDirectory: true)
            .appendingPathComponent(model + "-mlx-8bit", isDirectory: true)
    }
}

public enum SpeechError: LocalizedError {
    case message(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .message(let detail): return detail
        case .cancelled: return "Transcription stopped."
        }
    }
}
