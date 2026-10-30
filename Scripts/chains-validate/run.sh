#!/bin/bash
# A vault's chains.md checked against the tables its own PDFs print, on a Mac. See README.md.
#
#   Scripts/chains-validate/run.sh /path/to/vault-folder [/path/to/chains.md]
#   [CHAINS_VALIDATE_BUILD_DIR=/path/outside/the/repo] [CHAINS_VALIDATE_NAMES=0]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
src="$root/OpenGlasses/Sources/Services"
build="${CHAINS_VALIDATE_BUILD_DIR:-${TMPDIR:-/tmp}/chains-validate-build}"
case "$build" in
  "$root"*) echo "CHAINS_VALIDATE_BUILD_DIR must be outside the repository" >&2; exit 2 ;;
esac
mkdir -p "$build"

swiftc -O -parse-as-library -target "$(uname -m)-apple-macos26.0" -o "$build/chains-validate" \
  "$here/main.swift" "$here/Stubs.swift" \
  "$root/OpenGlassesTests/ChainsValidate/ChainsValidateCore.swift" \
  "$src/Vault/ChainDefinition.swift" "$src/Vault/TableLookup.swift" "$src/Vault/TableReference.swift" \
  "$src/Vault/TableExtractor.swift" "$src/Vault/TableChecks.swift" "$src/Vault/PDFTableReader.swift" \
  "$src/Vault/RecognisedTable.swift" "$src/Vault/CellCertainty.swift" "$src/Vault/PictureRegion.swift" \
  "$src/Vault/PictureTableReading.swift" "$src/Vault/VisionTableReader.swift" "$src/Vault/LexicalSupport.swift" \
  "$src/Vault/TermRule.swift" "$src/Vault/AWGSize.swift" "$src/Vault/TableDirectory.swift" \
  "$src/Vault/CaptionWords.swift" "$src/Vault/CodeTokenizer.swift" "$src/Vault/TermRuleStopwords.swift" "$src/Vault/DocumentLanguageProfile.swift" \
  "$src/NativeTools/ArithmeticExpression.swift" "$src/NativeTools/UnitConversionTool.swift"

exec "$build/chains-validate" "$@"
