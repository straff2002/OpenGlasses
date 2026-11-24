//
//  LlamaCppChat.mm
//  Plan MQ P2 — the chat bridge declared in LlamaCppWrapper.h, over llama.cpp's `common/chat`.
//
//  `common/chat` is the engine's maintained per-family tool code: it recognises a model's chat
//  template (Gemma 4, Qwen 3.x and the rest), renders a conversation with its tools the way that
//  family was trained, builds the grammar that constrains a call once one starts and the triggers
//  that start it, and parses a completion back into content and calls. It is C++, so this file is
//  the whole crossing: JSON text in, JSON text out, opaque handles, no exception past the ABI.
//
//  The same rules as LlamaCppWrapper.mm: no llama.cpp type escapes, nothing logs unless a
//  developer asked (common/ has its own logger, silenced here with the engine's), and a NULL
//  handle is answered rather than dereferenced. Status codes carry no message, so no rendered
//  prompt, argument or reply can reach a log through an error.
//
#import "LlamaCppWrapper.h"

#include "LlamaCppHandles.h"
#include "llama.h"
#include "llama-common/chat.h"
#include "llama-common/common.h"
#include "llama-common/log.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

#pragma mark - Handles

struct OGLlamaChatTemplates {
    common_chat_templates_ptr templates;
};

struct OGLlamaChatParser {
    common_chat_parser_params params;
};

namespace {

/// Replaces the sampler's grammar, freeing the old one. Null clears it.
void og_llama_sampler_attach_grammar(OGLlamaSampler *sampler, llama_sampler *grammar) {
    if (sampler->grammar != nullptr) {
        llama_sampler_free(sampler->grammar);
    }
    sampler->grammar = grammar;
}

std::once_flag g_common_log_once;

/// common/'s logger writes to stderr from its own thread, and its warnings quote template text and
/// model output. Off, the same default as the engine's own log callback.
void silence_common_log() {
    std::call_once(g_common_log_once, [] { common_log_set_verbosity_thold(-1); });
}

/// A heap copy the caller frees with `og_llama_string_free`.
OGLlamaStatus hand_over(const std::string &text, char **out) {
    char *copy = static_cast<char *>(std::malloc(text.size() + 1));
    if (copy == nullptr) {
        return OGLlamaStatusAllocationFailed;
    }
    std::memcpy(copy, text.data(), text.size());
    copy[text.size()] = '\0';
    *out = copy;
    return OGLlamaStatusOK;
}

common_chat_tool_choice tool_choice_named(const std::string &name) {
    if (name == "required") return COMMON_CHAT_TOOL_CHOICE_REQUIRED;
    if (name == "none") return COMMON_CHAT_TOOL_CHOICE_NONE;
    return COMMON_CHAT_TOOL_CHOICE_AUTO;
}

common_json message_json(const common_chat_msg &msg) {
    common_json out = common_json::object();
    out["content"] = msg.content;
    out["reasoning_content"] = msg.reasoning_content;
    common_json calls = common_json::array();
    for (const auto &call : msg.tool_calls) {
        common_json entry = common_json::object();
        entry["name"] = call.name;
        entry["arguments"] = call.arguments;
        entry["id"] = call.id;
        calls.push_back(entry);
    }
    out["tool_calls"] = calls;
    return out;
}

/// A request's inputs, as `common_chat_templates_apply` takes them. Throws on malformed JSON.
common_chat_templates_inputs inputs_from_request(const common_json &request) {
    common_chat_templates_inputs inputs;
    inputs.messages = common_chat_msgs_parse_oaicompat(request.at("messages"));
    if (request.contains("tools") && request.at("tools").is_array() && !request.at("tools").empty()) {
        inputs.tools = common_chat_tools_parse_oaicompat(request.at("tools"));
    }
    inputs.tool_choice = tool_choice_named(request.value("tool_choice", std::string("auto")));
    inputs.parallel_tool_calls = request.value("parallel_tool_calls", true);
    inputs.enable_thinking = request.value("enable_thinking", false);
    inputs.add_generation_prompt = request.value("add_generation_prompt", true);
    inputs.reasoning_format =
        common_reasoning_format_from_name(request.value("reasoning_format", std::string("auto")));
    inputs.use_jinja = true;
    // A fixed clock makes a render repeatable; the app passes the real time.
    if (request.contains("now")) {
        const auto seconds = request.at("now").get<int64_t>();
        inputs.now = std::chrono::system_clock::time_point(std::chrono::seconds(seconds));
    }
    return inputs;
}

}  // namespace

