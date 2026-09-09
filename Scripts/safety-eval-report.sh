#!/usr/bin/env bash
#
# Run the safety-evaluation gate locally and print its Markdown summary (W08.4).
#
# The same selection CI runs — OpenGlassesTests/SafetyEvalGateTests over the versioned corpus in
# OpenGlassesTests/Fixtures/SafetyEvalCorpus — so a prompt, schema or routing change can be measured
# before it is pushed rather than after a red pull request.
#
# The gate writes its report to .safety-eval/safety-eval-report.md (gitignored) whether it passes or
# fails; this prints that file. The thresholds it enforces are PROPOSED, not approved: a green run
# means no regression against a corpus of synthetic cases, and nothing more.
#
# Usage:
#   Scripts/safety-eval-report.sh                  # run the gate, then print the report
#   Scripts/safety-eval-report.sh --report-only    # print the last report without running anything
#
# Environment:
#   SAFETY_EVAL_DESTINATION   xcodebuild -destination (default: a booted iPhone simulator)
#   SAFETY_EVAL_DERIVED_DATA  -derivedDataPath (default: .safety-eval/DerivedData)
#   SAFETY_EVAL_UPDATE_DIGESTS=1  re-record prompt-digests.json after a corpus_version bump

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$REPO_ROOT/.safety-eval/safety-eval-report.md"

print_report() {
  if [[ -f "$REPORT" ]]; then
    echo
    cat "$REPORT"
  else
    echo "No report at $REPORT — the gate did not get far enough to write one." >&2
    return 1
  fi
}

if [[ "${1:-}" == "--report-only" ]]; then
  print_report
  exit $?
fi

cd "$REPO_ROOT"

if [[ ! -d OpenGlasses.xcodeproj ]]; then
  echo "==> Generating OpenGlasses.xcodeproj"
  ./Scripts/generate-xcodeproj.sh
fi

DESTINATION="${SAFETY_EVAL_DESTINATION:-}"
if [[ -z "$DESTINATION" ]]; then
  UDID="$(xcrun simctl list devices booted --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
booted = [d for group in devices.values() for d in group if "iPhone" in d.get("name", "")]
print(booted[0]["udid"] if booted else "")')"
  if [[ -z "$UDID" ]]; then
    echo "No booted iPhone simulator. Boot one, or set SAFETY_EVAL_DESTINATION." >&2
    exit 1
  fi
  DESTINATION="platform=iOS Simulator,id=$UDID"
fi

DERIVED="${SAFETY_EVAL_DERIVED_DATA:-$REPO_ROOT/.safety-eval/DerivedData}"
LOG="$REPO_ROOT/.safety-eval/xcodebuild.log"
mkdir -p "$(dirname "$LOG")"

# SWIFT_EMIT_LOC_STRINGS=NO: a build here must not churn the tracked string catalog.
# TEST_RUNNER_ prefixed variables reach the test process with the prefix stripped.
echo "==> Running the safety-evaluation gate against $DESTINATION"
set +e
env TEST_RUNNER_SAFETY_EVAL_UPDATE_DIGESTS="${SAFETY_EVAL_UPDATE_DIGESTS:-0}" \
  xcodebuild test \
    -project OpenGlasses.xcodeproj \
    -scheme OpenGlasses \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -only-testing:OpenGlassesTests/SafetyEvalGateTests \
    -only-testing:OpenGlassesTests/SafetyEvalHarnessTests \
    -only-testing:OpenGlassesTests/PromptVersionRegistryTests \
    -collect-test-diagnostics never \
    SWIFT_EMIT_LOC_STRINGS=NO \
    >"$LOG" 2>&1
STATUS=$?
set -e

grep -E "Test Case '.*' (passed|failed)|Executed [0-9]+ test|\*\* TEST" "$LOG" || true
print_report || true

if [[ $STATUS -ne 0 ]]; then
  echo
  echo "Gate FAILED (xcodebuild exit $STATUS). Full log: $LOG" >&2
fi
exit $STATUS
