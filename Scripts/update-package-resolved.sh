#!/usr/bin/env bash
# Refresh ci_scripts/Package.resolved — the committed SwiftPM lockfile that
# Xcode Cloud copies into the generated .xcodeproj (it won't resolve packages
# itself). Run this whenever you add, remove, or bump an SPM dependency, then
# commit the result, so the cloud build keeps a complete, in-sync resolved file.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="OpenGlasses.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [[ ! -f "$SRC" ]]; then
  echo "No resolved file at $SRC." >&2
  echo "Generate + resolve first:" >&2
  echo "  ./Scripts/generate-xcodeproj.sh" >&2
  echo "  xcodebuild -resolvePackageDependencies -project OpenGlasses.xcodeproj -scheme OpenGlasses" >&2
  exit 1
fi

cp "$SRC" ci_scripts/Package.resolved
echo "Updated ci_scripts/Package.resolved ($(grep -c '"identity"' ci_scripts/Package.resolved) pins). Commit it."
