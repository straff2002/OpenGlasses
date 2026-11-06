#!/usr/bin/env python3
"""Convert EmbeddingGemma 2's text encoder to Core ML (Plan KQ P0).

Usage: python convert.py <model-dir> <out-dir>

Writes eg2-text-fp32 / -int8 / -int8-fp16 .mlpackage to <out-dir> (see README.md). Input `input_ids`
(int32, 1 x L) and `attention_mask` (float32, 1 x L, 1 = token, 0 = padding), with L from 1 to 512.
Output `embedding` (float32, 1 x 768), mean-pooled over the unmasked tokens and L2-normalised.
"""

import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from sentence_transformers import SentenceTransformer

MAX_TOKENS = 512


def _rotate_half(x, half):
    return torch.cat((-x[..., half:], x[..., :half]), dim=-1)


class TextEncoder(nn.Module):
    """The text model's forward, written with fixed head shapes so it traces, and one padding mask.

    The library's forward builds its masks through helpers that don't trace, and its attention reshapes
    from runtime shapes, which the converter can't fold. This is the same computation using the same
    modules' weights, with every head count and head size a Python constant; `main` checks it against
    the library before converting. Up to the sliding window (512 tokens, +1), a sliding layer sees every
    token, so one bidirectional padding mask serves both layer types.
    """

    def __init__(self, text):
        super().__init__()
        self.text = text
        config = text.config
        assert MAX_TOKENS <= config.sliding_window, f"sliding window {config.sliding_window} is below {MAX_TOKENS}"
        self.layer_types = list(config.layer_types)
        self.heads = config.num_attention_heads
        self.layers_n = config.num_hidden_layers
        self.ple_dim = config.hidden_size_per_layer_input
        self.ple_scale = text.ple.per_layer_model_projection_scale
        for kind in set(self.layer_types):
            assert getattr(text.rotary_emb, f"{kind}_attention_scaling") == 1.0

    def _attention(self, attn, hidden, additive, cos, sin):
        head_dim, kv_heads = attn.head_dim, attn.k_proj.out_features // attn.head_dim
        q = attn.q_proj(hidden).reshape(1, -1, self.heads, head_dim).transpose(1, 2)
        k = attn.k_proj(hidden).reshape(1, -1, kv_heads, head_dim).transpose(1, 2)
        v = attn.v_proj(hidden).reshape(1, -1, kv_heads, head_dim).transpose(1, 2)
        q, k, v = attn.q_norm(q), attn.k_norm(k), attn.v_norm(v)
        cos, sin = cos.unsqueeze(1), sin.unsqueeze(1)
        half = head_dim // 2
        q = q * cos + _rotate_half(q, half) * sin
        k = k * cos + _rotate_half(k, half) * sin
        groups = self.heads // kv_heads
        if groups > 1:
            k = k.repeat_interleave(groups, dim=1)
            v = v.repeat_interleave(groups, dim=1)
        scores = torch.matmul(q, k.transpose(2, 3)) * attn.scaling + additive
        out = torch.matmul(torch.softmax(scores, dim=-1), v)
        out = out.transpose(1, 2).reshape(1, -1, self.heads * head_dim)
        return attn.o_proj(out)

    def forward(self, input_ids, attention_mask):
        text = self.text
        mask = attention_mask.float()
        embeds = text.embed_tokens(input_ids.long())
        ple = text.ple
        per_layer = ple.per_layer_model_projection(embeds) * self.ple_scale
        per_layer = ple.per_layer_projection_norm(per_layer.reshape(1, -1, self.layers_n, self.ple_dim))
        positions = torch.cumsum(torch.ones_like(mask), dim=1) - 1.0
        additive = (1.0 - mask)[:, None, None, :] * -1e9
        cos_sin = {}
        for kind in set(self.layer_types):
            inv_freq = getattr(text.rotary_emb, f"{kind}_inv_freq").float()
            freqs = positions[..., None] * inv_freq
            emb = torch.cat((freqs, freqs), dim=-1)
            cos_sin[kind] = (emb.cos(), emb.sin())
        hidden = embeds
        for i, layer in enumerate(text.layers):
            cos, sin = cos_sin[self.layer_types[i]]
            residual = hidden
            h = self._attention(layer.self_attn, layer.input_layernorm(hidden), additive, cos, sin)
            hidden = residual + layer.post_attention_layernorm(h)
            residual = hidden
            h = layer.mlp(layer.pre_feedforward_layernorm(hidden))
            hidden = residual + layer.post_feedforward_layernorm(h)
            block = layer.ple_block
            g = block.act_fn(block.per_layer_input_gate(hidden)) * per_layer[:, :, i, :]
            hidden = hidden + block.post_per_layer_input_norm(block.per_layer_projection(g))
            hidden = hidden * layer.layer_scalar
        hidden = text.embedding_projection(text.norm(hidden))
        weights = mask.unsqueeze(-1)
        pooled = (hidden * weights).sum(dim=1) / weights.sum(dim=1).clamp(min=1.0)
        return pooled / pooled.norm(dim=-1, keepdim=True).clamp(min=1e-12)


