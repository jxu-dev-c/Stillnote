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
        guard let url = Bundle.module.url(forResource: "speech_models.json", withExtension: nil),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SpeechModelSpec].self, from: data)
        else {
            assertionFailure("speech_models.json is missing from the bundle")
            return [:]
        }
        return decoded
    }()

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
            .appendingPathComponent(model, isDirectory: true)
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
