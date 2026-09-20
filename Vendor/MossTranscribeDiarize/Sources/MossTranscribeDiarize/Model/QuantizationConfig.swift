import Foundation

/// Quantization block read from converted MLX `config.json`.
public struct QuantizationConfig: Codable, Sendable, Equatable {
    public var bits: Int
    public var groupSize: Int
    public var mode: String
    public var scope: String?
    public var excludedPrefixes: [String]

    enum CodingKeys: String, CodingKey {
        case bits
        case groupSize = "group_size"
        case mode
        case scope
        case excludedPrefixes = "excluded_prefixes"
    }

    public init(
        bits: Int,
        groupSize: Int = 64,
        mode: String = "affine",
        scope: String? = nil,
        excludedPrefixes: [String] = [
            "model.whisper_encoder",
            "model.vq_adaptor",
        ]
    ) {
        self.bits = bits
        self.groupSize = groupSize
        self.mode = mode
        self.scope = scope
        self.excludedPrefixes = excludedPrefixes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bits = try container.decode(Int.self, forKey: .bits)
        groupSize = try container.decodeIfPresent(Int.self, forKey: .groupSize) ?? 64
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "affine"
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        excludedPrefixes = try container.decodeIfPresent([String].self, forKey: .excludedPrefixes)
            ?? ["model.whisper_encoder", "model.vq_adaptor"]
    }

    /// Whether a module path should stay full precision (audio encoder / adaptor).
    public func shouldExclude(path: String) -> Bool {
        excludedPrefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + ".")
        }
    }
}

/// Top-level fields needed from converted MLX config without re-decoding the full model tree.
struct ModelConfigFile: Decodable {
    var quantization: QuantizationConfig?
    var quantizationConfig: QuantizationConfig?

    enum CodingKeys: String, CodingKey {
        case quantization
        case quantizationConfig = "quantization_config"
    }

    var resolvedQuantization: QuantizationConfig? {
        quantization ?? quantizationConfig
    }
}
