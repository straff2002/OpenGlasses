//
//  LlamaCppWrapper.h
//  Plan DZ P1 — the only surface of the vendored llama.cpp engine that Swift is allowed to see.
//
//  Everything here is C. llama.cpp's own headers are C too, but the library behind them is C++
//  with types whose layout and lifetime rules change between releases; letting those cross into
//  Swift would make every engine bump an app-wide source break. So the whole engine is reachable
//  only through the handful of opaque handles and plain-old-data structs below.
//
//  Conventions, applied uniformly:
//   * Every fallible call returns `OGLlamaStatus`; `OGLlamaStatusOK` is 0 and nothing else is.
//   * Calls that fill a caller-owned buffer return the number of bytes/tokens *needed* when the
//     buffer is too small, as a negative count, so the caller can size and retry. They never
//     write a NUL terminator — the count is the length.
//   * Handles are created by an `_create`/`_load` call and destroyed by exactly one matching
//     `_free`. Freeing NULL is a no-op. A context must be freed before its model.
//   * Nothing here is thread-safe. The owning actor is the synchronization.
//
#ifndef LLAMA_CPP_WRAPPER_H
#define LLAMA_CPP_WRAPPER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Status

typedef int32_t OGLlamaToken;

/// Returned by the lookup calls when the thing asked for does not exist, as distinct from
/// existing and not fitting (which returns the negative size needed). A missing key and an empty
/// value are different answers and the caller has to be able to tell them apart.
#define OG_LLAMA_NOT_FOUND INT32_MIN

typedef enum OGLlamaStatus {
    OGLlamaStatusOK                  = 0,
    OGLlamaStatusInvalidArgument     = 1,
    OGLlamaStatusModelLoadFailed     = 2,
    OGLlamaStatusContextCreateFailed = 3,
    OGLlamaStatusSamplerCreateFailed = 4,
    OGLlamaStatusTokenizeFailed      = 5,
    /// `llama_decode` could not find a KV slot for the batch — the prompt does not fit.
    OGLlamaStatusContextExhausted    = 6,
    OGLlamaStatusDecodeFailed        = 7,
    /// The model carries no usable chat template under the requested name.
    OGLlamaStatusNoChatTemplate      = 8,
    OGLlamaStatusTemplateFailed      = 9,
    /// Work stopped because the context was cancelled, not because it failed.
    OGLlamaStatusCancelled           = 10,
    OGLlamaStatusAllocationFailed    = 11,
} OGLlamaStatus;

#pragma mark - Handles

typedef struct OGLlamaModel   OGLlamaModel;
typedef struct OGLlamaContext OGLlamaContext;
typedef struct OGLlamaSampler OGLlamaSampler;

#pragma mark - Runtime lifecycle

/// The engine revision this binary was built from — the `commit` in Vendor/LlamaCpp/REVISION,
/// compiled in at build time. Diagnostics report this rather than a number typed into Swift,
/// so a stale framework cannot claim to be the pinned one.
const char *og_llama_engine_revision(void);

/// The release tag that revision belongs to (e.g. "v0.3.0").
const char *og_llama_engine_tag(void);

/// Idempotent. Initializes the ggml backends and silences the engine's stderr logging (see
/// `og_llama_set_logging_enabled`). Safe to call from any thread; internally serialized.
void og_llama_runtime_init(void);

/// Releases process-wide engine state. Only meaningful once every model and context is freed.
void og_llama_runtime_shutdown(void);

/// True when this binary was built with the Metal backend compiled in. It says nothing about
/// whether Metal will actually run on the current device — a simulator answers true here and
/// still falls back to CPU.
bool og_llama_metal_compiled_in(void);

/// The engine logs model paths and tensor names to stderr by default. That is device-log egress
/// nobody asked for, so it is off unless a developer turns it on. Off by default.
void og_llama_set_logging_enabled(bool enabled);

#pragma mark - Model lifecycle

typedef enum OGLlamaLoadMode {
    OGLlamaLoadModeAuto      = 0,
    OGLlamaLoadModeMmap      = 1,
    OGLlamaLoadModeMmapMlock = 2,
    OGLlamaLoadModeNone      = 3,
} OGLlamaLoadMode;

typedef struct OGLlamaModelOptions {
    /// Layers to place on the GPU. Negative means all of them.
    int32_t n_gpu_layers;
    OGLlamaLoadMode load_mode;
    /// Load metadata and vocabulary only. Used to inspect a candidate file without paying for
    /// its weights.
    bool vocab_only;
    /// Validate tensor data while loading. Slower; catches a corrupt download.
    bool check_tensors;
} OGLlamaModelOptions;

