import Foundation
@preconcurrency import MLX
import MLXFast
import MLXNN

// Adapted from Blaizzy/mlx-audio-swift WhisperLayers (encoder only).

// MARK: - Attention

/// Multi-head attention shared by encoder self-attention and decoder
/// self/cross-attention. Whisper omits the bias on `k_proj`; all other
/// projections carry bias.
final class MossWhisperAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scaling: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(embedDim: Int, numHeads: Int) {
        self.embedDim = embedDim
        self.numHeads = numHeads
        self.headDim = embedDim / numHeads
        self.scaling = pow(Float(headDim), -0.5)

        self._qProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._kProj.wrappedValue = Linear(embedDim, embedDim, bias: false)
        self._vProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._outProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
    }

    /// Run attention with optional cached K/V (for the decoder's autoregressive
    /// path). Returns `(output, newK, newV)`.
    func callAsFunction(
        _ hidden: MLXArray,
        keyValueInput: MLXArray,
        cachedKeys: MLXArray? = nil,
        cachedValues: MLXArray? = nil,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none
    ) -> (MLXArray, MLXArray, MLXArray) {
        let B = hidden.shape[0]
        let Tq = hidden.shape[1]

        let q = qProj(hidden).reshaped([B, Tq, numHeads, headDim]).transposed(0, 2, 1, 3)

        var keys: MLXArray
        var values: MLXArray
        if let cachedKeys, let cachedValues {
            let Tnew = keyValueInput.shape[1]
            let newK = kProj(keyValueInput).reshaped([B, Tnew, numHeads, headDim]).transposed(0, 2, 1, 3)
            let newV = vProj(keyValueInput).reshaped([B, Tnew, numHeads, headDim]).transposed(0, 2, 1, 3)
            keys = MLX.concatenated([cachedKeys, newK], axis: 2)
            values = MLX.concatenated([cachedValues, newV], axis: 2)
        } else {
            let Tk = keyValueInput.shape[1]
            keys = kProj(keyValueInput).reshaped([B, Tk, numHeads, headDim]).transposed(0, 2, 1, 3)
            values = vProj(keyValueInput).reshaped([B, Tk, numHeads, headDim]).transposed(0, 2, 1, 3)
        }

        let attn = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: keys,
            values: values,
            scale: scaling,
            mask: mask
        )

        let merged = attn.transposed(0, 2, 1, 3).reshaped([B, Tq, embedDim])
        return (outProj(merged), keys, values)
    }
}

// MARK: - Encoder

final class MossWhisperEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: MossWhisperAttention
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    init(config: AudioEncoderConfig) {
        let d = config.dModel
        self._selfAttn.wrappedValue = MossWhisperAttention(
            embedDim: d,
            numHeads: config.encoderAttentionHeads
        )
        self._selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: d)
        self._fc1.wrappedValue = Linear(d, config.encoderFfnDim, bias: true)
        self._fc2.wrappedValue = Linear(config.encoderFfnDim, d, bias: true)
        self._finalLayerNorm.wrappedValue = LayerNorm(dimensions: d)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var residual = x
        var h = selfAttnLayerNorm(x)
        let (attnOut, _, _) = selfAttn(h, keyValueInput: h)
        h = residual + attnOut

        residual = h
        h = finalLayerNorm(h)
        h = gelu(fc1(h))
        h = fc2(h)
        return residual + h
    }
}

final class MossWhisperEncoder: Module {
    let config: AudioEncoderConfig

    @ModuleInfo(key: "conv1") var conv1: Conv1d
    @ModuleInfo(key: "conv2") var conv2: Conv1d
    @ModuleInfo(key: "embed_positions") var embedPositions: Embedding
    @ModuleInfo(key: "layers") var layers: [MossWhisperEncoderLayer]
    @ModuleInfo(key: "layer_norm") var layerNorm: LayerNorm

    init(config: AudioEncoderConfig) {
        self.config = config
        let d = config.dModel
        self._conv1.wrappedValue = Conv1d(
            inputChannels: config.numMelBins,
            outputChannels: d,
            kernelSize: 3,
            stride: 1,
            padding: 1
        )
        self._conv2.wrappedValue = Conv1d(
            inputChannels: d,
            outputChannels: d,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        self._embedPositions.wrappedValue = Embedding(
            embeddingCount: config.maxSourcePositions,
            dimensions: d
        )
        self._layers.wrappedValue = (0..<config.encoderLayers).map { _ in
            MossWhisperEncoderLayer(config: config)
        }
        self._layerNorm.wrappedValue = LayerNorm(dimensions: d)
    }

    func callAsFunction(_ inputFeatures: MLXArray) -> MLXArray {
        var h = gelu(conv1(inputFeatures))
        h = gelu(conv2(h))
        let seqLen = h.shape[1]
        h = h + embedPositions.weight[0..<seqLen]
        for layer in layers {
            h = layer(h)
        }
        return layerNorm(h)
    }
}
