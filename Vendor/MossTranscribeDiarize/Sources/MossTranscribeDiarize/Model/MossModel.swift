import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXLMCommon
import MLXNN
import Tokenizers

private let audioPadToken = "<|audio_pad|>"
private let audioStartToken = "<|audio_start|>"
private let audioEndToken = "<|audio_end|>"
private let whisperEncoderStride = 2

// MARK: - VQ Adaptor

final class MossVQAdaptor: Module {
    @ModuleInfo(key: "layers") var layers: Sequential

    init(inputDim: Int, hiddenSize: Int, normEps: Float) {
        self._layers.wrappedValue = Sequential(layers: [
            Linear(inputDim, hiddenSize, bias: true),
            SiLU(),
            Linear(hiddenSize, hiddenSize, bias: true),
            LayerNorm(dimensions: hiddenSize, eps: normEps),
        ])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        layers(x)
    }
}

// MARK: - Backbone

final class MossBackbone: Module {
    let config: ModelConfig

    @ModuleInfo(key: "language_model") var languageModel: Qwen3TextModel
    @ModuleInfo(key: "whisper_encoder") var whisperEncoder: MossWhisperEncoder
    @ModuleInfo(key: "vq_adaptor") var vqAdaptor: MossVQAdaptor

    init(_ config: ModelConfig) {
        self.config = config
        self._languageModel.wrappedValue = Qwen3TextModel(config.textConfig)
        self._whisperEncoder.wrappedValue = MossWhisperEncoder(config: config.audioConfig)
        self._vqAdaptor.wrappedValue = MossVQAdaptor(
            inputDim: config.adaptorInputDim,
            hiddenSize: config.textConfig.hiddenSize,
            normEps: config.textConfig.rmsNormEps
        )
    }

    func timeMerge(_ features: MLXArray) -> MLXArray {
        let batchSize = features.dim(0)
        let seqLen = features.dim(1)
        let dim = features.dim(2)
        let mergeSize = config.audioMergeSize
        let trimLen = (seqLen / mergeSize) * mergeSize
        return features[0..., 0..<trimLen, 0...].reshaped(
            batchSize,
            trimLen / mergeSize,
            dim * mergeSize
        )
    }

    func getAudioFeatures(
        inputFeatures: MLXArray,
        audioFeatureLengths: MLXArray,
        audioChunkMapping: MLXArray? = nil
    ) throws -> [MLXArray] {
        let whisperFeatures = whisperEncoder(inputFeatures)
        let lengths = audioFeatureLengths.asArray(Int32.self).map(Int.init)
        let mapping = audioChunkMapping?.asArray(Int32.self).map(Int.init)
            ?? [Int](repeating: 0, count: inputFeatures.dim(0))

        guard lengths.count == inputFeatures.dim(0) else {
            throw MossError.invalidAudio("audio_feature_lengths must contain one length per chunk.")
        }
        guard mapping.count == inputFeatures.dim(0) else {
            throw MossError.invalidAudio("audio_chunk_mapping must contain one sample index per chunk.")
        }

        let audioCount = (mapping.max() ?? -1) + 1
        var perAudioChunks = [[MLXArray]](repeating: [], count: max(audioCount, 0))
        for chunkIndex in 0..<lengths.count {
            let sampleIndex = mapping[chunkIndex]
            let frameLen = lengths[chunkIndex] * config.audioMergeSize
            perAudioChunks[sampleIndex].append(
                whisperFeatures[chunkIndex..<(chunkIndex + 1), 0..<frameLen, 0...]
            )
        }

        return perAudioChunks.map { chunks in
            let features = MLX.concatenated(chunks, axis: 1)
            return vqAdaptor(timeMerge(features))
        }
    }

