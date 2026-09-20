import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXNN
import HuggingFace
import Tokenizers

/// Loads converted MLX MOSS-Transcribe-Diarize checkpoints (FP / 8-bit / 4-bit).
public enum ModelLoader {
    /// Load from a local directory or Hugging Face repo id.
    public static func load(
        _ modelPath: String = MossDefaults.recommendedModel,
        cache: HubCache = .default
    ) async throws -> MossModel {
        let directory = try await resolveModelDirectory(modelPath, cache: cache)
        return try await load(directory: directory)
    }

    /// Load from an already-resolved local model directory.
    public static func load(directory modelDir: URL) async throws -> MossModel {
        let configURL = modelDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw MossError.missingConfig(configURL.path)
        }

        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ModelConfig.self, from: configData)
        let model = MossModel(config)

        let tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)
        model.attachTokenizer(tokenizer)
        try model.loadProcessorConfig(from: modelDir)
        try model.initializeDigitTokenIds()

        let weights = try loadWeights(from: modelDir)
        let sanitized = MossModel.sanitize(weights: weights)

        if let quantization = config.quantization
            ?? (sanitized.keys.contains(where: { $0.contains("scales") })
                ? QuantizationConfig(bits: 8, groupSize: 64) : nil) {
            applyQuantization(to: model, quantization: quantization, weights: sanitized)
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
        model.train(false)
        eval(model)
        return model
    }

    // MARK: - Internals

    private static func resolveModelDirectory(
        _ modelPath: String,
        cache: HubCache
    ) async throws -> URL {
        let expanded = (modelPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        guard let repoID = Repo.ID(rawValue: modelPath) else {
            throw MossError.invalidModelPath(modelPath)
        }

        let hfToken = ProcessInfo.processInfo.environment["HF_TOKEN"]
        return try await ModelUtils.resolveOrDownloadModel(
            repoID: repoID,
            requiredExtension: "safetensors",
            hfToken: hfToken,
            cache: cache
        )
    }

    private static func loadWeights(from modelDir: URL) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: nil
        )
        let safetensors = files
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !safetensors.isEmpty else {
            throw MossError.missingWeights(modelDir.path)
        }

        var weights: [String: MLXArray] = [:]
        for file in safetensors {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }
        return weights
    }

    /// Quantize text-backbone modules that have matching `*.scales` weights.
    /// Audio encoder + VQ adaptor stay full precision (matches Python predicate).
    private static func applyQuantization(
        to model: MossModel,
        quantization: QuantizationConfig,
        weights: [String: MLXArray]
    ) {
        quantize(
            model: model,
            groupSize: quantization.groupSize,
            bits: quantization.bits
        ) { path, _ in
            if quantization.shouldExclude(path: path) {
                return false
            }
            // Only quantize leaves that actually have scales in the checkpoint.
            return weights["\(path).scales"] != nil
        }
    }
}
