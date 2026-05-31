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