/// Conservative defaults: all layers on the GPU, mmap, full load, no tensor validation.
OGLlamaModelOptions og_llama_model_options_default(void);

/// Called during load with progress in [0, 1]. Return false to abort the load — that is the
/// only way to cancel a load already in flight, and it makes `og_llama_model_load` return
/// `OGLlamaStatusCancelled`.
typedef bool (*OGLlamaProgressCallback)(float progress, void *user_data);

OGLlamaStatus og_llama_model_load(const char *path,
                                  const OGLlamaModelOptions *options,
                                  OGLlamaProgressCallback progress,
                                  void *progress_user_data,
                                  OGLlamaModel **out_model);

void og_llama_model_free(OGLlamaModel *model);

#pragma mark - Model metadata

int64_t og_llama_model_parameter_count(const OGLlamaModel *model);
int64_t og_llama_model_size_bytes(const OGLlamaModel *model);
/// Context length the model was trained for. The runtime clamps to this, never above it.
int32_t og_llama_model_train_context_length(const OGLlamaModel *model);
int32_t og_llama_model_vocabulary_size(const OGLlamaModel *model);
bool    og_llama_model_has_decoder(const OGLlamaModel *model);

/// Free-form description ("llama 8B Q4_K - Medium"). Returns bytes written, or the negative
/// count needed when `capacity` is too small.
int32_t og_llama_model_description(const OGLlamaModel *model, char *buffer, int32_t capacity);

/// Number of GGUF key/value metadata entries.
int32_t og_llama_model_metadata_count(const OGLlamaModel *model);
/// Metadata key at `index`. Returns bytes written, or the negative count needed.
int32_t og_llama_model_metadata_key_at(const OGLlamaModel *model, int32_t index,
                                       char *buffer, int32_t capacity);
/// Value for `key`. Returns bytes written, the negative count needed, or `OG_LLAMA_NOT_FOUND`
/// when the key is absent — callers must treat absent as absent, never as an empty string.
int32_t og_llama_model_metadata_value(const OGLlamaModel *model, const char *key,
                                      char *buffer, int32_t capacity);

/// The chat template embedded in the model, by GGUF template name (`name` may be NULL for the
/// default). Returns bytes written, the negative count needed, or `OG_LLAMA_NOT_FOUND` when the
/// model carries none. Plan DZ treats the embedded template as authoritative, so this is the
/// load-time gate: no template, no chat.
int32_t og_llama_model_chat_template(const OGLlamaModel *model, const char *name,
                                     char *buffer, int32_t capacity);

#pragma mark - Vocabulary and tokenization

OGLlamaToken og_llama_token_bos(const OGLlamaModel *model);
OGLlamaToken og_llama_token_eos(const OGLlamaModel *model);
OGLlamaToken og_llama_token_eot(const OGLlamaModel *model);
/// End-of-generation: EOS, EOT, or any other terminator this vocabulary defines. Generation
/// stops on this, not on EOS alone.
bool og_llama_token_is_eog(const OGLlamaModel *model, OGLlamaToken token);
bool og_llama_vocab_adds_bos(const OGLlamaModel *model);

/// Tokenizes `text` (`length` bytes, not NUL-terminated). Returns the token count written, or
/// the negative count needed when `capacity` is too small.
int32_t og_llama_tokenize(const OGLlamaModel *model,
                          const char *text, int32_t length,
                          bool add_special, bool parse_special,
                          OGLlamaToken *tokens, int32_t capacity);

/// One token's bytes. These are bytes, not characters: a token can end mid-UTF-8, which is why
/// the caller accumulates before decoding a string.
int32_t og_llama_token_to_piece(const OGLlamaModel *model, OGLlamaToken token,
                                char *buffer, int32_t capacity, bool render_special);

int32_t og_llama_detokenize(const OGLlamaModel *model,
                            const OGLlamaToken *tokens, int32_t token_count,
                            char *buffer, int32_t capacity,
                            bool remove_special, bool render_special);

#pragma mark - Chat template application

typedef struct OGLlamaChatMessage {
    const char *role;     ///< NUL-terminated, e.g. "system", "user", "assistant".
    const char *content;  ///< NUL-terminated.
} OGLlamaChatMessage;

/// Renders `messages` through `template_text`. Returns bytes written, or the negative count
/// needed when `capacity` is too small. `add_assistant` appends the assistant turn's opening
/// tokens, which is what you want for generation and not what you want for measurement.
int32_t og_llama_chat_apply_template(const char *template_text,
                                     const OGLlamaChatMessage *messages, size_t message_count,
                                     bool add_assistant,
                                     char *buffer, int32_t capacity);