    func injectAudioFeatures(
        inputIds: MLXArray,
        inputsEmbeds: MLXArray,
        inputFeatures: MLXArray,
        audioFeatureLengths: MLXArray,
        audioChunkMapping: MLXArray?
    ) throws -> MLXArray {
        let audioFeatures = try getAudioFeatures(
            inputFeatures: inputFeatures,
            audioFeatureLengths: audioFeatureLengths,
            audioChunkMapping: audioChunkMapping
        )
        let audioEmbeds = MLX.concatenated(audioFeatures.map { $0.squeezed(axis: 0) }, axis: 0)
            .asType(inputsEmbeds.dtype)

        let flatMask = (inputIds .== MLXArray(Int32(config.audioTokenId))).reshaped(-1)
        let maskValues = flatMask.asType(.int32).asArray(Int32.self)
        let audioTokenCount = maskValues.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        guard audioTokenCount == audioEmbeds.dim(0) else {
            throw MossError.invalidAudio(
                "Audio features and audio tokens do not match: tokens \(audioTokenCount), features \(audioEmbeds.dim(0))."
            )
        }

        let batchSize = inputsEmbeds.dim(0)
        let hiddenDim = inputsEmbeds.dim(2)
        let flatEmbeds = inputsEmbeds.reshaped(-1, hiddenDim)

        var pieces: [MLXArray] = []
        var cursor = 0
        var audioIndex = 0
        for (position, value) in maskValues.enumerated() where value != 0 {
            if position > cursor {
                pieces.append(flatEmbeds[cursor..<position])
            }
            pieces.append(audioEmbeds[audioIndex..<(audioIndex + 1)])
            cursor = position + 1
            audioIndex += 1
        }
        if cursor < flatEmbeds.dim(0) {
            pieces.append(flatEmbeds[cursor..<flatEmbeds.dim(0)])
        }

        return MLX.concatenated(pieces, axis: 0).reshaped(batchSize, inputIds.dim(1), hiddenDim)
    }

    func callAsFunction(
        inputIds: MLXArray,
        inputsEmbeds: MLXArray? = nil,
        cache: [KVCache]? = nil,
        inputFeatures: MLXArray? = nil,
        audioFeatureLengths: MLXArray? = nil,
        audioChunkMapping: MLXArray? = nil
    ) throws -> MLXArray {
        var embeds = inputsEmbeds ?? languageModel.embedTokens(inputIds)
        if let inputFeatures,
           let audioFeatureLengths,
           cache == nil || cache?.first == nil || (cache?.first as? KVCacheSimple)?.offset == 0 {
            embeds = try injectAudioFeatures(
                inputIds: inputIds,
                inputsEmbeds: embeds,
                inputFeatures: inputFeatures,
                audioFeatureLengths: audioFeatureLengths,
                audioChunkMapping: audioChunkMapping
            )
        }
        return languageModel(inputsEmbeds: embeds, cache: cache)
    }
}

// MARK: - Model

/// End-to-end MOSS-Transcribe-Diarize model for Apple Silicon via MLX.
public final class MossModel: Module, @unchecked Sendable {
    public let config: ModelConfig
    public let sampleRate: Int

    @ModuleInfo(key: "model") var model: MossBackbone
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public private(set) var tokenizer: (any Tokenizers.Tokenizer)?
    public var audioTokensPerSecond: Float = 12.5
    public var timeMarkerEverySeconds: Int = 5
    public var enableTimeMarker = true

    private var generationWeightBytes = 0
    private var digitTokenIds: [Character: Int] = [:]

    public init(_ config: ModelConfig) {
        self.config = config
        self.sampleRate = config.sampleRate
        self._model.wrappedValue = MossBackbone(config)
        if config.textConfig.tieWordEmbeddings {
            self._lmHead.wrappedValue = nil
        } else {
            self._lmHead.wrappedValue = Linear(
                config.textConfig.hiddenSize,
                config.textConfig.vocabSize,
                bias: false
            )
        }
    }

