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

# --- XcodeGen (no Homebrew) -------------------------------------------------
# Xcode Cloud's network can't resolve ghcr.io — Homebrew's bottle + portable-ruby host. So
# `brew install xcodegen` dies inside Homebrew auto-update with
#   curl: (6) Could not resolve host: ghcr.io
# which (under `set -e`) aborts this whole script. Install XcodeGen from its GitHub *release*
# instead: github.com is reachable (the repo was just cloned from it), and the release archive is
# self-contained (`xcodegen/bin/xcodegen` + `share/`).
#
# When bumping, keep this in step with the version developers use locally.
XCODEGEN_VERSION="2.45.4"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ci_post_clone: installing XcodeGen ${XCODEGEN_VERSION} from the GitHub release…"
  tools_dir="$PWD/.ci-tools/xcodegen-${XCODEGEN_VERSION}"
  rm -rf "$tools_dir"
  mkdir -p "$tools_dir"
  # Retries: a single connect failure here (curl exit 7) killed a whole archive under `set -e` —
  # release assets redirect to objects.githubusercontent.com, a different host from the one the
  # clone proved reachable, and Xcode Cloud's network drops it occasionally. --retry-all-errors
  # covers connect-level failures, which plain --retry does not consider transient.
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
    "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" \
    -o "$tools_dir/xcodegen.zip"
  unzip -oq "$tools_dir/xcodegen.zip" -d "$tools_dir"
  xcodegen_bin="$(find "$tools_dir" -type f -name xcodegen -path '*/bin/*' | head -n 1)"
  if [ -n "$xcodegen_bin" ]; then
    chmod +x "$xcodegen_bin"
    PATH="$(dirname "$xcodegen_bin"):$PATH"
    export PATH
  fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ci_post_clone: xcodegen unavailable after GitHub-release install" >&2
  exit 1
fi
echo "ci_post_clone: $(xcodegen --version 2>&1 | head -n 1)"

# MediaPipe Tasks frameworks (Plan CK) are fetched, not committed — the graph static
# libraries exceed GitHub's per-file size limit. Pinned + sha256-verified from dl.google.com
# (Google's official CocoaPods artefacts); the script is idempotent.
./Scripts/fetch-mediapipe-frameworks.sh

# The llama.cpp engine (Plan DZ) is likewise built, not committed. With no mirror published yet
# this compiles it from the pinned revision, which adds several minutes to a cold run and needs
# cmake — hence OG_ALLOW_TOOL_BOOTSTRAP, which lets the fetch script unpack a pinned,
# checksum-verified cmake into .ci-tools/ the way this script already does for XcodeGen. Homebrew
# is not an option here (it cannot resolve ghcr.io). Setting LLAMACPP_FRAMEWORK_URL and
# LLAMACPP_FRAMEWORK_SHA256 in the workflow environment switches this to a download once the
# artefact is mirrored. Idempotent, and it verifies SHA256SUMS before anything links the engine.
OG_ALLOW_TOOL_BOOTSTRAP=1 ./Scripts/fetch-llamacpp-framework.sh

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
echo "ci_post_clone: complete"
