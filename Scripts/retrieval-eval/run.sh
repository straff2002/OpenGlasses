#!/bin/bash
# The local retrieval eval on a Mac, on the device's embedding model. See README.md.
#
#   RETRIEVAL_EVAL_VAULT=/path/to/vault RETRIEVAL_EVAL_ANSWER_KEY=/path/to/answers.jsonl \
#     [RETRIEVAL_EVAL_WORKDIR=/path/outside/the/repo] [RETRIEVAL_EVAL_EMBEDDER=contextual|eg2[:dim]] \
#     [RETRIEVAL_EVAL_LABEL=name] [RETRIEVAL_EVAL_RECOGNISE=off|grid|words] Scripts/retrieval-eval/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
src="$root/OpenGlasses/Sources/Services"
build="${RETRIEVAL_EVAL_BUILD_DIR:-${TMPDIR:-/tmp}/retrieval-eval-build}"
mkdir -p "$build"

swiftc -O -parse-as-library -D RETRIEVAL_EVAL -target "$(uname -m)-apple-macos26.0" -o "$build/retrieval-eval" \
  "$here/main.swift" "$here/Stubs.swift" "$here/Tuning.swift" \
  "$root/OpenGlassesTests/RetrievalEval/RetrievalEvalCore.swift" \
  "$src/RAG/DocumentStore.swift" "$src/RAG/DocumentReconstructor.swift" "$src/RAG/DocumentChunker.swift" \
  "$src/RAG/Embedder.swift" "$src/RAG/EmbeddingBackend.swift" "$src/RAG/CoreMLEmbeddingBackend.swift" "$here/SearchModel.swift" "$src/RAG/EmbeddingVersion.swift" \
  "$src/RAG/PassageLocation.swift" "$src/RAG/EmbeddingScript.swift" \
  "$src/Vault/VaultRetriever.swift" "$src/Vault/ClauseReference.swift" "$src/Vault/CodeTokenizer.swift" \
  "$src/Vault/LexicalSupport.swift" "$src/Vault/TermRule.swift" "$src/Vault/TermRuleStopwords.swift" \
  "$src/Vault/DocumentLanguageProfile.swift" "$src/Vault/ChunkSizing.swift" "$src/Vault/PageReference.swift" "$src/Vault/DocumentEditions.swift" "$src/Vault/BackOfBookIndex.swift" "$src/Vault/ManualPassageLimit.swift" \
  "$src/Vault/TableExtractor.swift" "$src/Vault/CaptionWords.swift" "$src/Vault/TableChecks.swift" "$src/Vault/TableRowPassage.swift" "$src/Vault/TableReference.swift" \
  "$src/Vault/PDFTableReader.swift" \
  "$src/Vault/RecognisedTable.swift" "$src/Vault/CellCertainty.swift" "$src/Vault/PictureRegion.swift" \
  "$src/Vault/PictureTableReading.swift" "$src/Vault/VisionTableReader.swift"

export RETRIEVAL_EVAL_EXTRACTOR="${RETRIEVAL_EVAL_EXTRACTOR:-$root/Scripts/extract-manual-text.swift}"
exec "$build/retrieval-eval"
