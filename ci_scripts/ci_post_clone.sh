#!/bin/sh
set -eu
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

# mlx-swift-lm ships a Swift macro (MLXHuggingFaceMacros, used by LocalLLMService).
# Since Xcode 15, macros must be trusted before the build can use them — locally you
# do that once via Xcode's "Trust & Enable" prompt, but Xcode Cloud is a fresh
# environment that never trusted it, so `xcodebuild archive` fails with
# "Macro … must be enabled before it can be used" (exit 65). Skip macro/plugin
# fingerprint validation for the headless build — we control these dependencies.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

if ! command -v xcodegen >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  brew install xcodegen
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen required to generate OpenGlasses.xcodeproj" >&2
  exit 1
fi
./Scripts/generate-xcodeproj.sh

# Xcode Cloud requires a committed Package.resolved and will NOT resolve packages
# itself — automatic resolution is disabled in its environment, and even
# `xcodebuild -resolvePackageDependencies` fails there (exit 74). Because the
# .xcodeproj is generated (and gitignored), no resolved file is committed at its
# path, so copy our tracked copy into place before the build/archive action runs.
#
# Keep ci_scripts/Package.resolved in sync after adding/updating an SPM dependency:
#   ./Scripts/update-package-resolved.sh
RESOLVED_DST="OpenGlasses.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DST"
cp ci_scripts/Package.resolved "$RESOLVED_DST/Package.resolved"
