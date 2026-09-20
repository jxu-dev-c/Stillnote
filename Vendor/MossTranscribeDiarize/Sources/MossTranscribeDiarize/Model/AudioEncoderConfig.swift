import Foundation

/// Whisper-style audio encoder hyperparameters for MOSS-Transcribe-Diarize.
public struct AudioEncoderConfig: Codable, Sendable, Equatable {
    public var modelType: String
    public var numMelBins: Int
    public var dModel: Int
    public var encoderLayers: Int
    public var encoderAttentionHeads: Int
    public var encoderFfnDim: Int
    public var maxSourcePositions: Int
    public var scaleEmbedding: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case numMelBins = "num_mel_bins"
        case dModel = "d_model"
        case encoderLayers = "encoder_layers"
        case encoderAttentionHeads = "encoder_attention_heads"
        case encoderFfnDim = "encoder_ffn_dim"
        case maxSourcePositions = "max_source_positions"
        case scaleEmbedding = "scale_embedding"
    }

    public init(
        modelType: String = "whisper",
        numMelBins: Int = 80,
        dModel: Int = 1024,
        encoderLayers: Int = 24,
        encoderAttentionHeads: Int = 16,
        encoderFfnDim: Int = 4096,
        maxSourcePositions: Int = 1500,
        scaleEmbedding: Bool = false
    ) {
        self.modelType = modelType
        self.numMelBins = numMelBins
        self.dModel = dModel
        self.encoderLayers = encoderLayers
        self.encoderAttentionHeads = encoderAttentionHeads
        self.encoderFfnDim = encoderFfnDim
        self.maxSourcePositions = maxSourcePositions
        self.scaleEmbedding = scaleEmbedding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "whisper"
        numMelBins = try container.decodeIfPresent(Int.self, forKey: .numMelBins) ?? 80
        dModel = try container.decodeIfPresent(Int.self, forKey: .dModel) ?? 1024
        encoderLayers = try container.decodeIfPresent(Int.self, forKey: .encoderLayers) ?? 24
        encoderAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .encoderAttentionHeads) ?? 16
        encoderFfnDim = try container.decodeIfPresent(Int.self, forKey: .encoderFfnDim) ?? 4096
        maxSourcePositions = try container.decodeIfPresent(Int.self, forKey: .maxSourcePositions) ?? 1500
        scaleEmbedding = try container.decodeIfPresent(Bool.self, forKey: .scaleEmbedding) ?? false
    }
}

/// Fixed Whisper feature-extraction constants (16 kHz, 30 s windows).
public enum MossWhisperAudioConfig {
    public static let sampleRate = 16_000
    public static let nFft = 400
    public static let hopLength = 160
    public static let chunkLengthSeconds = 30
    public static var chunkLengthSamples: Int { sampleRate * chunkLengthSeconds }
}
