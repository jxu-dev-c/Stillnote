import Foundation

/// Structured output from a transcription run.
public struct TranscribeResult: Sendable, Equatable {
    public var contextCacheBytes: Int
    public var pcmReadTime: TimeInterval
    public var encodingTime: TimeInterval
    public var prefillTime: TimeInterval
    public var decodingTime: TimeInterval
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
        peakMemoryGB: Double = 0, contextCacheBytes: Int = 0, pcmReadTime: TimeInterval = 0, encodingTime: TimeInterval = 0,
        prefillTime: TimeInterval = 0, decodingTime: TimeInterval = 0
    ) {
        self.contextCacheBytes = contextCacheBytes
        self.pcmReadTime = pcmReadTime
        self.encodingTime = encodingTime
        self.prefillTime = prefillTime
        self.decodingTime = decodingTime
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

/// Context storage precision. Four-bit mode protects the first/last two layers at eight bits.
public enum ContextCache: Sendable, Equatable {
    case original, eightBit, fourBit
    public var bits: Int? { switch self { case .original: nil; case .eightBit: 8; case .fourBit: 4 } }
}

/// Parameters controlling generation. Memory budgets are bytes and apply per generation.
public struct GenerateParameters: Sendable, Equatable {
    public var contextCache: ContextCache
    public var memoryBudget: Int?
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
        maxTokens: Int = 2048, contextCache: ContextCache = .original, memoryBudget: Int? = nil,
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
        self.contextCache = contextCache
        self.memoryBudget = memoryBudget
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
