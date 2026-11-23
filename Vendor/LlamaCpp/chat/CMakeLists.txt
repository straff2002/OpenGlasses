# The part of llama.cpp's `common/` library the GGUF tool path links (Plan MQ P2, decision 4):
# `common/chat` — each model family's chat template, tool-call grammar and tool-call parser — and
# exactly what it needs to compile and link, built from the same pinned checkout as the engine
# (Scripts/build-llamacpp-framework.sh passes LLAMA_SOURCE_DIR).
#
# Why a list here rather than upstream's `llama-common` target (`LLAMA_BUILD_COMMON=ON`): that
# target also carries the model downloader, the Hugging Face cache, the CLI argument parser and
# cpp-httplib, which is network code. None of it is reachable from chat, so none of it is
# compiled: the set below is chat's link closure, worked out from the objects' undefined symbols
# at the pinned revision (everything it leaves open is defined by libllama or the system). The
# build script then checks the merged archive for network symbols and fails if any appear.
#
# Left out, deliberately: arg, console, debug, download, hf-cache, http, imatrix-loader,
# llguidance, preset, subproc. Adding a source here changes BUILD-INFO's options fingerprint.
cmake_minimum_required(VERSION 3.14...3.28)
project(og-llama-chat CXX)

if(NOT LLAMA_SOURCE_DIR OR NOT EXISTS "${LLAMA_SOURCE_DIR}/common/chat.cpp")
    message(FATAL_ERROR "LLAMA_SOURCE_DIR must name the pinned llama.cpp checkout")
endif()
if(NOT OG_LLAMA_COMMIT)
    message(FATAL_ERROR "OG_LLAMA_COMMIT must name the pinned commit")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(OG_LLAMA_CHAT_SOURCES
    chat.cpp
    chat-auto-parser-generator.cpp
    chat-auto-parser-helpers.cpp
    chat-diff-analyzer.cpp
    chat-peg-parser.cpp
    common.cpp
    fit.cpp
    jinja/caps.cpp
    jinja/lexer.cpp
    jinja/parser.cpp
    jinja/runtime.cpp
    jinja/string.cpp
    jinja/value.cpp
    json-schema-to-grammar.cpp
    json.cpp
    log.cpp
    ngram-cache.cpp
    ngram-map.cpp
    ngram-mod.cpp
    peg-parser.cpp
    reasoning-budget.cpp
    sampling.cpp
    speculative.cpp
    trie.cpp
    unicode.cpp
)
list(TRANSFORM OG_LLAMA_CHAT_SOURCES PREPEND "${LLAMA_SOURCE_DIR}/common/")

# common.cpp reports a build number and commit. Upstream asks git for them at configure time;
# fixed values from REVISION keep the bytes independent of the checkout's history and the machine.
set(LLAMA_BUILD_NUMBER 0)
set(LLAMA_BUILD_COMMIT "${OG_LLAMA_COMMIT}")
set(BUILD_COMPILER "clang")
set(BUILD_TARGET "ios")
configure_file("${LLAMA_SOURCE_DIR}/common/build-info.cpp.in"
               "${CMAKE_CURRENT_BINARY_DIR}/build-info.cpp" @ONLY)

add_library(llama-chat STATIC ${OG_LLAMA_CHAT_SOURCES} "${CMAKE_CURRENT_BINARY_DIR}/build-info.cpp")
target_include_directories(llama-chat PRIVATE
    "${LLAMA_SOURCE_DIR}/common"
    "${LLAMA_SOURCE_DIR}/include"
    "${LLAMA_SOURCE_DIR}/ggml/include"
    # nlohmann/json, header-only, reached only through common/json.cpp.
    "${LLAMA_SOURCE_DIR}/vendor")
