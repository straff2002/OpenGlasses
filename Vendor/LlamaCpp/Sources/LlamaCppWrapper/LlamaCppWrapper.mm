//
//  LlamaCppWrapper.mm
//  Plan DZ P1 — the C ABI declared in LlamaCppWrapper.h, over the vendored llama.cpp engine.
//
//  Rules this file keeps so its callers do not have to:
//   * No llama.cpp type escapes. The three handles are boxes we own.
//   * No exception crosses the ABI. Every entry point that can allocate is wrapped.
//   * No engine logging reaches the device log unless a developer asked for it.
//   * A NULL handle is answered, not dereferenced. Swift can pass one during teardown.
//
#import "LlamaCppWrapper.h"

#include "llama.h"

#include <atomic>
#include <cstring>
#include <functional>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#pragma mark - Build stamp

// Injected by Scripts/build-llamacpp-framework.sh via OG_LLAMA_ENGINE_* so the binary reports the
// revision it was actually built from. The fallbacks keep a bare `swift build` of the package
// honest about not knowing, rather than asserting a revision it cannot vouch for.
#ifndef OG_LLAMA_ENGINE_REVISION
#define OG_LLAMA_ENGINE_REVISION "unknown"
#endif
#ifndef OG_LLAMA_ENGINE_TAG
#define OG_LLAMA_ENGINE_TAG "unknown"
#endif

#pragma mark - Handles

struct OGLlamaModel {
    llama_model *model = nullptr;
};

struct OGLlamaContext {
    llama_context *context = nullptr;
    std::atomic<bool> cancelled{false};
};

struct OGLlamaSampler {
    llama_sampler *chain = nullptr;
};

#pragma mark - Runtime

