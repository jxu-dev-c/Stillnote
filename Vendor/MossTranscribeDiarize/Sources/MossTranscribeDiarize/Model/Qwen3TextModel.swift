import Foundation
@preconcurrency import MLX
import MLXFast
import MLXLMCommon
import MLXNN

// Adapted from Blaizzy/mlx-audio-swift Qwen3ASR text decoder stack.

final class Qwen3TextAttention: Module {
    let hiddenSize: Int
    let numHeads: Int
    let numKvHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE

    init(_ config: TextConfig) {
        self.hiddenSize = config.hiddenSize
        self.numHeads = config.numAttentionHeads
        self.numKvHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = pow(Float(config.headDim), -0.5)

        self._qProj.wrappedValue = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        self._kProj.wrappedValue = Linear(config.hiddenSize, numKvHeads * headDim, bias: false)
        self._vProj.wrappedValue = Linear(config.hiddenSize, numKvHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, config.hiddenSize, bias: false)
        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self.rope = RoPE(dimensions: headDim, traditional: false, base: config.ropeTheta)
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let batch = hiddenStates.dim(0)
        let length = hiddenStates.dim(1)

        var queries = qProj(hiddenStates)
        var keys = kProj(hiddenStates)
        var values = vProj(hiddenStates)

        queries = queries.reshaped(batch, length, numHeads, headDim)
        keys = keys.reshaped(batch, length, numKvHeads, headDim)
        values = values.reshaped(batch, length, numKvHeads, headDim)

        queries = qNorm(queries)
        keys = kNorm(keys)

        queries = queries.transposed(0, 2, 1, 3)
        keys = keys.transposed(0, 2, 1, 3)
        values = values.transposed(0, 2, 1, 3)

        if let cache {
            queries = rope(queries, offset: cache.offset)
            keys = rope(keys, offset: cache.offset)
            (keys, values) = cache.update(keys: keys, values: values)
        } else {
            queries = rope(queries)
            keys = rope(keys)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(batch, length, -1)

        return oProj(output)
    }
}

final class Qwen3TextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: TextConfig) {
        self._gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

final class Qwen3TextDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3TextAttention
    @ModuleInfo(key: "mlp") var mlp: Qwen3TextMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm

    init(_ config: TextConfig) {
        self._selfAttn.wrappedValue = Qwen3TextAttention(config)
        self._mlp.wrappedValue = Qwen3TextMLP(config)
        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(
            dimensions: config.hiddenSize,
            eps: config.rmsNormEps
        )
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        var residual = hiddenStates
        var hidden = inputLayernorm(hiddenStates)
        hidden = selfAttn(hidden, mask: mask, cache: cache)
        hidden = residual + hidden

        residual = hidden
        hidden = postAttentionLayernorm(hidden)
        hidden = mlp(hidden)
        return residual + hidden
    }
}

final class Qwen3TextModel: Module {
    let config: TextConfig

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [Qwen3TextDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(_ config: TextConfig) {
        self.config = config
        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabSize,
            dimensions: config.hiddenSize
        )
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in
            Qwen3TextDecoderLayer(config)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(
        inputIds: MLXArray? = nil,
        inputsEmbeds: MLXArray? = nil,
        cache: [KVCache]? = nil
    ) -> MLXArray {
        let hidden: MLXArray
        if let inputsEmbeds {
            hidden = inputsEmbeds
        } else if let inputIds {
            hidden = embedTokens(inputIds)
        } else {
            fatalError("Either inputIds or inputsEmbeds must be provided")
        }

        let mask = createAttentionMask(h: hidden, cache: cache?.first)
        let caches = cache ?? [KVCache?](repeating: nil, count: layers.count)

        var state = hidden
        for (index, layer) in layers.enumerated() {
            state = layer(state, mask: mask, cache: caches[index])
        }
        return norm(state)
    }
}
