// Gemma 4 text model implementation for mlx-swift-lm.
// Ported from mlx-vlm/mlx_vlm/models/gemma4/language.py
// Source: https://github.com/vdthatte/gemma4-ios

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - Configuration

public struct Gemma4TextConfiguration: Codable {
    let modelType: String
    let hiddenSize: Int
    let numHiddenLayers: Int
    let intermediateSize: Int
    let numAttentionHeads: Int
    let headDim: Int
    let globalHeadDim: Int?
    let rmsNormEps: Float
    let vocabSize: Int
    let numKeyValueHeads: Int
    let numKvSharedLayers: Int
    let slidingWindow: Int
    let slidingWindowPattern: Int
    let maxPositionEmbeddings: Int
    let finalLogitSoftcapping: Float
    let ropeTraditional: Bool
    let hiddenSizePerLayerInput: Int
    let vocabSizePerLayerInput: Int
    let useDoubleWideMlp: Bool
    let tieWordEmbeddings: Bool
    let layerTypes: [String]?
    let ropeParameters: [String: [String: Gemma4AnyCodable]]?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case numAttentionHeads = "num_attention_heads"
        case headDim = "head_dim"
        case globalHeadDim = "global_head_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabSize = "vocab_size"
        case numKeyValueHeads = "num_key_value_heads"
        case numKvSharedLayers = "num_kv_shared_layers"
        case slidingWindow = "sliding_window"
        case slidingWindowPattern = "sliding_window_pattern"
        case maxPositionEmbeddings = "max_position_embeddings"
        case finalLogitSoftcapping = "final_logit_softcapping"
        case ropeTraditional = "rope_traditional"
        case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
        case vocabSizePerLayerInput = "vocab_size_per_layer_input"
        case useDoubleWideMlp = "use_double_wide_mlp"
        case tieWordEmbeddings = "tie_word_embeddings"
        case layerTypes = "layer_types"
        case ropeParameters = "rope_parameters"
    }

    enum VLMCodingKeys: String, CodingKey {
        case textConfig = "text_config"
    }

    public init(from decoder: Decoder) throws {
        let nestedContainer = try decoder.container(keyedBy: VLMCodingKeys.self)
        let container =
            if nestedContainer.contains(.textConfig) {
                try nestedContainer.nestedContainer(keyedBy: CodingKeys.self, forKey: .textConfig)
            } else {
                try decoder.container(keyedBy: CodingKeys.self)
            }

        modelType = try container.decode(String.self, forKey: .modelType)
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1536
        numHiddenLayers = try container.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? 35
        intermediateSize = try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 6144
        numAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 8
        headDim = try container.decodeIfPresent(Int.self, forKey: .headDim) ?? 256
        globalHeadDim = try container.decodeIfPresent(Int.self, forKey: .globalHeadDim)
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        vocabSize = try container.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 262144
        numKeyValueHeads = try container.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? 1
        numKvSharedLayers = try container.decodeIfPresent(Int.self, forKey: .numKvSharedLayers) ?? 20
        slidingWindow = try container.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 512
        slidingWindowPattern = try container.decodeIfPresent(Int.self, forKey: .slidingWindowPattern) ?? 5
        maxPositionEmbeddings = try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131072
        finalLogitSoftcapping = try container.decodeIfPresent(Float.self, forKey: .finalLogitSoftcapping) ?? 30.0
        ropeTraditional = try container.decodeIfPresent(Bool.self, forKey: .ropeTraditional) ?? false
        hiddenSizePerLayerInput = try container.decodeIfPresent(Int.self, forKey: .hiddenSizePerLayerInput) ?? 256
        vocabSizePerLayerInput = try container.decodeIfPresent(Int.self, forKey: .vocabSizePerLayerInput) ?? 262144
        useDoubleWideMlp = try container.decodeIfPresent(Bool.self, forKey: .useDoubleWideMlp) ?? true
        tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        layerTypes = try container.decodeIfPresent([String].self, forKey: .layerTypes)
        ropeParameters = try container.decodeIfPresent([String: [String: Gemma4AnyCodable]].self, forKey: .ropeParameters)
    }

    var resolvedLayerTypes: [String] {
        if let lt = layerTypes { return lt }
        let pattern = Array(repeating: "sliding_attention", count: slidingWindowPattern - 1) + ["full_attention"]
        var result = [String]()
        while result.count < numHiddenLayers {
            result.append(contentsOf: pattern)
        }
        return Array(result.prefix(numHiddenLayers))
    }

    func ropeTheta(forLayerType type: String) -> Float {
        if let params = ropeParameters?[type],
           let theta = params["rope_theta"]?.floatValue {
            return theta
        }
        return type == "sliding_attention" ? 10000.0 : 1_000_000.0
    }

    func partialRotaryFactor(forLayerType type: String) -> Float {
        if let params = ropeParameters?[type],
           let factor = params["partial_rotary_factor"]?.floatValue {
            return factor
        }
        return 1.0
    }

    func ropeType(forLayerType type: String) -> String {
        if let params = ropeParameters?[type],
           let rt = params["rope_type"]?.stringValue {
            return rt
        }
        return "default"
    }
}