    public func makeCache(context: ContextCache = .original) -> [KVCache] {
        (0..<config.textConfig.numHiddenLayers).map { index in
            if let bits = context.bits {
                // Protect boundary layers: uniform 4-bit KV can suppress all output.
                let protected = context == .fourBit && (index < 2 || index >= config.textConfig.numHiddenLayers - 2)
                return QuantizedKVCache(groupSize: 64, bits: protected ? 8 : bits)
            }
            return KVCacheSimple()
        }
    }

    public func callAsFunction(
        inputIds: MLXArray,
        inputEmbeddings: MLXArray? = nil,
        cache: [KVCache]? = nil
    ) throws -> MLXArray {
        let hiddenStates = try model(
            inputIds: inputIds,
            inputsEmbeds: inputEmbeddings,
            cache: cache
        )
        if let lmHead {
            return lmHead(hiddenStates)
        }
        return model.languageModel.embedTokens.asLinear(hiddenStates)
    }

    /// Transcribe an audio/video file path (extracts mono PCM at `sampleRate`).
    public func generate(
        fileURL: URL,
        parameters: GenerateParameters = GenerateParameters()
    ) throws -> TranscribeResult {
        let (_, audio) = try loadAudioArray(from: fileURL, sampleRate: sampleRate)
        return try generate(audio: audio, parameters: parameters)
    }

    /// Transcribe mono audio samples (`float32`, sample rate = `sampleRate`).
    public func generate(
        audio: MLXArray,
        parameters: GenerateParameters = GenerateParameters(),
        progress: @escaping @Sendable (GenerationProgress) -> Void = { _ in }
    ) throws -> TranscribeResult {
        let wav = try audioToMono(audio)
        return try generateSamples(count: wav.dim(0), parameters: parameters, progress: progress) { range in wav[range] }
    }

    /// Reads little-endian, mono 16 kHz float32 PCM in bounded encoder windows.
    public func generate(pcmURL: URL, parameters: GenerateParameters = .init(),
                         progress: @escaping @Sendable (GenerationProgress) -> Void = { _ in }) throws -> TranscribeResult {
        let source = try PCMSource(url: pcmURL)
        return try generateSamples(count: source.count, parameters: parameters, progress: progress) { try source.read($0) }
    }

