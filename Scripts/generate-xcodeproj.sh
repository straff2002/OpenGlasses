#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install: brew install xcodegen" >&2
  exit 1
fi

if [[ -f .openglasses-generate.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .openglasses-generate.env
  set +a
fi

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