// MARK: - AnyCodable helper (Gemma4-namespaced to avoid collisions)

public struct Gemma4AnyCodable: Codable {
    let value: Any

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else { value = "" }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? Double { try container.encode(v) }
        else if let v = value as? String { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
    }

    var floatValue: Float? {
        if let v = value as? Double { return Float(v) }
        if let v = value as? Int { return Float(v) }
        return nil
    }

    var stringValue: String? {
        value as? String
    }
}

// MARK: - ProportionalRoPE

nonisolated class Gemma4ProportionalRoPE: Module, OffsetLayer {
    let dims: Int
    let rotatedDims: Int
    let traditional: Bool
    let _freqs: MLXArray?

    init(dims: Int, traditional: Bool = false, base: Float = 10000.0, partialRotaryFactor: Float = 1.0, factor: Float = 1.0) {
        self.dims = dims
        self.traditional = traditional

        let ropeAngles = Int(partialRotaryFactor * Float(dims) / 2.0)
        self.rotatedDims = 2 * ropeAngles

        if rotatedDims > 0 {
            let exponents = MLXArray(stride(from: Float(0), to: Float(rotatedDims), by: 2)) / Float(dims)
            self._freqs = factor * pow(MLXArray(base), exponents)
        } else {
            self._freqs = nil
        }
        super.init()
    }

    nonisolated(unsafe) private static var didLogShapes = false

    func callAsFunction(_ x: MLXArray, offset: Int) -> MLXArray {
        guard rotatedDims > 0 else { return x }

        if !Self.didLogShapes {
            Self.didLogShapes = true
            NSLog("🔬 Gemma4 RoPE x.shape=%@ dims=%d rotatedDims=%d offset=%d", "\(x.shape)", dims, rotatedDims, offset)
        }

        // Full rotary (rotatedDims == dims): the split/concat path below produces
        // zero-length slices — left[(rotatedDims/2)...] etc. — and concatenating empty
        // arrays crashes mlx-c with "SmallVector out of range". Apply RoPE to the whole
        // rotated span directly; this is mathematically identical to the split/concat
        // when rotatedDims == dims, just without the empty slices.
        if rotatedDims >= dims {
            let head = x[.ellipsis, 0 ..< dims]
            let rotated = MLXFast.RoPE(
                head, dimensions: rotatedDims, traditional: traditional,
                base: nil, scale: 1.0, offset: offset, freqs: _freqs
            )
            if x.shape.last! > dims {
                return concatenated([rotated, x[.ellipsis, dims...]], axis: -1)
            }
            return rotated
        }

        let head = x[.ellipsis, 0 ..< dims]
        let half = dims / 2

        let left = head[.ellipsis, 0 ..< half]
        let right = head[.ellipsis, half ..< dims]

        let rotatedLeft = left[.ellipsis, 0 ..< (rotatedDims / 2)]
        let rotatedRight = right[.ellipsis, 0 ..< (rotatedDims / 2)]
        var rotated = concatenated([rotatedLeft, rotatedRight], axis: -1)

        rotated = MLXFast.RoPE(
            rotated,
            dimensions: rotatedDims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )

        let newLeft = concatenated([
            rotated[.ellipsis, 0 ..< (rotatedDims / 2)],
            left[.ellipsis, (rotatedDims / 2)...]
        ], axis: -1)
        let newRight = concatenated([
            rotated[.ellipsis, (rotatedDims / 2)...],
            right[.ellipsis, (rotatedDims / 2)...]
        ], axis: -1)
        let newHead = concatenated([newLeft, newRight], axis: -1)

        if x.shape.last! > dims {
            return concatenated([newHead, x[.ellipsis, dims...]], axis: -1)
        }
        return newHead
    }
}