def main():
    model_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    st = SentenceTransformer(str(model_dir), device="cpu", model_kwargs={"dtype": torch.float32})
    hf = st[0].model
    text = hf.language_model if hasattr(hf, "language_model") else hf
    text.config._attn_implementation = "eager"
    text.eval()
    encoder = TextEncoder(text).eval()

    # The wrapper must equal the library's own path before anything is converted.
    sample = "task: search result | query: what does fault Z9 mean on the boiler"
    reference = st.encode([sample], convert_to_numpy=True, normalize_embeddings=True)[0]
    batch = st.tokenize([sample])
    with torch.no_grad():
        mine = encoder(batch["input_ids"].int(), batch["attention_mask"].float())[0].numpy()
    cosine = float(np.dot(reference, mine))
    print(f"[KQ] wrapper vs library cosine {cosine:.6f}")
    assert cosine > 0.9999, "the wrapper does not reproduce the library's embedding"

    example_ids = torch.ones(1, 128, dtype=torch.int32) * 2
    example_mask = torch.ones(1, 128, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(encoder, (example_ids, example_mask), check_trace=False)

    length = ct.RangeDim(lower_bound=1, upper_bound=MAX_TOKENS, default=128)
    inputs = [
        ct.TensorType(name="input_ids", shape=(1, length), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, length), dtype=np.float32),
    ]
    outputs = [ct.TensorType(name="embedding", dtype=np.float32)]

    def convert(precision):
        return ct.convert(traced, inputs=inputs, outputs=outputs, convert_to="mlprogram",
                          compute_precision=precision, minimum_deployment_target=ct.target.iOS18)

    int8 = OptimizationConfig(global_config=OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=2048))

    fp32 = convert(ct.precision.FLOAT32)
    fp32.short_description = "EmbeddingGemma 2 text encoder (Apache 2.0), float32. Plan KQ P0."
    fp32.save(str(out / "eg2-text-fp32.mlpackage"))
    print("[KQ] wrote eg2-text-fp32.mlpackage")

    q32 = linear_quantize_weights(fp32, config=int8)
    q32.short_description = "EmbeddingGemma 2 text encoder (Apache 2.0), int8 weights, float32 compute. Plan KQ P0."
    q32.save(str(out / "eg2-text-int8.mlpackage"))
    print("[KQ] wrote eg2-text-int8.mlpackage")
    del fp32, q32

    fp16 = convert(ct.precision.FLOAT16)
    q16 = linear_quantize_weights(fp16, config=int8)
    q16.short_description = "EmbeddingGemma 2 text encoder (Apache 2.0), int8 weights, float16 compute. Plan KQ P0 test only."
    q16.save(str(out / "eg2-text-int8-fp16.mlpackage"))
    print("[KQ] wrote eg2-text-int8-fp16.mlpackage")


if __name__ == "__main__":
    main()
