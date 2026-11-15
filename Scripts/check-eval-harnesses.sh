#!/usr/bin/env bash
# Builds every Mac eval harness (Scripts/<name>/run.sh) with its own swiftc line, and runs none.
#
#   Scripts/check-eval-harnesses.sh [name ...]      default: every Scripts/*/run.sh that calls swiftc
#
# The harnesses compile a hand-kept list of app sources, not the app target, so a new type in a
# listed file breaks them without breaking the app build. This catches that in CI rather than on
# the day someone needs the eval. Each run.sh stops after compiling when EVAL_COMPILE_ONLY=1, and
# builds at -Onone then (the same files, linked; minutes faster than -O); a harness that doesn't
# honour it is refused here rather than run against no data.
#
# A failure prints the compiler's first errors. Usually the fix is the file that declares the
# missing name added to that run.sh's list; when that file imports a package a plain swiftc can't
# link, stub the names the listed sources use in the harness's Stubs.swift instead.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/eval-harness-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ "$#" -gt 0 ]; then
  names=("$@")
else
  names=()
  for script in "$root"/Scripts/*/run.sh; do
    grep -q '^swiftc ' "$script" && names+=("$(basename "$(dirname "$script")")")
  done
fi
[ "${#names[@]}" -gt 0 ] || { echo "no eval harnesses found under Scripts/" >&2; exit 2; }

failed=()
for name in "${names[@]}"; do
  script="$root/Scripts/$name/run.sh"
  [ -f "$script" ] || { echo "no harness at Scripts/$name/run.sh" >&2; exit 2; }
  if ! grep -q 'EVAL_COMPILE_ONLY' "$script"; then
    echo "FAIL $name: run.sh doesn't stop at EVAL_COMPILE_ONLY=1, so it would run" >&2
    failed+=("$name"); continue
  fi
  # Each harness names its build directory <NAME>_BUILD_DIR (retrieval-eval → RETRIEVAL_EVAL_BUILD_DIR).
  var="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')_BUILD_DIR"
  log="$work/$name.log"
  start=$SECONDS
  if env "$var=$work/$name" EVAL_COMPILE_ONLY=1 bash "$script" </dev/null >"$log" 2>&1; then
    echo "ok   $name ($((SECONDS - start)) s)"
  else
    echo "FAIL $name ($((SECONDS - start)) s):" >&2
    grep -E 'error:' "$log" | sed "s#$root/##" | sort -u | head -20 >&2 || tail -20 "$log" >&2
    failed+=("$name")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "${#failed[@]} eval harness(es) don't build: ${failed[*]}" >&2
  exit 1
fi
echo "all ${#names[@]} eval harnesses build"
