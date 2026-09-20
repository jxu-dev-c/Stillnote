import Foundation

/// Qwen3 text decoder hyperparameters used by MOSS-Transcribe-Diarize.
public struct TextConfig: Codable, Sendable, Equatable {
    public var modelType: String
    public var vocabSize: Int
    public var hiddenSize: Int
    public var intermediateSize: Int
    public var numHiddenLayers: Int
    public var numAttentionHeads: Int
    public var numKeyValueHeads: Int
    public var headDim: Int
    public var hiddenAct: String
    public var maxPositionEmbeddings: Int
    public var rmsNormEps: Float
    public var useCache: Bool
    public var tieWordEmbeddings: Bool
    public var ropeTheta: Float
    public var attentionBias: Bool
    public var attentionDropout: Float

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case hiddenAct = "hidden_act"
        case maxPositionEmbeddings = "max_position_embeddings"
        case rmsNormEps = "rms_norm_eps"
        case useCache = "use_cache"
        case tieWordEmbeddings = "tie_word_embeddings"
        case ropeTheta = "rope_theta"
        case attentionBias = "attention_bias"
        case attentionDropout = "attention_dropout"
    }

    public init(
        modelType: String = "qwen3",
        vocabSize: Int = 151_936,
        hiddenSize: Int = 1024,
        intermediateSize: Int = 3072,
        numHiddenLayers: Int = 28,
        numAttentionHeads: Int = 16,
        numKeyValueHeads: Int = 8,
        headDim: Int = 128,
        hiddenAct: String = "silu",
        maxPositionEmbeddings: Int = 131_072,
        rmsNormEps: Float = 1e-6,
        useCache: Bool = true,
        tieWordEmbeddings: Bool = true,
        ropeTheta: Float = 1_000_000.0,
        attentionBias: Bool = false,
        attentionDropout: Float = 0.0
    ) {
        self.modelType = modelType
        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
        self.hiddenAct = hiddenAct
        self.maxPositionEmbeddings = maxPositionEmbeddings
        self.rmsNormEps = rmsNormEps
        self.useCache = useCache
        self.tieWordEmbeddings = tieWordEmbeddings
        self.ropeTheta = ropeTheta
        self.attentionBias = attentionBias
        self.attentionDropout = attentionDropout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "qwen3"
        vocabSize = try container.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 151_936
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1024
        intermediateSize = try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 3072
        numHiddenLayers = try container.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? 28
        numAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 16
        numKeyValueHeads = try container.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? 8
        headDim = try container.decodeIfPresent(Int.self, forKey: .headDim) ?? 128
        hiddenAct = try container.decodeIfPresent(String.self, forKey: .hiddenAct) ?? "silu"
        maxPositionEmbeddings = try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131_072
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        useCache = try container.decodeIfPresent(Bool.self, forKey: .useCache) ?? true
        tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 1_000_000.0
        attentionBias = try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        attentionDropout = try container.decodeIfPresent(Float.self, forKey: .attentionDropout) ?? 0.0
    }
}
