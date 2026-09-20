import Foundation

/// Top-level MOSS-Transcribe-Diarize configuration (matches converted MLX `config.json`).
public struct ModelConfig: Codable, Sendable, Equatable {
    public var modelType: String
    public var textConfig: TextConfig
    public var audioConfig: AudioEncoderConfig
    public var audioTokenId: Int
    public var audioMergeSize: Int
    public var adaptorInputDim: Int
    public var tieWordEmbeddings: Bool
    public var sampleRate: Int
    public var quantization: QuantizationConfig?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case textConfig = "text_config"
        case audioConfig = "audio_config"
        case audioTokenId = "audio_token_id"
        case audioMergeSize = "audio_merge_size"
        case adaptorInputDim = "adaptor_input_dim"
        case tieWordEmbeddings = "tie_word_embeddings"
        case sampleRate = "sample_rate"
        case quantization
        case quantizationConfig = "quantization_config"
    }

    public init(
        modelType: String = "moss_transcribe_diarize",
        textConfig: TextConfig = TextConfig(),
        audioConfig: AudioEncoderConfig = AudioEncoderConfig(),
        audioTokenId: Int = 151_671,
        audioMergeSize: Int = 4,
        adaptorInputDim: Int? = nil,
        tieWordEmbeddings: Bool = true,
        sampleRate: Int = 16_000,
        quantization: QuantizationConfig? = nil
    ) {
        self.modelType = modelType
        var resolvedText = textConfig
        resolvedText.tieWordEmbeddings = tieWordEmbeddings
        self.textConfig = resolvedText
        self.audioConfig = audioConfig
        self.audioTokenId = audioTokenId
        self.audioMergeSize = audioMergeSize
        self.adaptorInputDim = adaptorInputDim ?? audioConfig.dModel * audioMergeSize
        self.tieWordEmbeddings = tieWordEmbeddings
        self.sampleRate = sampleRate
        self.quantization = quantization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "moss_transcribe_diarize"
        var decodedText = try container.decodeIfPresent(TextConfig.self, forKey: .textConfig) ?? TextConfig()
        audioConfig = try container.decodeIfPresent(AudioEncoderConfig.self, forKey: .audioConfig)
            ?? AudioEncoderConfig()
        audioTokenId = try container.decodeIfPresent(Int.self, forKey: .audioTokenId) ?? 151_671
        audioMergeSize = try container.decodeIfPresent(Int.self, forKey: .audioMergeSize) ?? 4
        tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        decodedText.tieWordEmbeddings = tieWordEmbeddings
        textConfig = decodedText
        adaptorInputDim = try container.decodeIfPresent(Int.self, forKey: .adaptorInputDim)
            ?? audioConfig.dModel * audioMergeSize
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 16_000
        quantization = try container.decodeIfPresent(QuantizationConfig.self, forKey: .quantization)
            ?? container.decodeIfPresent(QuantizationConfig.self, forKey: .quantizationConfig)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(textConfig, forKey: .textConfig)
        try container.encode(audioConfig, forKey: .audioConfig)
        try container.encode(audioTokenId, forKey: .audioTokenId)
        try container.encode(audioMergeSize, forKey: .audioMergeSize)
        try container.encode(adaptorInputDim, forKey: .adaptorInputDim)
        try container.encode(tieWordEmbeddings, forKey: .tieWordEmbeddings)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encodeIfPresent(quantization, forKey: .quantization)
    }
}
