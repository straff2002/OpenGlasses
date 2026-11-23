//
//  LlamaCppHandles.h
//  The boxes behind the C ABI's opaque handles, shared by the wrapper's two implementation files
//  (LlamaCppWrapper.mm, and the chat bridge LlamaCppChat.mm, Plan MQ P2). Private to the package:
//  it is not under include/, so neither Swift nor the app ever sees a llama.cpp type.
//
#ifndef LLAMA_CPP_HANDLES_H
#define LLAMA_CPP_HANDLES_H

#include "llama.h"

#include <atomic>

struct OGLlamaModel {
    llama_model *model = nullptr;
};

struct OGLlamaContext {
    llama_context *context = nullptr;
    std::atomic<bool> cancelled{false};
};

struct OGLlamaSampler {
    llama_sampler *chain = nullptr;
    /// A tool turn's lazy grammar (Plan MQ P2), or null. Kept beside the chain rather than in it:
    /// it is checked against the token the chain chose and applied first only when that token
    /// breaks it, the way llama.cpp's own sampler does, so a turn pays for the grammar over the
    /// whole vocabulary only inside a call.
    llama_sampler *grammar = nullptr;
};

#endif /* LLAMA_CPP_HANDLES_H */
