#!/usr/bin/env bash
# Builds the device qualification app for the simulator and runs nothing (Plan MQ P3).
#
#   Scripts/local-model-qualification/check-compiles.sh [derived-data-path]
#
# The app compiles a hand-kept list of production sources (project.yml), so a new type in a listed
# file can break it without breaking the app. Not part of Scripts/check-eval-harnesses.sh: that job
# compiles plain-swiftc Mac harnesses inside a 10-minute budget, and this app links mlx-swift-lm,
# whose cold build alone takes longer. Run it before a change to a listed file is merged, and
# before a phone run. Needs xcodegen. No signing: the simulator build is unsigned.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
derived="${1:-${TMPDIR:-/tmp}/local-model-qualification-check}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
export AVENKIN_SOURCE_COMMIT="${AVENKIN_SOURCE_COMMIT:-$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)}"
xcodegen generate --spec "$here/project.yml" --quiet
nice -n 15 xcodebuild build -project "$here/LocalModelQualification.xcodeproj" -scheme LocalModelQualification \
  -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" -jobs 3 \
  CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO -quiet
echo "local-model-qualification builds"