#pragma mark - Context lifecycle

typedef struct OGLlamaContextOptions {
    /// 0 means "take the model's trained length".
    uint32_t n_ctx;
    /// Logical batch: the largest token count a single decode call may carry.
    uint32_t n_batch;
    /// Physical batch: the largest chunk the backend processes at once.
    uint32_t n_ubatch;
    int32_t  n_threads;
    int32_t  n_threads_batch;
    /// Keep the KV cache on the GPU. Off trades speed for headroom on a memory-tight device.
    bool     offload_kqv;
    /// Flash attention: -1 auto, 0 off, 1 on.
    int32_t  flash_attention;
} OGLlamaContextOptions;

OGLlamaContextOptions og_llama_context_options_default(void);

OGLlamaStatus og_llama_context_create(OGLlamaModel *model,
                                      const OGLlamaContextOptions *options,
                                      OGLlamaContext **out_context);

void og_llama_context_free(OGLlamaContext *context);

uint32_t og_llama_context_length(const OGLlamaContext *context);
uint32_t og_llama_context_batch_size(const OGLlamaContext *context);

/// Drops the whole KV cache. Plan DZ's cache policy is full-history-per-request, so this runs
/// before every generation; prefix reuse is not on the table until a prefix diff can prove it.
void og_llama_context_clear_memory(OGLlamaContext *context);

#pragma mark - Cancellation

/// Cancellation is a flag on the context, not a callback Swift has to vend. Setting it makes an
/// in-flight `og_llama_decode` abort at the next ggml graph boundary and return
/// `OGLlamaStatusCancelled`, and makes every subsequent decode/sample refuse immediately until
/// it is cleared.
void og_llama_context_set_cancelled(OGLlamaContext *context, bool cancelled);
bool og_llama_context_is_cancelled(const OGLlamaContext *context);

#pragma mark - Decode

/// Decodes `token_count` tokens at positions [`position`, `position` + `token_count`) in
/// sequence 0. The caller partitions the prompt into chunks no larger than
/// `og_llama_context_batch_size` and checks cancellation between chunks.
///
/// `want_logits_for_last` requests logits for the final token only — the sampler needs them for
/// the token it is about to produce, and asking for the whole batch's logits wastes the memory
/// of an entire vocabulary row per token.
OGLlamaStatus og_llama_decode(OGLlamaContext *context,
                              const OGLlamaToken *tokens, int32_t token_count,
                              int32_t position,
                              bool want_logits_for_last);

/// Blocks until every scheduled accelerator command has retired. Required before tearing down a
/// context or model after a cancellation: Metal work outlives the call that queued it, and
/// freeing underneath it is a use-after-free on the GPU's timeline.
void og_llama_context_synchronize(OGLlamaContext *context);

#pragma mark - Sampling

typedef struct OGLlamaSamplerOptions {
    /// Fixed seeds are how generation is made reproducible in tests.
    uint32_t seed;
    /// <= 0 selects greedy decoding and ignores top_k/top_p/min_p.
    float    temperature;
    int32_t  top_k;
    float    top_p;
    float    min_p;
    /// 0 disables the repetition penalty entirely.
    int32_t  penalty_last_n;
    float    penalty_repeat;
    float    penalty_frequency;
    float    penalty_presence;
} OGLlamaSamplerOptions;

OGLlamaSamplerOptions og_llama_sampler_options_default(void);

OGLlamaStatus og_llama_sampler_create(const OGLlamaModel *model,
                                      const OGLlamaSamplerOptions *options,
                                      OGLlamaSampler **out_sampler);

void og_llama_sampler_free(OGLlamaSampler *sampler);

/// Forgets the penalty history without rebuilding the chain.
void og_llama_sampler_reset(OGLlamaSampler *sampler);

/// Samples one token from the logits of the decoded token at `logit_index` (-1 = the last one),
/// and accepts it into the sampler's history. Writes `OGLlamaStatusCancelled` and leaves
/// `*out_token` untouched when the context is cancelled.
OGLlamaStatus og_llama_sampler_sample(OGLlamaSampler *sampler, OGLlamaContext *context,
                                      int32_t logit_index, OGLlamaToken *out_token);

/// Accepts a token the caller chose (a forced prefix, a replayed turn) into the penalty history.
void og_llama_sampler_accept(OGLlamaSampler *sampler, OGLlamaToken token);

#ifdef __cplusplus
}
#endif

#endif /* LLAMA_CPP_WRAPPER_H */