// MARK: - RMSNormNoScale

nonisolated class Gemma4RMSNormNoScale: Module {
    let eps: Float

    init(eps: Float = 1e-6) {
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }
}

// MARK: - Attention

nonisolated class Gemma4Attention: Module {
    let isSliding: Bool
    let layerIdx: Int
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float
    let isKvSharedLayer: Bool

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    @ModuleInfo(key: "v_norm") var vNorm: Gemma4RMSNormNoScale
    @ModuleInfo var rope: OffsetLayer

    init(_ config: Gemma4TextConfiguration, layerIdx: Int) {
        let layerTypes = config.resolvedLayerTypes
        let layerType = layerTypes[layerIdx]
        self.isSliding = layerType == "sliding_attention"
        self.layerIdx = layerIdx

        let dim = config.hiddenSize
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = (!isSliding && config.globalHeadDim != nil) ? config.globalHeadDim! : config.headDim
        self.scale = 1.0

        self._qProj.wrappedValue = Linear(dim, numHeads * headDim, bias: false)
        self._kProj.wrappedValue = Linear(dim, numKVHeads * headDim, bias: false)
        self._vProj.wrappedValue = Linear(dim, numKVHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, dim, bias: false)

        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._vNorm.wrappedValue = Gemma4RMSNormNoScale(eps: config.rmsNormEps)

        let firstKvSharedIdx = config.numHiddenLayers - config.numKvSharedLayers
        self.isKvSharedLayer = layerIdx >= firstKvSharedIdx && firstKvSharedIdx > 0

        let ropeTheta = config.ropeTheta(forLayerType: layerType)
        let ropeType = config.ropeType(forLayerType: layerType)

        if ropeType == "proportional" {
            let partialFactor = config.partialRotaryFactor(forLayerType: layerType)
            self._rope.wrappedValue = Gemma4ProportionalRoPE(
                dims: headDim, traditional: config.ropeTraditional,
                base: ropeTheta, partialRotaryFactor: partialFactor
            )
        } else {
            self._rope.wrappedValue = RoPE(
                dimensions: headDim, traditional: config.ropeTraditional, base: ropeTheta
            )
        }

        super.init()
    }

    nonisolated(unsafe) private static var didLogAttn = false

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        cache: KVCache? = nil
    ) -> MLXArray {
        let (B, L, _) = (x.dim(0), x.dim(1), x.dim(2))

        var queries = qProj(x).reshaped(B, L, numHeads, headDim)
        queries = qNorm(queries)

        let offset = cache?.offset ?? 0

        var keys: MLXArray
        var values: MLXArray

        if isKvSharedLayer, let cache, cache.state.count >= 2 {
            keys = cache.state[0]
            values = cache.state[1]
        } else {
            keys = kProj(x).reshaped(B, L, numKVHeads, headDim)
            keys = kNorm(keys)
            keys = keys.transposed(0, 2, 1, 3)
            keys = rope(keys, offset: offset)

            values = vProj(x).reshaped(B, L, numKVHeads, headDim)
            values = vNorm(values)
            values = values.transposed(0, 2, 1, 3)

            if let cache {
                (keys, values) = cache.update(keys: keys, values: values)
            }
        }

        queries = queries.transposed(0, 2, 1, 3)
        queries = rope(queries, offset: offset)

        var adjustedMask = mask
        if case .array(let maskArray) = mask {
            let keysSeqLen = keys.dim(2)
            let maskLen = maskArray.shape.last ?? keysSeqLen
            if !Self.didLogAttn {
                Self.didLogAttn = true
                NSLog("🔬 Gemma4 attn B=%d L=%d keys.shape=%@ queries.shape=%@ maskLen=%d keysSeqLen=%d", B, L, "\(keys.shape)", "\(queries.shape)", maskLen, keysSeqLen)
            }
            // Only trim when the mask is LONGER than the key sequence — slicing
            // 0..<keysSeqLen when keysSeqLen exceeds the mask's last dim would itself
            // be out of range. If it's shorter/equal, pass it through unchanged.
            if maskLen > keysSeqLen {
                adjustedMask = .array(maskArray[.ellipsis, 0 ..< keysSeqLen].asType(queries.dtype))
            } else {
                adjustedMask = .array(maskArray.asType(queries.dtype))
            }
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values,
            scale: scale, mask: adjustedMask ?? .none
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return oProj(output)
    }
}