extern "C" {

void og_llama_string_free(char *string) {
    std::free(string);
}

bool og_llama_runtime_catches_standard_exceptions(void) {
    // Thrown and caught here, as common/ throws and catches its own: a libc++ runtime_error caught
    // as std::exception. False when the image's std::exception typeinfo is not libc++'s.
    try {
        throw std::runtime_error("probe");
    } catch (const std::exception &) {
        return true;
    } catch (...) {
        return false;
    }
}

#pragma mark - Templates

OGLlamaStatus og_llama_chat_templates_from_model(const OGLlamaModel *model,
                                                 OGLlamaChatTemplates **out_templates) {
    if (model == nullptr || out_templates == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_templates = nullptr;
    const llama_model *native = model->model;
    if (native == nullptr || llama_model_chat_template(native, nullptr) == nullptr) {
        // No embedded template: common/ would fall back to ChatML, which is a guess about the
        // model, not its own format. The caller keeps the plain path instead.
        return OGLlamaStatusNoChatTemplate;
    }
    silence_common_log();
    try {
        auto *handle = new OGLlamaChatTemplates();
        handle->templates = common_chat_templates_init(native, "");
        if (!handle->templates) {
            delete handle;
            return OGLlamaStatusTemplateFailed;
        }
        *out_templates = handle;
        return OGLlamaStatusOK;
    } catch (const std::bad_alloc &) {
        return OGLlamaStatusAllocationFailed;
    } catch (...) {
        return OGLlamaStatusTemplateFailed;
    }
}

OGLlamaStatus og_llama_chat_templates_from_source(const char *source,
                                                  const char *bos_token,
                                                  const char *eos_token,
                                                  OGLlamaChatTemplates **out_templates) {
    if (source == nullptr || out_templates == nullptr || source[0] == '\0') {
        return OGLlamaStatusInvalidArgument;
    }
    *out_templates = nullptr;
    silence_common_log();
    try {
        auto *handle = new OGLlamaChatTemplates();
        handle->templates = common_chat_templates_init(nullptr, source,
                                                       bos_token != nullptr ? bos_token : "",
                                                       eos_token != nullptr ? eos_token : "");
        if (!handle->templates) {
            delete handle;
            return OGLlamaStatusTemplateFailed;
        }
        *out_templates = handle;
        return OGLlamaStatusOK;
    } catch (const std::bad_alloc &) {
        return OGLlamaStatusAllocationFailed;
    } catch (...) {
        return OGLlamaStatusTemplateFailed;
    }
}

void og_llama_chat_templates_free(OGLlamaChatTemplates *templates) {
    delete templates;
}

#pragma mark - Render

OGLlamaStatus og_llama_chat_render(const OGLlamaChatTemplates *templates,
                                   const char *request_json,
                                   char **out_json) {
    if (templates == nullptr || !templates->templates || request_json == nullptr || out_json == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_json = nullptr;
    try {
        const common_json request = common_json::parse(request_json);
        const common_chat_templates_inputs inputs = inputs_from_request(request);
        const common_chat_params params = common_chat_templates_apply(templates->templates.get(), inputs);

        common_json out = common_json::object();
        // v1.0.0 keeps the prompt as parts, marking the ones that came from user input; joined
        // here into the one text the backend tokenizes, as before.
        out["prompt"] = params.prompt.str();
        out["format"] = static_cast<int>(params.format);
        out["format_name"] = std::string(common_chat_format_name(params.format));
        out["grammar"] = params.grammar;
        out["grammar_lazy"] = params.grammar_lazy;
        common_json triggers = common_json::array();
        for (const auto &trigger : params.grammar_triggers) {
            common_json entry = common_json::object();
            entry["type"] = static_cast<int>(trigger.type);
            entry["value"] = trigger.value;
            triggers.push_back(entry);
        }
        out["grammar_triggers"] = triggers;
        out["preserved_tokens"] = params.preserved_tokens;
        out["additional_stops"] = params.additional_stops;
        out["generation_prompt"] = params.generation_prompt;
        out["reasoning_format"] = request.value("reasoning_format", std::string("auto"));
        out["supports_thinking"] = params.supports_thinking;
        out["tools_rendered"] = !inputs.tools.empty();
        return hand_over(out.dump(), out_json);
    } catch (const std::bad_alloc &) {
        return OGLlamaStatusAllocationFailed;
    } catch (...) {
        return OGLlamaStatusTemplateFailed;
    }
}

#pragma mark - Parse

OGLlamaStatus og_llama_chat_parser_create(const OGLlamaChatTemplates *templates,
                                          const char *request_json,
                                          OGLlamaChatParser **out_parser) {
    if (templates == nullptr || !templates->templates || request_json == nullptr || out_parser == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_parser = nullptr;
    silence_common_log();
    try {
        // v1.0.0's parser is an in-memory PEG arena with no serialized form, so it is taken from
        // a render of the same request rather than read back from the render's JSON.
        const common_json request = common_json::parse(request_json);
        common_chat_params params = common_chat_templates_apply(templates->templates.get(),
                                                                inputs_from_request(request));
        auto *handle = new OGLlamaChatParser();
        handle->params.format = params.format;
        handle->params.generation_prompt = common_chat_input(params.generation_prompt);
        handle->params.parser = std::move(params.parser);
        *out_parser = handle;
        return OGLlamaStatusOK;
    } catch (const std::bad_alloc &) {
        return OGLlamaStatusAllocationFailed;
    } catch (...) {
        return OGLlamaStatusTemplateFailed;
    }
}

void og_llama_chat_parser_free(OGLlamaChatParser *parser) {
    delete parser;
}

OGLlamaStatus og_llama_chat_parse(const OGLlamaChatParser *parser,
                                  const char *text, int32_t length,
                                  bool partial,
                                  char **out_json) {
    if (parser == nullptr || out_json == nullptr || length < 0 || (length > 0 && text == nullptr)) {
        return OGLlamaStatusInvalidArgument;
    }
    *out_json = nullptr;
    try {
        const common_chat_input input(std::string(text != nullptr ? text : "", static_cast<size_t>(length)));
        const common_chat_msg msg = common_chat_parse(input, partial, parser->params);
        return hand_over(message_json(msg).dump(), out_json);
    } catch (const std::bad_alloc &) {
        return OGLlamaStatusAllocationFailed;
    } catch (...) {
        // Output that does not match the family's format. Never a call: the caller keeps the
        // text, and the app's own output policy decides what of it may be spoken.
        return OGLlamaStatusParseFailed;
    }
}

#pragma mark - Grammar

OGLlamaStatus og_llama_sampler_set_chat_grammar(OGLlamaSampler *sampler,
                                                const OGLlamaModel *model,
                                                const char *render_json) {
    if (sampler == nullptr || model == nullptr || render_json == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    const llama_model *native = model->model;
    if (native == nullptr) {
        return OGLlamaStatusInvalidArgument;
    }
    const llama_vocab *vocab = llama_model_get_vocab(native);
    try {
        const common_json render = common_json::parse(render_json);
        const std::string grammar = render.value("grammar", std::string());
        // Only a lazy grammar: it waits for the family's own call opener and constrains only the
        // call. A grammar over the whole reply (tool_choice "required") is not what a voice turn
        // wants, and would need the generation prompt fed through it first.
        if (grammar.empty() || !render.value("grammar_lazy", false)) {
            og_llama_sampler_attach_grammar(sampler, nullptr);
            return OGLlamaStatusOK;
        }

        std::vector<llama_token> preserved;
        if (render.contains("preserved_tokens")) {
            for (const auto &piece : render.at("preserved_tokens")) {
                const auto ids = common_tokenize(vocab, piece.get<std::string>(), false, true);
                if (ids.size() == 1) {
                    preserved.push_back(ids[0]);
                }
            }
        }

        // The trigger conversion llama.cpp's server and common sampler make: a word that is one
        // preserved token triggers on that token, any other word on its escaped text, a full
        // pattern anchored at both ends.
        std::vector<std::string> patterns;
        std::vector<llama_token> tokens;
        if (render.contains("grammar_triggers")) {
            for (const auto &trigger : render.at("grammar_triggers")) {
                const auto type = static_cast<common_grammar_trigger_type>(trigger.value("type", 0));
                const std::string value = trigger.value("value", std::string());
                switch (type) {
                    case COMMON_GRAMMAR_TRIGGER_TYPE_WORD: {
                        const auto ids = common_tokenize(vocab, value, false, true);
                        if (ids.size() == 1 &&
                            std::find(preserved.begin(), preserved.end(), ids[0]) != preserved.end()) {
                            tokens.push_back(ids[0]);
                        } else {
                            patterns.push_back(regex_escape(value));
                        }
                        break;
                    }
                    case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN:
                        patterns.push_back(value);
                        break;
                    case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN_FULL: {
                        std::string anchored = "^$";
                        if (!value.empty()) {
                            anchored = (value.front() != '^' ? "^" : "") + value + (value.back() != '$' ? "$" : "");
                        }
                        patterns.push_back(anchored);
                        break;
                    }
                    case COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN: {
                        const auto ids = common_tokenize(vocab, value, false, true);
                        if (ids.size() == 1) {
                            tokens.push_back(ids[0]);
                        }
                        break;
                    }
                }
            }
        }
        if (patterns.empty() && tokens.empty()) {
            // A lazy grammar with nothing to wake it would never apply; upstream refuses one.
            og_llama_sampler_attach_grammar(sampler, nullptr);
            return OGLlamaStatusGrammarFailed;
        }
        std::vector<const char *> pattern_pointers;
        pattern_pointers.reserve(patterns.size());
        for (const auto &pattern : patterns) {
            pattern_pointers.push_back(pattern.c_str());
        }
        llama_sampler *lazy = llama_sampler_init_grammar_lazy_patterns(
            vocab, grammar.c_str(), "root",
            pattern_pointers.data(), pattern_pointers.size(),
            tokens.data(), tokens.size());
        if (lazy == nullptr) {
            og_llama_sampler_attach_grammar(sampler, nullptr);
            return OGLlamaStatusGrammarFailed;
        }
        og_llama_sampler_attach_grammar(sampler, lazy);
        return OGLlamaStatusOK;
    } catch (const std::bad_alloc &) {
        return OGLlamaStatusAllocationFailed;
    } catch (...) {
        og_llama_sampler_attach_grammar(sampler, nullptr);
        return OGLlamaStatusGrammarFailed;
    }
}

void og_llama_sampler_clear_grammar(OGLlamaSampler *sampler) {
    if (sampler == nullptr) {
        return;
    }
    og_llama_sampler_attach_grammar(sampler, nullptr);
}

}  // extern "C"
