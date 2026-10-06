#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install: brew install xcodegen" >&2
  exit 1
fi

# The target's MediaPipe linker configuration is generated, not committed: the fetch script
# writes it into the gitignored Frameworks directory. XcodeGen validates every configFiles
# path, so generating before that file exists fails outright on a fresh clone. Fetching is
# idempotent, but it re-reads the graph archives even on a cache hit (~20 seconds), and CI and
# Xcode Cloud already fetch before calling this — so only fetch when the file is missing.
if [[ ! -f Vendor/MediaPipeTasks/Frameworks/holistic-linker-flags.xcconfig ]]; then
  ./Scripts/fetch-mediapipe-frameworks.sh
fi

if [[ -f .openglasses-generate.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .openglasses-generate.env
  set +a
fi

# A personal entitlements file (see project.local.yml) replaces the committed one when signing,
# so a capability added to the spec after that copy was made is silently missing from a device
# build. Warn rather than edit: the file is the developer's own.
personal_entitlements=Config/Entitlements/Personal/OpenGlasses.entitlements
if [[ -f project.local.yml ]] && [[ -f "$personal_entitlements" ]] \
  && ! grep -q "com.apple.developer.healthkit" "$personal_entitlements"; then
  echo "warning: $personal_entitlements lacks com.apple.developer.healthkit — Apple Health" >&2
  echo "         access will fail on device. Run ./Scripts/setup-local-dev.sh to add it." >&2
fi
if [[ -f project.local.yml ]] && [[ -f "$personal_entitlements" ]] \
  && ! grep -q "com.apple.developer.weatherkit" "$personal_entitlements"; then
  echo "warning: $personal_entitlements lacks com.apple.developer.weatherkit — weather" >&2
  echo "         requests will fail on device. Run ./Scripts/setup-local-dev.sh to add it." >&2
fi

# The commit this project is generated at, for support reports (AppBuildIdentity). Xcode Cloud
# names it; anywhere else git does. "unknown" outside a checkout, which the app reads as unstamped.
AVENKIN_SOURCE_COMMIT="${CI_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}"
export AVENKIN_SOURCE_COMMIT="${AVENKIN_SOURCE_COMMIT:-unknown}"

spec_file=.xcodegen-spec.yml
{
  echo "include:"
  echo "  - project.base.yml"
  if [[ "${OPENGLASSES_SKIP_WATCH:-}" != "1" ]]; then
    echo "  - project.watch.yml"
  fi
  if [[ "${OPENGLASSES_SKIP_TESTS:-}" != "1" ]]; then
    echo "  - project.tests.yml"
  fi
  if [[ "${OPENGLASSES_OFFICE_TRANSPORT:-}" == "1" ]]; then
    framework=Transport/Frameworks/Mobilecore.xcframework
    if [[ ! -d "$framework/ios-arm64" ]] || [[ ! -d "$framework/ios-arm64_x86_64-simulator" ]]; then
      echo "Build the pinned iOS/simulator bridge first: Transport/scripts/build_ios_lab.sh" >&2
      exit 1
    fi
    echo "  - project.office-transport.yml"
  fi
  if [[ -f project.local.yml ]]; then
    echo "  - project.local.yml"
  fi
} >"$spec_file"

xcodegen generate --spec "$spec_file"
rm -f "$spec_file"

if [[ "${OPENGLASSES_SKIP_WATCH:-}" != "1" ]] && [[ -f xcshareddata/xcschemes/OpenGlassesWatch.xcscheme ]]; then
  mkdir -p OpenGlasses.xcodeproj/xcshareddata/xcschemes
  cp xcshareddata/xcschemes/OpenGlassesWatch.xcscheme OpenGlasses.xcodeproj/xcshareddata/xcschemes/
fi

echo "Generated OpenGlasses.xcodeproj"
