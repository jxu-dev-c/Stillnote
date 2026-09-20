import Foundation

/// Structured output from a transcription run.
public struct TranscribeResult: Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var promptTokens: Int
    public var generationTokens: Int
    public var totalTokens: Int
    public var promptTokensPerSecond: Double
    public var generationTokensPerSecond: Double
    public var totalTime: TimeInterval
    public var peakMemoryGB: Double

    public init(
        text: String,
        segments: [TranscriptSegment] = [],
        promptTokens: Int = 0,
        generationTokens: Int = 0,
        totalTokens: Int = 0,
        promptTokensPerSecond: Double = 0,
        generationTokensPerSecond: Double = 0,
        totalTime: TimeInterval = 0,
        peakMemoryGB: Double = 0
    ) {
        self.text = text
        self.segments = segments
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.totalTokens = totalTokens
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.totalTime = totalTime
        self.peakMemoryGB = peakMemoryGB
    }
}

/// Streaming token / completion events.
public enum TranscribeEvent: Sendable {
    case token(String)
    case finished(TranscribeResult)
}

/// Parameters controlling generation (aligned with Python MLX CLI).
public struct GenerateParameters: Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var minP: Float
    public var repetitionPenalty: Float
    public var repetitionContextSize: Int
    public var prefillStepSize: Int
    public var prompt: String?
    public var hotwords: [String]

    public init(
        maxTokens: Int = 2048,
        temperature: Float = 0.0,
        topP: Float = 1.0,
        topK: Int = 0,
        minP: Float = 0.0,
        repetitionPenalty: Float = 1.0,
        repetitionContextSize: Int = 100,
        prefillStepSize: Int = 2048,
        prompt: String? = nil,
        hotwords: [String] = []
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.prefillStepSize = prefillStepSize
        self.prompt = prompt
        self.hotwords = hotwords
    }

    /// Effective prompt after hotword injection.
    public var resolvedPrompt: String {
        PromptBuilder.make(base: prompt ?? MossDefaults.prompt, hotwords: hotwords)
    }
}