    private func generateSamples(count: Int, parameters: GenerateParameters,
                                progress: @escaping @Sendable (GenerationProgress) -> Void,
                                read: (Range<Int>) throws -> MLXArray) throws -> TranscribeResult {
        defer { Stream().synchronize(); Memory.clearCache() }
        let started = Date()
        generationWeightBytes = parametersMemoryBytes()
        let prefillStart = Date()
        var pcmSeconds = 0.0
        var prepared: PreparedGenerationInputs? = try prepareGenerationInputs(count: count, read: { range in
            let start = Date()
            defer { pcmSeconds += Date().timeIntervalSince(start) }
            return try read(range)
        }, parameters: parameters, progress: progress)
        let prefillTime = Date().timeIntervalSince(prefillStart)

        let duration = prepared!.duration
        let promptCount = prepared!.promptTokenCount
        Memory.clearCache()
        let genStart = Date()
        let generated = try generateTokenIds(
            prepared: &prepared,
            parameters: parameters,
            progress: progress
        )
        Stream().synchronize()
        let tokens = generated.tokens
        let genTime = Date().timeIntervalSince(genStart) - generated.prefillTime

        let text = tokenizer?
            .decode(tokens: tokens, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let segments = parseTranscript(text)
        let totalTime = Date().timeIntervalSince(started)

        return TranscribeResult(
            text: text,
            segments: segments.isEmpty
                ? [TranscriptSegment(start: 0, end: duration, speaker: "S00", text: text)]
                : segments,
            promptTokens: promptCount,
            generationTokens: tokens.count,
            totalTokens: promptCount + tokens.count,
            promptTokensPerSecond: generated.prefillTime > 0 ? Double(promptCount) / generated.prefillTime : 0,
            generationTokensPerSecond: genTime > 0 ? Double(tokens.count) / genTime : 0,
            totalTime: totalTime,
            peakMemoryGB: Double(Memory.peakMemory) / 1e9, contextCacheBytes: generated.cacheBytes,
            pcmReadTime: pcmSeconds, encodingTime: prefillTime - pcmSeconds,
            prefillTime: generated.prefillTime, decodingTime: genTime
        )
    }

    /// Stream decoded token strings as they are generated.
    public func generateStream(
        audio: MLXArray,
        parameters: GenerateParameters = GenerateParameters()
    ) -> AsyncThrowingStream<TranscribeEvent, Error> {
        let modelBox = UncheckedSendable(self)
        let audioBox = UncheckedSendable(audio)
        let parametersBox = UncheckedSendable(parameters)
        return AsyncThrowingStream(TranscribeEvent.self) { continuation in
            let task = Task.detached {
                let model = modelBox.value
                let audio = audioBox.value
                let parameters = parametersBox.value
                do {
                    // Progress carries the complete decoded prefix. Wait for complete Unicode
                    // before emitting a delta; decoding individual BPE tokens corrupts text.
                    let state = StreamingText()
                    let result = try model.generate(audio: audio, parameters: parameters) { event in
                        if case .decoded(let text) = event, let delta = state.append(text) {
                            continuation.yield(.token(delta))
                        }
                    }
                    if let delta = state.append(result.text) { continuation.yield(.token(delta)) }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Loading helpers (internal)

extension MossModel {
    func attachTokenizer(_ tokenizer: any Tokenizers.Tokenizer) {
        self.tokenizer = tokenizer
    }

    func loadProcessorConfig(from modelDir: URL) throws {
        let url = modelDir.appendingPathComponent("processor_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let value = object["audio_tokens_per_second"] as? NSNumber {
            audioTokensPerSecond = value.floatValue
        }
        if let value = object["time_marker_every_seconds"] as? NSNumber {
            timeMarkerEverySeconds = value.intValue
        }
        if let value = object["enable_time_marker"] as? Bool {
            enableTimeMarker = value
        }
    }

    func initializeDigitTokenIds() throws {
        guard let tokenizer else {
            throw MossError.loadFailed("Tokenizer not loaded.")
        }
        var ids: [Character: Int] = [:]
        for digit in "0123456789" {
            let encoded = tokenizer.encode(text: String(digit), addSpecialTokens: false)
            guard encoded.count == 1, let token = encoded.first else {
                throw MossError.loadFailed("Digit \(digit) is not a single token: \(encoded).")
            }
            ids[digit] = token
        }
        digitTokenIds = ids
    }

    static func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let alreadyConverted = weights.keys.contains { $0.contains("scales") }
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, rawValue) in weights {
            if rawKey == "lm_head.weight" { continue }
            var key = rawKey
            var value = rawValue

            if key.hasPrefix("model.vq_adwaptor.") {
                key = key.replacingOccurrences(
                    of: "model.vq_adwaptor.",
                    with: "model.vq_adaptor.",
                    options: [.anchored]
                )
            }
            if key.hasPrefix("model.vq_adaptor.layers.")
                && !key.hasPrefix("model.vq_adaptor.layers.layers.") {
                key = key.replacingOccurrences(
                    of: "model.vq_adaptor.layers.",
                    with: "model.vq_adaptor.layers.layers.",
                    options: [.anchored]
                )
            }
            if key.hasPrefix("model.vq_adaptor.layers.layers.layers.") {
                key = key.replacingOccurrences(
                    of: "model.vq_adaptor.layers.layers.layers.",
                    with: "model.vq_adaptor.layers.layers.",
                    options: [.anchored]
                )
            }
            if !alreadyConverted,
               key.hasPrefix("model.whisper_encoder."),
               key.contains("conv"),
               key.hasSuffix(".weight"),
               value.ndim == 3 {
                value = value.transposed(0, 2, 1)
            }
            sanitized[key] = value
        }
        return sanitized
    }
}

// MARK: - Generation internals

extension MossModel {
    private struct PreparedGenerationInputs {
        let promptIds: MLXArray
        let inputEmbeddings: MLXArray
        let promptTokenCount: Int
        let duration: Double
    }

    func audioToMono(_ audio: MLXArray) throws -> MLXArray {
        guard audio.shape.reduce(1, *) > 0 else {
            throw MossError.invalidAudio("Audio must contain at least one sample.")
        }
        var mono = audio
        if mono.ndim > 1 {
            mono = mono.reshaped([-1])
        }
        return mono.asType(.float32)
    }

    func computeAudioTokenLength(numSamples: Int) -> Int {
        let hopLength = MossWhisperAudioConfig.hopLength
        let stride = hopLength * whisperEncoderStride * config.audioMergeSize
        return max(1, (numSamples - 1) / stride + 1)
    }

    func audioSpanIds(audioTokenCount: Int) throws -> [Int] {
        guard enableTimeMarker,
              audioTokenCount > 0,
              timeMarkerEverySeconds > 0
        else {
            return [Int](repeating: config.audioTokenId, count: max(audioTokenCount, 0))
        }

        let tokensPerMarker = Int(audioTokensPerSecond * Float(timeMarkerEverySeconds))
        guard tokensPerMarker > 0 else {
            return [Int](repeating: config.audioTokenId, count: audioTokenCount)
        }
        guard !digitTokenIds.isEmpty else {
            throw MossError.loadFailed("Digit token ids are not initialized.")
        }

        let duration = Float(audioTokenCount) / audioTokensPerSecond
        var output: [Int] = []
        var consumed = 0
        var seconds = timeMarkerEverySeconds
        while seconds <= Int(duration) {
            let position = (seconds / timeMarkerEverySeconds) * tokensPerMarker
            let segmentLength = position - consumed
            if segmentLength > 0 {
                output.append(contentsOf: [Int](repeating: config.audioTokenId, count: segmentLength))
                consumed += segmentLength
            }
            for digit in String(seconds) {
                if let token = digitTokenIds[digit] {
                    output.append(token)
                }
            }
            seconds += timeMarkerEverySeconds
        }
        let remainder = audioTokenCount - consumed
        if remainder > 0 {
            output.append(contentsOf: [Int](repeating: config.audioTokenId, count: remainder))
        }
        return output
    }

    func buildPrompt(audioTokenCount: Int, prompt: String?) throws -> MLXArray {
        guard let tokenizer else {
            throw MossError.loadFailed("Tokenizer not loaded.")
        }

        let resolvedPrompt: String = {
            if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return prompt
            }
            return MossDefaults.prompt
        }()

        let rendered: String
        if resolvedPrompt.contains(audioPadToken) {
            rendered = resolvedPrompt
        } else {
            rendered = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"
                + "<|im_start|>user\n"
                + "\(audioStartToken)\(audioPadToken)\(audioEndToken)\n"
                + "\(resolvedPrompt)<|im_end|>\n"
                + "<|im_start|>assistant\n"
        }

        let parts = rendered.components(separatedBy: audioPadToken)
        guard parts.count == 2 else {
            throw MossError.generationFailed("Expected exactly one \(audioPadToken) token in the prompt.")
        }

        let tokenIds = tokenizer.encode(text: parts[0], addSpecialTokens: false)
            + (try audioSpanIds(audioTokenCount: audioTokenCount))
            + tokenizer.encode(text: parts[1], addSpecialTokens: false)
        return MLXArray(tokenIds.map(Int32.init)).expandedDimensions(axis: 0)
    }

    private func prepareGenerationInputs(
        count: Int, read: (Range<Int>) throws -> MLXArray, parameters: GenerateParameters, progress: @Sendable (GenerationProgress) -> Void
    ) throws -> PreparedGenerationInputs {
        let window = MossWhisperAudioConfig.chunkLengthSamples
        let starts = Array(stride(from: 0, to: count, by: window))
        let lengths = starts.map { computeAudioTokenLength(numSamples: min(window, count - $0)) }
        let inputIds = try buildPrompt(audioTokenCount: lengths.reduce(0, +), prompt: parameters.resolvedPrompt)
        guard config.textConfig.maxPositionEmbeddings - inputIds.dim(1) - 1 >= 256 else {
            throw MossError.generationFailed("This recording exceeds the MOSS context limit. Import a shorter recording.")
        }
        try checkMemory(tokens: inputIds.dim(1), parameters: parameters)
        var encoded: [MLXArray] = []
        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            try checkMemory(tokens: inputIds.dim(1), parameters: parameters)
            let features = MossWhisperAudio.encoderFeatures(
                audio: try read(start..<min(start + window, count)), nMels: config.audioConfig.numMelBins
            ).asType(model.whisperEncoder.conv1.weight.dtype)
            let part = try model.getAudioFeatures(
                inputFeatures: features, audioFeatureLengths: MLXArray([Int32(lengths[index])])
            )[0]
            eval(part)
            encoded.append(part)
            progress(.encoding(index + 1, starts.count))
        }
        let embeds = model.languageModel.embedTokens(inputIds)
        let audioEmbeds = MLX.concatenated(encoded, axis: 1).squeezed(axis: 0).asType(embeds.dtype)
        let ids = inputIds.reshaped(-1).asArray(Int32.self)
        let positions = ids.indices.filter { ids[$0] == Int32(config.audioTokenId) }
        guard positions.count == audioEmbeds.dim(0) else {
            throw MossError.invalidAudio("Audio tokens and encoded features do not match.")
        }
        let flat = embeds.reshaped(-1, embeds.dim(2))
        flat[MLXArray(positions.map(Int32.init))] = audioEmbeds
        let inputsEmbeds = flat.reshaped(embeds.shape)
        eval(inputsEmbeds)
        return PreparedGenerationInputs(
            promptIds: inputIds, inputEmbeddings: inputsEmbeds,
            promptTokenCount: inputIds.dim(1), duration: Double(count) / Double(sampleRate)
        )
    }

    func checkMemory(tokens: Int, parameters: GenerateParameters) throws {
        guard let budget = parameters.memoryBudget else { return }
        let c = config.textConfig
        let baseBytes = parameters.contextCache.bits.map { Double($0) / 8 + 4.0 / 64 } ?? 2
        let bytesPerValue = baseBytes + (parameters.contextCache == .fourBit ? 0.5 * Double(min(4, c.numHiddenLayers)) / Double(c.numHiddenLayers) : 0)
        let cacheBytes = Double(((tokens + 255) / 256) * 256) * Double(2 * c.numHiddenLayers * c.numKeyValueHeads * c.headDim) * bytesPerValue
        let weights = generationWeightBytes
        let embeddings = Double(tokens * c.hiddenSize * 2 * 3)
        let scratch = max(Double(1024 * 1024 * 1024), parameters.contextCache.bits == nil ? 0 : Double(c.numAttentionHeads * parameters.prefillStepSize * tokens * 8))
        guard Double(weights) + cacheBytes * 1.08 + embeddings + scratch + Double(256 * 1024 * 1024) <= Double(budget),
              Memory.activeMemory < budget else {
            throw MossError.generationFailed(parameters.contextCache == .fourBit
                ? "This recording exceeds the memory budget. Use a shorter recording."
                : "This recording exceeds the memory budget for the selected mode. Choose a lower-memory mode or a shorter recording.")
        }
    }

    private func parametersMemoryBytes() -> Int {
        parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
    }

    func eosTokenIds() -> Set<Int> {
        [151_643, 151_645]
    }

    func prefill(promptIds: MLXArray, inputEmbeddings: MLXArray,
                         cache: [KVCache], parameters: GenerateParameters,
                         progress: @Sendable (GenerationProgress) -> Void) throws -> MLXArray {
        let prefillStepSize = max(1, parameters.prefillStepSize)
        let totalTokens = promptIds.dim(1)
        var processedTokens = 0

        while totalTokens - processedTokens > 1 {
            try Task.checkCancellation()
            try checkMemory(tokens: totalTokens, parameters: parameters)
            let remaining = (totalTokens - processedTokens) - 1
            let n = min(prefillStepSize, remaining)
            let chunkIds = promptIds[0..., processedTokens..<(processedTokens + n)]
            let chunkEmbeds = inputEmbeddings[0..., processedTokens..<(processedTokens + n), 0...]
            _ = try model(inputIds: chunkIds, inputsEmbeds: chunkEmbeds, cache: cache)
            eval(cache.flatMap { $0.innerState() })
            processedTokens += n
            progress(.prefill(processedTokens, totalTokens))
        }

        let lastIds = promptIds[0..., processedTokens..<totalTokens]
        let lastEmbeds = inputEmbeddings[0..., processedTokens..<totalTokens, 0...]
        let logits = try callAsFunction(inputIds: lastIds, inputEmbeddings: lastEmbeds, cache: cache)
        eval(logits)
        return logits[0..., -1, 0...]
    }

    private func generateTokenIds(
        prepared: inout PreparedGenerationInputs?, parameters: GenerateParameters,
        progress: @Sendable (GenerationProgress) -> Void
    ) throws -> (tokens: [Int], prefillTime: Double, cacheBytes: Int) {
        let totalTokens = prepared!.promptTokenCount
        let limit = try GenerationPolicy.tokenLimit(requested: parameters.maxTokens,
            promptTokens: totalTokens, contextSize: config.textConfig.maxPositionEmbeddings)
        let cache = makeCache(context: parameters.contextCache)
        let started = Date()
        var lastLogits = try prefill(promptIds: prepared!.promptIds,
            inputEmbeddings: prepared!.inputEmbeddings, cache: cache, parameters: parameters, progress: progress)
        prepared = nil
        Memory.clearCache()
        let prefillTime = Date().timeIntervalSince(started)
        lastLogits = applyLogitProcessors(lastLogits, generated: [], parameters: parameters)
        var nextTokenArray = sampleFromLogits(lastLogits, parameters: parameters)
        asyncEval(nextTokenArray)
        var generated: [Int] = []
        let eos = eosTokenIds()
        var lastDecoded = Date.distantPast

        progress(.prefill(totalTokens, totalTokens))
        for tokenIndex in 0..<limit {
            try Task.checkCancellation()
            do { try checkMemory(tokens: totalTokens + tokenIndex + 2, parameters: parameters) }
            catch {
                // A completed transcript needs no speculative next step or cache growth.
                if eos.contains(nextTokenArray.item(Int.self)) {
                    return (try GenerationPolicy.completedTokens(generated, reachedEOS: true),
                            prefillTime, cache.flatMap { $0.innerState() }.reduce(0) { $0 + $1.nbytes })
                }
                throw error
            }
            let current = nextTokenArray
            let pipelined = parameters.temperature <= 0 && parameters.repetitionPenalty == 1 && tokenIndex < limit - 1
            if pipelined {
                let output = try callAsFunction(inputIds: current.reshaped(1, 1), cache: cache)
                nextTokenArray = output[0..., -1, 0...].argMax(axis: -1)
                asyncEval(nextTokenArray)
            }
            let token = current.item(Int.self)
            if eos.contains(token) {
                return (try GenerationPolicy.completedTokens(generated, reachedEOS: true), prefillTime, cache.flatMap { $0.innerState() }.reduce(0) { $0 + $1.nbytes })
            }
            generated.append(token)

            try GenerationPolicy.checkRepetition(generated)
            if generated.count % 32 == 0 && Date().timeIntervalSince(lastDecoded) >= 0.5 {
                lastDecoded = Date()
                progress(.decoded(tokenizer?.decode(tokens: generated, skipSpecialTokens: true) ?? ""))
            }
            if tokenIndex == limit - 1 { break }

            if pipelined { continue }
            let nextInput = MLXArray([Int32(token)]).expandedDimensions(axis: 0)
            let logits = try callAsFunction(inputIds: nextInput, cache: cache)
            lastLogits = logits[0..., -1, 0...]
            lastLogits = applyLogitProcessors(lastLogits, generated: generated, parameters: parameters)
            nextTokenArray = sampleFromLogits(lastLogits, parameters: parameters)
            asyncEval(nextTokenArray)
        }
        return (try GenerationPolicy.completedTokens(generated, reachedEOS: false), prefillTime, 0)
    }

    func applyLogitProcessors(
        _ logits: MLXArray,
        generated: [Int],
        parameters: GenerateParameters
    ) -> MLXArray {
        var lastLogits = logits
        if parameters.temperature > 0 {
            lastLogits = lastLogits / parameters.temperature
        }
        if parameters.repetitionPenalty != 1.0 && !generated.isEmpty {
            let recent = Array(generated.suffix(max(1, parameters.repetitionContextSize))).map(Int32.init)
            let recentArray = MLXArray(recent)
            let logitsForRecent = lastLogits[0..., recentArray]
            let penalty = MLXArray(parameters.repetitionPenalty)
            lastLogits[0..., recentArray] = MLX.where(
                logitsForRecent .> 0,
                logitsForRecent / penalty,
                logitsForRecent * penalty
            )
        }
        return lastLogits
    }

    /// Greedy when temperature <= 0; otherwise multinomial with optional top-k / top-p.
    func sampleFromLogits(_ logits: MLXArray, parameters: GenerateParameters) -> MLXArray {
        if parameters.temperature <= 0 {
            return logits.argMax(axis: -1)
        }

        var values = logits.asArray(Float.self)
        let vocab = values.count
        guard vocab > 0 else { return MLXArray([Int32(0)]) }

        if parameters.topK > 0 && parameters.topK < vocab {
            let sorted = values.enumerated().sorted { $0.element > $1.element }
            let keep = Set(sorted.prefix(parameters.topK).map(\.offset))
            for index in values.indices where !keep.contains(index) {
                values[index] = -Float.greatestFiniteMagnitude
            }
        }

        // Softmax
        let maxLogit = values.max() ?? 0
        var probs = values.map { exp($0 - maxLogit) }
        var sum = probs.reduce(0, +)
        if sum <= 0 {
            return logits.argMax(axis: -1)
        }
        probs = probs.map { $0 / sum }

        if parameters.topP < 1.0 {
            let order = probs.enumerated().sorted { $0.element > $1.element }
            var cumulative: Float = 0
            var allowed = Set<Int>()
            for item in order {
                allowed.insert(item.offset)
                cumulative += item.element
                if cumulative >= parameters.topP { break }
            }
            for index in probs.indices where !allowed.contains(index) {
                probs[index] = 0
            }
            sum = probs.reduce(0, +)
            if sum > 0 {
                probs = probs.map { $0 / sum }
            }
        }

        if parameters.minP > 0 {
            let peak = probs.max() ?? 0
            let threshold = peak * parameters.minP
            for index in probs.indices where probs[index] < threshold {
                probs[index] = 0
            }
            sum = probs.reduce(0, +)
            if sum > 0 {
                probs = probs.map { $0 / sum }
            }
        }

        // Multinomial sample
        var draw = Float.random(in: 0..<1)
        for (index, probability) in probs.enumerated() {
            draw -= probability
            if draw <= 0 {
                return MLXArray([Int32(index)])
            }
        }
        return MLXArray([Int32(probs.count - 1)])
    }
}
