#!/usr/bin/env bash
#
# Install the pinned, checksum-verified XcodeGen into .ci-tools/ (W06.1).
#
# Both CI paths use this: GitHub Actions ran `brew install xcodegen`, which installs whatever
# version the tap happens to hold that morning and verifies nothing this repository states, and
# Xcode Cloud downloaded the release archive with no digest check at all. XcodeGen writes the
# project file every build compiles, so substituting it substitutes the build — the same reason
# Scripts/fetch-mediapipe-frameworks.sh and Scripts/fetch-llamacpp-framework.sh verify what they
# fetch. This closes the last unverified tool download.
#
# Homebrew is deliberately not an option on Xcode Cloud: its network cannot resolve ghcr.io (the
# bottle host), so `brew install` dies inside auto-update and aborts the post-clone script. The
# GitHub release is reachable there — the repo was just cloned from github.com.
#
# Progress goes to stderr; the ONLY thing on stdout is the directory containing the binary, so a
# caller can do:
#
#   PATH="$(./Scripts/install-xcodegen.sh):$PATH"
#
# On GitHub Actions the directory is also appended to $GITHUB_PATH, so later steps pick it up
# without doing anything.
#
# Idempotent: a verified install already in .ci-tools/ is reused.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=Scripts/xcodegen-pin.env
. "$repo_root/Scripts/xcodegen-pin.env"

tools_dir="$repo_root/.ci-tools/xcodegen-${XCODEGEN_VERSION}"
zip_path="$tools_dir/xcodegen.zip"

log() { printf '%s\n' "install-xcodegen: $*" >&2; }

verify() { # file
  echo "$XCODEGEN_SHA256  $1" | shasum -a 256 -c - >/dev/null 2>&1
}

find_bin_dir() {
  local bin
  bin="$(find "$tools_dir" -type f -name xcodegen -path '*/bin/*' 2>/dev/null | head -n 1)"
  [ -n "$bin" ] || return 1
  chmod +x "$bin"
  dirname "$bin"
}

if bin_dir="$(find_bin_dir)" && [ -f "$zip_path" ] && verify "$zip_path"; then
  log "XcodeGen ${XCODEGEN_VERSION} already installed and verified."
else
  log "installing XcodeGen ${XCODEGEN_VERSION} from ${XCODEGEN_URL}"
  rm -rf "$tools_dir"
  mkdir -p "$tools_dir"
  # Retries: a single connect failure here (curl exit 7) has killed a whole Xcode Cloud archive
  # under `set -e` — release assets redirect to objects.githubusercontent.com, a different host
  # from the one the clone proved reachable. --retry-all-errors covers connect-level failures,
  # which plain --retry does not consider transient.
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
    "$XCODEGEN_URL" -o "$zip_path"

  if ! verify "$zip_path"; then
    log "FAIL — sha256 mismatch for $XCODEGEN_URL"
    log "  expected: $XCODEGEN_SHA256"
    log "  actual:   $(shasum -a 256 "$zip_path" | awk '{print $1}')"
    log "  Refusing to run an unverified build tool. If the release was legitimately re-cut,"
    log "  update XCODEGEN_SHA256 in Scripts/xcodegen-pin.env in a reviewed commit."
    rm -rf "$tools_dir"
    exit 1
  fi
  log "sha256 verified."

  unzip -oq "$zip_path" -d "$tools_dir"
  if ! bin_dir="$(find_bin_dir)"; then
    log "FAIL — no xcodegen binary in the extracted archive."
    exit 1
  fi
fi

log "$("$bin_dir/xcodegen" --version 2>&1 | head -n 1)"

# GitHub Actions: make it available to every later step without each one re-deriving the path.
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bin_dir" >> "$GITHUB_PATH"
fi

printf '%s\n' "$bin_dir"
