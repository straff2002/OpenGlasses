#!/bin/sh
set -eu
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

if ! command -v xcodegen >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  brew install xcodegen
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen required to generate OpenGlasses.xcodeproj" >&2
  exit 1
fi
./Scripts/generate-xcodeproj.sh

# The .xcodeproj is generated (and gitignored), so no Package.resolved is committed
# at its path. Xcode Cloud runs the build/archive action with automatic package
# resolution disabled and fails unless a resolved file already exists there. Resolve
# explicitly here (post-clone has network) so the file is in place before the build.
xcodebuild -resolvePackageDependencies \
  -project OpenGlasses.xcodeproj \
  -scheme OpenGlasses
