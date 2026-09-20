import Foundation

public enum MossError: Error, LocalizedError, Sendable {
    case invalidModelPath(String)
    case missingWeights(String)
    case missingConfig(String)
    case loadFailed(String)
    case generationFailed(String)
    case invalidAudio(String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .invalidModelPath(let message):
            return "Invalid model path: \(message)"
        case .missingWeights(let message):
            return "Missing model weights: \(message)"
        case .missingConfig(let message):
            return "Missing model config: \(message)"
        case .loadFailed(let message):
            return "Failed to load model: \(message)"
        case .generationFailed(let message):
            return "Generation failed: \(message)"
        case .invalidAudio(let message):
            return "Invalid audio: \(message)"
        case .notLoaded:
            return "Model is not loaded. Call load() first."
        }
    }
}