// MARK: - MLP

nonisolated class Gemma4MLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        self._gateProj.wrappedValue = Linear(hiddenSize, intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(hiddenSize, intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(intermediateSize, hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

// MARK: - DecoderLayer

nonisolated class Gemma4DecoderLayer: Module {
    let config: Gemma4TextConfiguration
    let layerIdx: Int
    let isSliding: Bool
    let hiddenSizePerLayerInput: Int

    @ModuleInfo(key: "self_attn") var selfAttn: Gemma4Attention
    @ModuleInfo var mlp: Gemma4MLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayernorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayernorm: RMSNorm
    @ModuleInfo(key: "layer_scalar") var layerScalar: MLXArray

    @ModuleInfo(key: "per_layer_input_gate") var perLayerInputGate: Linear?
    @ModuleInfo(key: "per_layer_projection") var perLayerProjection: Linear?
    @ModuleInfo(key: "post_per_layer_input_norm") var postPerLayerInputNorm: RMSNorm?

    init(_ config: Gemma4TextConfiguration, layerIdx: Int) {
        self.config = config
        self.layerIdx = layerIdx
        self.hiddenSizePerLayerInput = config.hiddenSizePerLayerInput

        let layerTypes = config.resolvedLayerTypes
        self.isSliding = layerTypes[layerIdx] == "sliding_attention"

        let firstKvSharedIdx = config.numHiddenLayers - config.numKvSharedLayers
        let isKvShared = layerIdx >= firstKvSharedIdx && firstKvSharedIdx > 0
        let effectiveIntermediateSize = config.useDoubleWideMlp && isKvShared
            ? config.intermediateSize * 2
            : config.intermediateSize

        self._selfAttn.wrappedValue = Gemma4Attention(config, layerIdx: layerIdx)
        self._mlp.wrappedValue = Gemma4MLP(hiddenSize: config.hiddenSize, intermediateSize: effectiveIntermediateSize)

        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._preFeedforwardLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postFeedforwardLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._layerScalar.wrappedValue = MLXArray.ones([1])

        if hiddenSizePerLayerInput > 0 {
            self._perLayerInputGate.wrappedValue = Linear(config.hiddenSize, hiddenSizePerLayerInput, bias: false)
            self._perLayerProjection.wrappedValue = Linear(hiddenSizePerLayerInput, config.hiddenSize, bias: false)
            self._postPerLayerInputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        cache: KVCache? = nil,
        perLayerInput: MLXArray? = nil
    ) -> MLXArray {
        var residual = x

        var h = inputLayernorm(x)
        h = selfAttn(h, mask: mask, cache: cache)
        h = postAttentionLayernorm(h)
        h = residual + h

        residual = h
        h = preFeedforwardLayernorm(h)
        h = mlp(h)
        h = postFeedforwardLayernorm(h)
        h = residual + h

        if let gate = perLayerInputGate,
           let proj = perLayerProjection,
           let norm = postPerLayerInputNorm,
           let pli = perLayerInput {
            residual = h
            var g = gate(h)
            g = geluApproximate(g)
            g = g * pli
            g = proj(g)
            g = norm(g)
            h = residual + g
        }

        h = h * layerScalar

        return h
    }
}

// MARK: - ScaledLinear

nonisolated class Gemma4ScaledLinear: Module {
    @ModuleInfo var weight: MLXArray
    let scalar: Float

    init(inFeatures: Int, outFeatures: Int, scalar: Float) {
        self.scalar = scalar
        self._weight.wrappedValue = MLXArray.zeros([outFeatures, inFeatures])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(x, weight.transposed()) * scalar
    }
}

// MARK: - RMSNormZeroShift

nonisolated class Gemma4RMSNormZeroShift: Module {
    @ModuleInfo var weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float = 1e-6) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

// MARK: - Inner Model

nonisolated class Gemma4InnerModel: Module {
    let config: Gemma4TextConfiguration
    let firstKvSharedLayerIdx: Int
    let layerIdxToCacheIdx: [Int]
    let firstFullCacheIdx: Int
    let firstSlidingCacheIdx: Int

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [Gemma4DecoderLayer]
    @ModuleInfo var norm: RMSNorm

    @ModuleInfo(key: "embed_tokens_per_layer") var embedTokensPerLayer: Embedding?
    @ModuleInfo(key: "per_layer_model_projection") var perLayerModelProjection: Gemma4ScaledLinear?
    @ModuleInfo(key: "per_layer_projection_norm") var perLayerProjectionNorm: Gemma4RMSNormZeroShift?

    init(_ config: Gemma4TextConfiguration) {
        self.config = config
        let layerTypes = config.resolvedLayerTypes

        self.firstKvSharedLayerIdx = config.numHiddenLayers - config.numKvSharedLayers

        let concreteLayers = Array(layerTypes.prefix(firstKvSharedLayerIdx))
        let sharedFullIdx = concreteLayers.lastIndex(of: "full_attention") ?? 0
        let sharedSlidingIdx = concreteLayers.lastIndex(of: "sliding_attention") ?? 0

        var mapping = [Int]()
        for (i, lt) in layerTypes.enumerated() {
            if i < firstKvSharedLayerIdx {
                mapping.append(i)
            } else if lt == "full_attention" {
                mapping.append(sharedFullIdx)
            } else {
                mapping.append(sharedSlidingIdx)
            }
        }
        self.layerIdxToCacheIdx = mapping

        self.firstFullCacheIdx = concreteLayers.firstIndex(of: "full_attention") ?? 0
        self.firstSlidingCacheIdx = concreteLayers.firstIndex(of: "sliding_attention") ?? 0

        self._embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0 ..< config.numHiddenLayers).map { Gemma4DecoderLayer(config, layerIdx: $0) }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        if config.hiddenSizePerLayerInput > 0 {
            self._embedTokensPerLayer.wrappedValue = Embedding(
                embeddingCount: config.vocabSizePerLayerInput,
                dimensions: config.numHiddenLayers * config.hiddenSizePerLayerInput
            )
            self._perLayerModelProjection.wrappedValue = Gemma4ScaledLinear(
                inFeatures: config.hiddenSize,
                outFeatures: config.numHiddenLayers * config.hiddenSizePerLayerInput,
                scalar: pow(Float(config.hiddenSize), -0.5)
            )
            self._perLayerProjectionNorm.wrappedValue = Gemma4RMSNormZeroShift(
                dimensions: config.hiddenSizePerLayerInput, eps: config.rmsNormEps
            )
        }

        super.init()
    }

    func callAsFunction(
        _ inputs: MLXArray,
        cache: [KVCache?]? = nil
    ) -> MLXArray {
        let embedScale = sqrt(Float(config.hiddenSize))
        var h = embedTokens(inputs)
        h = h * MLXArray(embedScale).asType(h.dtype)

        var perLayerInputs: MLXArray? = nil
        if config.hiddenSizePerLayerInput > 0,
           let embedPL = embedTokensPerLayer,
           let proj = perLayerModelProjection,
           let projNorm = perLayerProjectionNorm {
            var pli = embedPL(inputs)
            pli = pli * MLXArray(sqrt(Float(config.hiddenSizePerLayerInput))).asType(pli.dtype)
            pli = pli.reshaped(inputs.shape + [config.numHiddenLayers, config.hiddenSizePerLayerInput])

            var plProj = proj(h)
            plProj = plProj.reshaped(h.shape.dropLast() + [config.numHiddenLayers, config.hiddenSizePerLayerInput])
            plProj = projNorm(plProj)

            perLayerInputs = (plProj + pli) * MLXArray(pow(2.0 as Float, -0.5)).asType(pli.dtype)
        }

        let globalMask = gemma4CreateAttentionMask(
            h: h,
            cache: firstFullCacheIdx < (cache?.count ?? 0) ? cache?[firstFullCacheIdx] : nil
        )
        let slidingMask = gemma4CreateAttentionMask(
            h: h,
            cache: firstSlidingCacheIdx < (cache?.count ?? 0) ? cache?[firstSlidingCacheIdx] : nil,
            windowSize: config.slidingWindow
        )

        let layerTypes = config.resolvedLayerTypes

        for (i, layer) in layers.enumerated() {
            let c = cache?[layerIdxToCacheIdx[i]]
            let isGlobal = layerTypes[i] == "full_attention"
            let mask = isGlobal ? globalMask : slidingMask

            var pli: MLXArray? = nil
            if let perLayerInputs {
                pli = perLayerInputs[.ellipsis, i, 0...]
            }

            h = layer(h, mask: mask, cache: c, perLayerInput: pli)
        }

        return norm(h)
    }
}

// MARK: - Gemma4TextModel (LanguageModel)

nonisolated public class Gemma4TextModel: Module, LanguageModel {

    @ModuleInfo var model: Gemma4InnerModel
    let config: Gemma4TextConfiguration

    public init(_ config: Gemma4TextConfiguration) {
        self.config = config
        self.model = Gemma4InnerModel(config)
        super.init()
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]? = nil) -> MLXArray {
        var out = model(inputs, cache: cache)
        out = model.embedTokens.asLinear(out)
        if config.finalLogitSoftcapping > 0 {
            out = tanh(out / config.finalLogitSoftcapping) * config.finalLogitSoftcapping
        }
        return out
    }

    public func newCache(parameters: GenerateParameters? = nil) -> [KVCache] {
        let layerTypes = config.resolvedLayerTypes
        let firstKvShared = config.numHiddenLayers - config.numKvSharedLayers
        var caches = [KVCache]()
        for i in 0 ..< firstKvShared {
            if layerTypes[i] == "full_attention" {
                caches.append(StandardKVCache())
            } else {
                caches.append(RotatingKVCache(maxSize: config.slidingWindow, keep: 0))
            }
        }
        return caches
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var w = weights

        let unflattened = ModuleParameters.unflattened(weights)
        if let lm = unflattened["language_model"] {
            w = Dictionary(uniqueKeysWithValues: lm.flattened())
        }

        w = w.filter {
            !$0.key.contains("rotary_emb") &&
            !$0.key.hasPrefix("lm_head")
        }

        return w
    }

    public func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        let prefillStepSize = windowSize ?? 512
        var y = input.text

        while y.tokens.size > prefillStepSize {
            let chunk = y[.newAxis, ..<prefillStepSize]
            _ = self(chunk, cache: cache.isEmpty ? nil : cache, state: nil)
            eval(cache)
            y = y[prefillStepSize...]
        }

        return .tokens(y)
    }
}

// MARK: - Attention mask helper

private func gemma4CreateAttentionMask(
    h: MLXArray,
    cache: KVCache?,
    windowSize: Int? = nil
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    let T = h.dim(1)

    if T == 1 {
        return .none
    }

    let offset = cache?.offset ?? 0
    let totalLen = T + offset

    let causal = tril(MLXArray.ones([T, T], type: Bool.self), k: 0)
    let causalPart = MLX.where(causal, MLXArray.zeros([T, T], dtype: h.dtype), MLXArray(Float.leastNormalMagnitude).asType(h.dtype))

    var mask: MLXArray
    if offset > 0 {
        mask = concatenated([MLXArray.zeros([T, offset], dtype: h.dtype), causalPart], axis: 1)
    } else {
        mask = causalPart
    }

    if let windowSize {
        let positions = MLXArray(0 ..< T) + offset
        let keys = MLXArray(0 ..< totalLen)
        let windowMask = (keys .< (expandedDimensions(positions, axis: 1) - windowSize + 1))
        mask = MLX.where(windowMask, MLXArray(Float.leastNormalMagnitude).asType(h.dtype), mask)
    }

    return .array(mask)
}
