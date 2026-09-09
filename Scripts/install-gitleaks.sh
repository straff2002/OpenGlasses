#!/usr/bin/env bash
#
# Install the pinned, checksum-verified gitleaks into .ci-tools/ (W06.2).
#
# Modelled on Scripts/install-xcodegen.sh, for the same reason: a tool that decides whether a
# commit is allowed to merge is a build input, and downloading the newest release of it on every
# run means the gate's behaviour is whatever upstream shipped that morning. The pin lives in
# Scripts/gitleaks-pin.env.
#
# Progress goes to stderr; the ONLY thing on stdout is the directory containing the binary:
#
#   PATH="$(./Scripts/install-gitleaks.sh):$PATH"
#
# On GitHub Actions the directory is also appended to $GITHUB_PATH.
#
# Idempotent: a verified install already in .ci-tools/ is reused.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=Scripts/gitleaks-pin.env
. "$repo_root/Scripts/gitleaks-pin.env"

log() { printf '%s\n' "install-gitleaks: $*" >&2; }

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) asset="gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz"; expected="$GITLEAKS_SHA256_darwin_arm64" ;;
  Linux/x86_64) asset="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz";    expected="$GITLEAKS_SHA256_linux_x64" ;;
  *)
    log "FAIL — no pinned gitleaks digest for $(uname -s)/$(uname -m)."
    log "  Add the platform's asset digest to Scripts/gitleaks-pin.env in a reviewed commit."
    log "  Installing an unverified scanner is not an acceptable fallback: a scanner that can be"
    log "  substituted is a scanner that can be made to find nothing."
    exit 1
    ;;
esac

tools_dir="$repo_root/.ci-tools/gitleaks-${GITLEAKS_VERSION}"
tarball="$tools_dir/$asset"
binary="$tools_dir/gitleaks"

verify() { # file
  echo "$expected  $1" | shasum -a 256 -c - >/dev/null 2>&1
}

if [ -x "$binary" ] && [ -f "$tarball" ] && verify "$tarball"; then
  log "gitleaks ${GITLEAKS_VERSION} already installed and verified."
else
  url="$GITLEAKS_BASE_URL/$asset"
  log "installing gitleaks ${GITLEAKS_VERSION} from ${url}"
  rm -rf "$tools_dir"
  mkdir -p "$tools_dir"
  # Same retry posture as install-xcodegen.sh: release assets redirect to a different host from
  # the one the clone proved reachable, and a single connect failure under `set -e` has killed a
  # whole run before.
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
    "$url" -o "$tarball"

  if ! verify "$tarball"; then
    log "FAIL — sha256 mismatch for $url"
    log "  expected: $expected"
    log "  actual:   $(shasum -a 256 "$tarball" | awk '{print $1}')"
    log "  Refusing to run an unverified scanner. If the release was legitimately re-cut, update"
    log "  Scripts/gitleaks-pin.env in a reviewed commit."
    rm -rf "$tools_dir"
    exit 1
  fi
  log "sha256 verified."

  tar -xzf "$tarball" -C "$tools_dir" gitleaks
  chmod +x "$binary"
fi

log "$("$binary" version 2>&1 | head -n 1)"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$tools_dir" >> "$GITHUB_PATH"
fi

printf '%s\n' "$tools_dir"
