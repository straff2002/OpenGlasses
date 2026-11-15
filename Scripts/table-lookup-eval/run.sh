#!/bin/bash
# The table lookup scored against a key of cells, on a Mac. See README.md.
#
#   Scripts/table-lookup-eval/run.sh /path/to/vault-folder /path/to/key.jsonl
#   [TABLE_LOOKUP_EVAL_BUILD_DIR=/path/outside/the/repo] [TABLE_LOOKUP_EVAL_LABEL=name]
#   [TABLE_LOOKUP_EVAL_KEY_CHECKED=1] [TABLE_LOOKUP_EVAL_RECOGNISE=off|grid|words]
#   [TABLE_LOOKUP_EVAL_FLOOR=0.5] [TABLE_LOOKUP_EVAL_OUTCOMES=/path/outside/the/repo/outcomes.jsonl]
#   [TABLE_LOOKUP_EVAL_BASELINE=/path/to/an/earlier/outcomes.jsonl]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
src="$root/OpenGlasses/Sources/Services"
build="${TABLE_LOOKUP_EVAL_BUILD_DIR:-${TMPDIR:-/tmp}/table-lookup-eval-build}"
case "$build" in
  "$root"*) echo "TABLE_LOOKUP_EVAL_BUILD_DIR must be outside the repository" >&2; exit 2 ;;
esac
mkdir -p "$build"

# A compile-only check skips optimisation: what it checks is the file list, and -O is minutes slower.
opt=-O; if [ "${EVAL_COMPILE_ONLY:-}" = 1 ]; then opt=-Onone; fi
swiftc "$opt" -parse-as-library -target "$(uname -m)-apple-macos26.0" -o "$build/table-lookup-eval" \
  "$here/main.swift" "$here/Stubs.swift" \
  "$root/OpenGlassesTests/TableLookupEval/TableLookupEvalCore.swift" \
  "$root/OpenGlassesTests/RetrievalEval/EvalIntervals.swift" "$root/OpenGlassesTests/RetrievalEval/EvalOutcomes.swift" \
  "$src/Vault/TableLookup.swift" "$src/Vault/TableReference.swift" "$src/Vault/SpokenNumber.swift" \
  "$src/Vault/LexicalSupport.swift" "$src/Vault/CodeTokenizer.swift" "$src/Vault/CaptionWords.swift" \
  "$src/Vault/TermRule.swift" "$src/Vault/TermRuleStopwords.swift" "$src/Vault/DocumentLanguageProfile.swift" \
  "$src/Vault/AWGSize.swift" "$src/Vault/TableDirectory.swift" \
  "$src/Vault/TableExtractor.swift" "$src/Vault/TableChecks.swift" "$src/Vault/PDFTableReader.swift" \
  "$src/Vault/RecognisedTable.swift" "$src/Vault/CellCertainty.swift" "$src/Vault/PictureRegion.swift" \
  "$src/Vault/PictureTableReading.swift" "$src/Vault/VisionTableReader.swift"

# Scripts/check-eval-harnesses.sh builds every harness this way, to catch a stale file list.
if [ "${EVAL_COMPILE_ONLY:-}" = 1 ]; then exit 0; fi

exec "$build/table-lookup-eval" "$@"
