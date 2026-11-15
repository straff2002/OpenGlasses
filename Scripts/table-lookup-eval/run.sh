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

swiftc -O -parse-as-library -target "$(uname -m)-apple-macos26.0" -o "$build/table-lookup-eval" \
  "$here/main.swift" "$here/Stubs.swift" \
  "$root/OpenGlassesTests/TableLookupEval/TableLookupEvalCore.swift" \
  "$root/OpenGlassesTests/RetrievalEval/EvalIntervals.swift" "$root/OpenGlassesTests/RetrievalEval/EvalOutcomes.swift" \
  "$src/Vault/TableLookup.swift" "$src/Vault/TableReference.swift" "$src/Vault/LexicalSupport.swift" \
  "$src/Vault/TableExtractor.swift" "$src/Vault/TableChecks.swift" "$src/Vault/PDFTableReader.swift" \
  "$src/Vault/RecognisedTable.swift" "$src/Vault/CellCertainty.swift" "$src/Vault/PictureRegion.swift" \
  "$src/Vault/PictureTableReading.swift" "$src/Vault/VisionTableReader.swift"

exec "$build/table-lookup-eval" "$@"