namespace {

std::atomic<bool> g_logging_enabled{false};
std::once_flag g_init_once;

void og_log_callback(ggml_log_level level, const char *text, void *user_data) {
    (void)level;
    (void)user_data;
    if (g_logging_enabled.load(std::memory_order_relaxed) && text != nullptr) {
        fputs(text, stderr);
    }
}

/// llama_decode consults this between graph nodes. Note the engine's own caveat: the abort
/// callback is honoured on CPU execution, and a Metal graph already in flight may run to
/// completion before it is seen. Cancellation is therefore prompt between decode calls and
/// best-effort within one — which is why the caller also checks between chunks and tokens.
bool og_abort_callback(void *data) {
    auto *box = static_cast<OGLlamaContext *>(data);
    return box != nullptr && box->cancelled.load(std::memory_order_relaxed);
}

struct ProgressBox {
    OGLlamaProgressCallback callback = nullptr;
    void *user_data = nullptr;
    bool aborted = false;
};

bool og_progress_callback(float progress, void *user_data) {
    auto *box = static_cast<ProgressBox *>(user_data);
    if (box == nullptr || box->callback == nullptr) {
        return true;
    }
    const bool keep_going = box->callback(progress, box->user_data);
    if (!keep_going) {
        box->aborted = true;
    }
    return keep_going;
}

const llama_vocab *vocab_of(const OGLlamaModel *model) {
    if (model == nullptr || model->model == nullptr) {
        return nullptr;
    }
    return llama_model_get_vocab(model->model);
}

/// Normalizes llama.cpp's "wrote this much / needed this much" conventions onto the one this
/// ABI promises: a positive count written, or the negative count needed.
int32_t fit(int32_t needed, int32_t capacity) {
    if (needed < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    return needed > capacity ? -needed : needed;
}

/// The metadata getters null-terminate, so they need one byte more than they report. Staging
/// through a local buffer keeps that off the caller's side of the ABI, where a caller who sized
/// exactly would otherwise lose its last byte.
int32_t copy_terminated(char *buffer, int32_t capacity,
                        const std::function<int32_t(char *, size_t)> &produce) {
    if (capacity < 0 || (capacity > 0 && buffer == nullptr)) {
        return OG_LLAMA_NOT_FOUND;
    }
    std::vector<char> staging;
    try {
        staging.resize(static_cast<size_t>(capacity) + 1);
    } catch (const std::bad_alloc &) {
        return OG_LLAMA_NOT_FOUND;
    }
    const int32_t needed = produce(staging.data(), staging.size());
    if (needed < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    if (needed > capacity) {
        return -needed;
    }
    if (needed > 0) {
        std::memcpy(buffer, staging.data(), static_cast<size_t>(needed));
    }
    return needed;
}

int32_t copy_string(char *buffer, int32_t capacity, const char *value) {
    if (value == nullptr) {
        return OG_LLAMA_NOT_FOUND;
    }
    const size_t length = std::strlen(value);
    if (length > static_cast<size_t>(INT32_MAX)) {
        return OG_LLAMA_NOT_FOUND;
    }
    const int32_t needed = static_cast<int32_t>(length);
    if (needed > capacity) {
        return -needed;
    }
    if (needed > 0) {
        if (buffer == nullptr) {
            return OG_LLAMA_NOT_FOUND;
        }
        std::memcpy(buffer, value, static_cast<size_t>(needed));
    }
    return needed;
}

}  // namespace

const char *og_llama_engine_revision(void) {
    return OG_LLAMA_ENGINE_REVISION;
}

const char *og_llama_engine_tag(void) {
    return OG_LLAMA_ENGINE_TAG;
}

void og_llama_runtime_init(void) {
    std::call_once(g_init_once, [] {
        llama_log_set(og_log_callback, nullptr);
        llama_backend_init();
    });
}

void og_llama_runtime_shutdown(void) {
    llama_backend_free();
}

bool og_llama_metal_compiled_in(void) {
#ifdef GGML_USE_METAL
    return true;
#else
    // The framework is built with GGML_METAL=ON, but that define belongs to ggml's own
    // translation units, not this one. Ask the registry instead of guessing from a macro that
    // is not in scope here.
    return llama_supports_gpu_offload();
#endif
}

void og_llama_set_logging_enabled(bool enabled) {
    g_logging_enabled.store(enabled, std::memory_order_relaxed);
}

#pragma mark - Model

OGLlamaModelOptions og_llama_model_options_default(void) {
    OGLlamaModelOptions options{};
    options.n_gpu_layers = -1;  // all layers; the caller clamps for headroom, not this ABI
    options.load_mode = OGLlamaLoadModeMmap;
    options.vocab_only = false;
    options.check_tensors = false;
    return options;
}

OGLlamaStatus og_llama_model_load(const char *path,
                                  const OGLlamaModelOptions *options,
                                  OGLlamaProgressCallback progress,
                                  void *progress_user_data,
                                  OGLlamaModel **out_model) {
    if (path == nullptr || out_model == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_model = nullptr;
    og_llama_runtime_init();

    const OGLlamaModelOptions resolved = (options != nullptr) ? *options : og_llama_model_options_default();

    llama_model_params params = llama_model_default_params();
    params.n_gpu_layers = resolved.n_gpu_layers;
    params.vocab_only = resolved.vocab_only;
    params.check_tensors = resolved.check_tensors;
    switch (resolved.load_mode) {
        case OGLlamaLoadModeMmap:      params.load_mode = LLAMA_LOAD_MODE_MMAP; break;
        case OGLlamaLoadModeMmapMlock: params.load_mode = LLAMA_LOAD_MODE_MMAP_MLOCK; break;
        case OGLlamaLoadModeNone:      params.load_mode = LLAMA_LOAD_MODE_NONE; break;
        case OGLlamaLoadModeAuto:
        default:                       params.load_mode = LLAMA_LOAD_MODE_AUTO; break;
    }

    ProgressBox box;
    box.callback = progress;
    box.user_data = progress_user_data;
    if (progress != nullptr) {
        params.progress_callback = og_progress_callback;
        params.progress_callback_user_data = &box;
    }

    llama_model *model = llama_model_load_from_file(path, params);
    if (model == nullptr) {
        // A load the caller stopped is not a load that failed, and the difference is the whole
        // of whether the UI apologises or not.
        return box.aborted ? OGLlamaStatusCancelled : OGLlamaStatusModelLoadFailed;
    }

    auto *handle = new (std::nothrow) OGLlamaModel();
    if (handle == nullptr) {
        llama_model_free(model);
        return OGLlamaStatusAllocationFailed;
    }
    handle->model = model;
    *out_model = handle;
    return OGLlamaStatusOK;
}

void og_llama_model_free(OGLlamaModel *model) {
    if (model == nullptr) {
        return;
    }
    if (model->model != nullptr) {
        llama_model_free(model->model);
        model->model = nullptr;
    }
    delete model;
}

#pragma mark - Model metadata

int64_t og_llama_model_parameter_count(const OGLlamaModel *model) {
    if (model == nullptr || model->model == nullptr) {
        return 0;
    }
    return static_cast<int64_t>(llama_model_n_params(model->model));
}

int64_t og_llama_model_size_bytes(const OGLlamaModel *model) {
    if (model == nullptr || model->model == nullptr) {
        return 0;
    }
    return static_cast<int64_t>(llama_model_size(model->model));
}

int32_t og_llama_model_train_context_length(const OGLlamaModel *model) {
    if (model == nullptr || model->model == nullptr) {
        return 0;
    }
    return llama_model_n_ctx_train(model->model);
}

int32_t og_llama_model_vocabulary_size(const OGLlamaModel *model) {
    const llama_vocab *vocab = vocab_of(model);
    return vocab == nullptr ? 0 : llama_vocab_n_tokens(vocab);
}

bool og_llama_model_has_decoder(const OGLlamaModel *model) {
    if (model == nullptr || model->model == nullptr) {
        return false;
    }
    return llama_model_has_decoder(model->model);
}

int32_t og_llama_model_description(const OGLlamaModel *model, char *buffer, int32_t capacity) {
    if (model == nullptr || model->model == nullptr) {
        return OG_LLAMA_NOT_FOUND;
    }
    llama_model *raw = model->model;
    return copy_terminated(buffer, capacity, [raw](char *staging, size_t size) {
        return llama_model_desc(raw, staging, size);
    });
}

int32_t og_llama_model_metadata_count(const OGLlamaModel *model) {
    if (model == nullptr || model->model == nullptr) {
        return 0;
    }
    return llama_model_meta_count(model->model);
}

int32_t og_llama_model_metadata_key_at(const OGLlamaModel *model, int32_t index,
                                       char *buffer, int32_t capacity) {
    if (model == nullptr || model->model == nullptr || index < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    llama_model *raw = model->model;
    return copy_terminated(buffer, capacity, [raw, index](char *staging, size_t size) {
        return llama_model_meta_key_by_index(raw, index, staging, size);
    });
}

int32_t og_llama_model_metadata_value(const OGLlamaModel *model, const char *key,
                                      char *buffer, int32_t capacity) {
    if (model == nullptr || model->model == nullptr || key == nullptr) {
        return OG_LLAMA_NOT_FOUND;
    }
    llama_model *raw = model->model;
    return copy_terminated(buffer, capacity, [raw, key](char *staging, size_t size) {
        return llama_model_meta_val_str(raw, key, staging, size);
    });
}

int32_t og_llama_model_chat_template(const OGLlamaModel *model, const char *name,
                                     char *buffer, int32_t capacity) {
    if (model == nullptr || model->model == nullptr) {
        return OG_LLAMA_NOT_FOUND;
    }
    return copy_string(buffer, capacity, llama_model_chat_template(model->model, name));
}

#pragma mark - Vocabulary and tokenization

OGLlamaToken og_llama_token_bos(const OGLlamaModel *model) {
    const llama_vocab *vocab = vocab_of(model);
    return vocab == nullptr ? -1 : llama_vocab_bos(vocab);
}

OGLlamaToken og_llama_token_eos(const OGLlamaModel *model) {
    const llama_vocab *vocab = vocab_of(model);
    return vocab == nullptr ? -1 : llama_vocab_eos(vocab);
}

OGLlamaToken og_llama_token_eot(const OGLlamaModel *model) {
    const llama_vocab *vocab = vocab_of(model);
    return vocab == nullptr ? -1 : llama_vocab_eot(vocab);
}

bool og_llama_token_is_eog(const OGLlamaModel *model, OGLlamaToken token) {
    const llama_vocab *vocab = vocab_of(model);
    return vocab != nullptr && llama_vocab_is_eog(vocab, token);
}

bool og_llama_vocab_adds_bos(const OGLlamaModel *model) {
    const llama_vocab *vocab = vocab_of(model);
    return vocab != nullptr && llama_vocab_get_add_bos(vocab);
}

int32_t og_llama_tokenize(const OGLlamaModel *model,
                          const char *text, int32_t length,
                          bool add_special, bool parse_special,
                          OGLlamaToken *tokens, int32_t capacity) {
    const llama_vocab *vocab = vocab_of(model);
    if (vocab == nullptr || length < 0 || (length > 0 && text == nullptr) || capacity < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    // llama_tokenize already returns the negative count needed when the buffer is short, which
    // is the convention this ABI exports, so it is passed through rather than reinterpreted.
    return llama_tokenize(vocab, text, length, tokens, capacity, add_special, parse_special);
}

int32_t og_llama_token_to_piece(const OGLlamaModel *model, OGLlamaToken token,
                                char *buffer, int32_t capacity, bool render_special) {
    const llama_vocab *vocab = vocab_of(model);
    if (vocab == nullptr || capacity < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    return llama_token_to_piece(vocab, token, buffer, capacity, /*lstrip=*/0, render_special);
}

int32_t og_llama_detokenize(const OGLlamaModel *model,
                            const OGLlamaToken *tokens, int32_t token_count,
                            char *buffer, int32_t capacity,
                            bool remove_special, bool render_special) {
    const llama_vocab *vocab = vocab_of(model);
    if (vocab == nullptr || token_count < 0 || (token_count > 0 && tokens == nullptr) || capacity < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    return llama_detokenize(vocab, tokens, token_count, buffer, capacity,
                            remove_special, render_special);
}

#pragma mark - Chat template

int32_t og_llama_chat_apply_template(const char *template_text,
                                     const OGLlamaChatMessage *messages, size_t message_count,
                                     bool add_assistant,
                                     char *buffer, int32_t capacity) {
    if (template_text == nullptr || capacity < 0) {
        return OG_LLAMA_NOT_FOUND;
    }
    if (message_count > 0 && messages == nullptr) {
        return OG_LLAMA_NOT_FOUND;
    }
    std::vector<llama_chat_message> chat;
    try {
        chat.reserve(message_count);
    } catch (const std::bad_alloc &) {
        return OG_LLAMA_NOT_FOUND;
    }
    for (size_t i = 0; i < message_count; ++i) {
        if (messages[i].role == nullptr || messages[i].content == nullptr) {
            return OG_LLAMA_NOT_FOUND;
        }
        chat.push_back(llama_chat_message{messages[i].role, messages[i].content});
    }
    const int32_t needed = llama_chat_apply_template(template_text, chat.data(), chat.size(),
                                                     add_assistant, buffer, capacity);
    return fit(needed, capacity);
}

#pragma mark - Context

OGLlamaContextOptions og_llama_context_options_default(void) {
    const llama_context_params defaults = llama_context_default_params();
    OGLlamaContextOptions options{};
    options.n_ctx = 0;  // 0 = the model's trained length, clamped by the caller's policy
    options.n_batch = defaults.n_batch;
    options.n_ubatch = defaults.n_ubatch;
    options.n_threads = defaults.n_threads;
    options.n_threads_batch = defaults.n_threads_batch;
    options.offload_kqv = defaults.offload_kqv;
    options.flash_attention = -1;  // auto
    return options;
}

OGLlamaStatus og_llama_context_create(OGLlamaModel *model,
                                      const OGLlamaContextOptions *options,
                                      OGLlamaContext **out_context) {
    if (model == nullptr || model->model == nullptr || out_context == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_context = nullptr;
    og_llama_runtime_init();

    const OGLlamaContextOptions resolved =
        (options != nullptr) ? *options : og_llama_context_options_default();

    llama_context_params params = llama_context_default_params();
    params.n_ctx = resolved.n_ctx;
    if (resolved.n_batch > 0) {
        params.n_batch = resolved.n_batch;
    }
    if (resolved.n_ubatch > 0) {
        params.n_ubatch = resolved.n_ubatch;
    }
    if (resolved.n_threads > 0) {
        params.n_threads = resolved.n_threads;
    }
    if (resolved.n_threads_batch > 0) {
        params.n_threads_batch = resolved.n_threads_batch;
    }
    params.offload_kqv = resolved.offload_kqv;
    switch (resolved.flash_attention) {
        case 0:  params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED; break;
        case 1:  params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED; break;
        default: params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO; break;
    }
    params.no_perf = true;

    auto *handle = new (std::nothrow) OGLlamaContext();
    if (handle == nullptr) {
        return OGLlamaStatusAllocationFailed;
    }
    // The abort callback has to be installed with the params: the box it reads is the handle we
    // just made, and wiring it afterwards leaves a window where a decode cannot be cancelled.
    params.abort_callback = og_abort_callback;
    params.abort_callback_data = handle;

    llama_context *context = llama_init_from_model(model->model, params);
    if (context == nullptr) {
        delete handle;
        return OGLlamaStatusContextCreateFailed;
    }
    handle->context = context;
    *out_context = handle;
    return OGLlamaStatusOK;
}

void og_llama_context_free(OGLlamaContext *context) {
    if (context == nullptr) {
        return;
    }
    if (context->context != nullptr) {
        // Anything still queued on the GPU holds pointers into this context. Retiring it before
        // the free is the difference between an orderly teardown and a GPU-side use-after-free.
        llama_synchronize(context->context);
        llama_free(context->context);
        context->context = nullptr;
    }
    delete context;
}

uint32_t og_llama_context_length(const OGLlamaContext *context) {
    if (context == nullptr || context->context == nullptr) {
        return 0;
    }
    return llama_n_ctx(context->context);
}

uint32_t og_llama_context_batch_size(const OGLlamaContext *context) {
    if (context == nullptr || context->context == nullptr) {
        return 0;
    }
    return llama_n_batch(context->context);
}

void og_llama_context_clear_memory(OGLlamaContext *context) {
    if (context == nullptr || context->context == nullptr) {
        return;
    }
    llama_memory_clear(llama_get_memory(context->context), /*data=*/true);
}

void og_llama_context_set_cancelled(OGLlamaContext *context, bool cancelled) {
    if (context == nullptr) {
        return;
    }
    context->cancelled.store(cancelled, std::memory_order_relaxed);
}

bool og_llama_context_is_cancelled(const OGLlamaContext *context) {
    return context != nullptr && context->cancelled.load(std::memory_order_relaxed);
}

void og_llama_context_synchronize(OGLlamaContext *context) {
    if (context == nullptr || context->context == nullptr) {
        return;
    }
    llama_synchronize(context->context);
}

#pragma mark - Decode

OGLlamaStatus og_llama_decode(OGLlamaContext *context,
                              const OGLlamaToken *tokens, int32_t token_count,
                              int32_t position,
                              bool want_logits_for_last) {
    if (context == nullptr || context->context == nullptr || tokens == nullptr ||
        token_count <= 0 || position < 0) {
        return OGLlamaStatusInvalidArgument;
    }
    if (context->cancelled.load(std::memory_order_relaxed)) {
        return OGLlamaStatusCancelled;
    }
    if (static_cast<uint32_t>(token_count) > llama_n_batch(context->context)) {
        // Partitioning is the caller's job (Plan DZ invariant 7); submitting an oversized batch
        // here would be the runtime silently doing the thing the plan forbids.
        return OGLlamaStatusInvalidArgument;
    }

    llama_batch batch = llama_batch_init(token_count, /*embd=*/0, /*n_seq_max=*/1);
    if (batch.token == nullptr) {
        return OGLlamaStatusAllocationFailed;
    }
    batch.n_tokens = token_count;
    for (int32_t i = 0; i < token_count; ++i) {
        batch.token[i] = tokens[i];
        batch.pos[i] = position + i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = (want_logits_for_last && i == token_count - 1) ? 1 : 0;
    }

    const int32_t result = llama_decode(context->context, batch);
    llama_batch_free(batch);

    if (result == 0) {
        return OGLlamaStatusOK;
    }
    if (context->cancelled.load(std::memory_order_relaxed)) {
        return OGLlamaStatusCancelled;
    }
    switch (result) {
        case 1:  return OGLlamaStatusContextExhausted;  // no KV slot for this batch
        case 2:  return OGLlamaStatusCancelled;         // aborted via the abort callback
        case -1: return OGLlamaStatusInvalidArgument;
        default: return OGLlamaStatusDecodeFailed;
    }
}

#pragma mark - Sampling

OGLlamaSamplerOptions og_llama_sampler_options_default(void) {
    OGLlamaSamplerOptions options{};
    options.seed = LLAMA_DEFAULT_SEED;
    options.temperature = 0.7f;
    options.top_k = 40;
    options.top_p = 0.95f;
    options.min_p = 0.05f;
    options.penalty_last_n = 64;
    options.penalty_repeat = 1.1f;
    options.penalty_frequency = 0.0f;
    options.penalty_presence = 0.0f;
    return options;
}

OGLlamaStatus og_llama_sampler_create(const OGLlamaModel *model,
                                      const OGLlamaSamplerOptions *options,
                                      OGLlamaSampler **out_sampler) {
    if (out_sampler == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_sampler = nullptr;
    const llama_vocab *vocab = vocab_of(model);
    if (vocab == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }

    const OGLlamaSamplerOptions resolved =
        (options != nullptr) ? *options : og_llama_sampler_options_default();

    llama_sampler_chain_params chain_params = llama_sampler_chain_default_params();
    chain_params.no_perf = true;
    llama_sampler *chain = llama_sampler_chain_init(chain_params);
    if (chain == nullptr) {
        return OGLlamaStatusSamplerCreateFailed;
    }

    // Penalties first: they rewrite the distribution, and the truncating samplers below should
    // see the penalised one. Then narrow (top-k, top-p, min-p), then temperature, then draw.
    if (resolved.penalty_last_n != 0) {
        llama_sampler_chain_add(chain,
            llama_sampler_init_penalties(llama_vocab_n_tokens(vocab),
                                         resolved.penalty_last_n,
                                         resolved.penalty_repeat,
                                         resolved.penalty_frequency,
                                         resolved.penalty_presence));
    }
    if (resolved.temperature <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    } else {
        if (resolved.top_k > 0) {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(resolved.top_k));
        }
        if (resolved.top_p > 0.0f && resolved.top_p < 1.0f) {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(resolved.top_p, /*min_keep=*/1));
        }
        if (resolved.min_p > 0.0f) {
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(resolved.min_p, /*min_keep=*/1));
        }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(resolved.temperature));
        llama_sampler_chain_add(chain, llama_sampler_init_dist(resolved.seed));
    }

    auto *handle = new (std::nothrow) OGLlamaSampler();
    if (handle == nullptr) {
        llama_sampler_free(chain);
        return OGLlamaStatusAllocationFailed;
    }
    handle->chain = chain;
    *out_sampler = handle;
    return OGLlamaStatusOK;
}

void og_llama_sampler_free(OGLlamaSampler *sampler) {
    if (sampler == nullptr) {
        return;
    }
    if (sampler->chain != nullptr) {
        llama_sampler_free(sampler->chain);
        sampler->chain = nullptr;
    }
    delete sampler;
}

void og_llama_sampler_reset(OGLlamaSampler *sampler) {
    if (sampler == nullptr || sampler->chain == nullptr) {
        return;
    }
    llama_sampler_reset(sampler->chain);
}

OGLlamaStatus og_llama_sampler_sample(OGLlamaSampler *sampler, OGLlamaContext *context,
                                      int32_t logit_index, OGLlamaToken *out_token) {
    if (sampler == nullptr || sampler->chain == nullptr || context == nullptr ||
        context->context == nullptr || out_token == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    if (context->cancelled.load(std::memory_order_relaxed)) {
        return OGLlamaStatusCancelled;
    }
    // llama_sampler_sample accepts the token into the chain's history itself; accepting again
    // here would double-count it in the repetition penalty.
    *out_token = llama_sampler_sample(sampler->chain, context->context, logit_index);
    return OGLlamaStatusOK;
}

void og_llama_sampler_accept(OGLlamaSampler *sampler, OGLlamaToken token) {
    if (sampler == nullptr || sampler->chain == nullptr) {
        return;
    }
    llama_sampler_accept(sampler->chain, token);
}
