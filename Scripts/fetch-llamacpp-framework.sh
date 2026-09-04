#!/bin/bash
# Obtains Vendor/LlamaCpp/Frameworks/llama.xcframework for a clean clone or a CI runner
# (Plan DZ P1). This is the CI-facing companion to Scripts/build-llamacpp-framework.sh:
# fetch-or-build, checksum-verified before anything links against it.
#
# Order of preference:
#   1. Already present and matching Vendor/LlamaCpp/SHA256SUMS  → nothing to do.
#   2. A prebuilt archive, when one is configured                → download, verify, extract, verify.
#   3. Build it from the pinned llama.cpp revision               → several minutes, deterministic sources.
#
# On the archive: there is no published mirror yet, so ARTIFACT_URL is empty and every caller
# currently takes path 3. That is a deliberate, stated gap rather than a hidden one — the honest
# statement is that the *sources* are pinned and the *bytes* are recorded, and the fast path
# arrives when the artefact is mirrored. MediaPipe's fetch script has the same shape and the same
# note about mirroring to our own GitHub release assets when a third-party host proves flaky;
# the difference is only that its tarballs already exist upstream and ours do not.
#
# Set LLAMACPP_FRAMEWORK_URL (+ LLAMACPP_FRAMEWORK_SHA256) in the environment to point at a
# mirror without editing this file. A URL without its digest is refused: an unverified binary
# that runs user models is exactly the thing a checksum exists to prevent.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_dir="$repo_root/Vendor/LlamaCpp"
xcframework="$vendor_dir/Frameworks/llama.xcframework"
sums_file="$vendor_dir/SHA256SUMS"

# No mirror published yet — see the header. Override via the environment.
ARTIFACT_URL="${LLAMACPP_FRAMEWORK_URL:-}"
ARTIFACT_SHA256="${LLAMACPP_FRAMEWORK_SHA256:-}"

die() { echo "fetch-llamacpp-framework: $*" >&2; exit 1; }

[ -f "$sums_file" ] || die "missing $sums_file — the recorded digests are what makes this verifiable"

verify() { ( cd "$vendor_dir" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ); }

pinned="$(sed -n 's/^commit=//p' "$vendor_dir/REVISION" | head -n 1)"
tag="$(sed -n 's/^tag=//p' "$vendor_dir/REVISION" | head -n 1)"

# --- 1. already in place -------------------------------------------------------------------------
if [ -d "$xcframework" ] && verify; then
  echo "llama.xcframework present and matches SHA256SUMS (${tag}, ${pinned:0:12})."
  exit 0
fi

if [ -d "$xcframework" ]; then
  echo "llama.xcframework present but does not match SHA256SUMS — replacing it."
  rm -rf "$xcframework"
fi

# --- 2. prebuilt archive ---------------------------------------------------------------------------
if [ -n "$ARTIFACT_URL" ]; then
  [ -n "$ARTIFACT_SHA256" ] \
    || die "LLAMACPP_FRAMEWORK_URL is set without LLAMACPP_FRAMEWORK_SHA256. Refusing to install an unverified engine binary."
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  echo "Downloading $ARTIFACT_URL …"
  # Same retry posture as the MediaPipe fetch: --retry alone does not cover a connection reset,
  # which is how CI actually fails, and a stalled-but-open socket must become a retryable error
  # rather than a hang.
  curl -fsS -L \
       --retry 5 --retry-all-errors --retry-delay 5 \
       --speed-limit 1024 --speed-time 60 \
       -C - -o "$work/llama-xcframework.tar.gz" "$ARTIFACT_URL" \
    || die "download failed for $ARTIFACT_URL"
  echo "$ARTIFACT_SHA256  $work/llama-xcframework.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "archive sha256 does not match LLAMACPP_FRAMEWORK_SHA256 — not extracting it"
  mkdir -p "$vendor_dir/Frameworks"
  tar xzf "$work/llama-xcframework.tar.gz" -C "$vendor_dir/Frameworks"
  [ -d "$xcframework" ] || die "archive did not contain llama.xcframework"
  # Belt and braces: the archive digest proves the download, SHA256SUMS proves the contents are
  # the ones this revision recorded.
  verify || die "extracted llama.xcframework does not match SHA256SUMS"
  echo "llama.xcframework installed from $ARTIFACT_URL (${tag}, ${pinned:0:12})."
  exit 0
fi

# --- 3. build from source ---------------------------------------------------------------------------
echo "No prebuilt llama.xcframework configured — building ${tag} (${pinned:0:12}) from source."
echo "This takes several minutes. Set LLAMACPP_FRAMEWORK_URL/_SHA256 to use a mirror instead."

# Building needs cmake. On a developer's Mac that is `brew install cmake` and the build script
# says so — this script will not install software on someone's machine uninvited. A disposable CI
# runner is a different situation, and Xcode Cloud cannot use Homebrew at all (it can't resolve
# ghcr.io), so ci_post_clone.sh sets OG_ALLOW_TOOL_BOOTSTRAP=1 and gets a pinned, checksum-verified
# cmake unpacked into the same .ci-tools/ directory XcodeGen already uses there.
CMAKE_VERSION="4.2.3"
CMAKE_SHA256="c2302d3e9c48daabee5ea7c4db4b2b93b989bcc89dae8b760880e00120641b5b"

if ! command -v cmake >/dev/null 2>&1; then
  if [ "${OG_ALLOW_TOOL_BOOTSTRAP:-0}" != "1" ]; then
    die "cmake is required to build the engine and is not installed.
     Install it (brew install cmake) and re-run, or point LLAMACPP_FRAMEWORK_URL at a prebuilt
     archive. This script will not install it for you."
  fi
  echo "fetch-llamacpp-framework: bootstrapping cmake ${CMAKE_VERSION} from the Kitware release…"
  tools_dir="$repo_root/.ci-tools/cmake-${CMAKE_VERSION}"
  rm -rf "$tools_dir"; mkdir -p "$tools_dir"
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
    "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz" \
    -o "$tools_dir/cmake.tar.gz" || die "could not download cmake ${CMAKE_VERSION}"
  echo "$CMAKE_SHA256  $tools_dir/cmake.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "cmake ${CMAKE_VERSION} archive failed its checksum — not unpacking it"
  tar xzf "$tools_dir/cmake.tar.gz" -C "$tools_dir"
  cmake_bin="$(find "$tools_dir" -type f -name cmake -perm -u+x -path '*/bin/*' | head -n 1)"
  [ -n "$cmake_bin" ] || die "cmake archive did not contain a cmake binary"
  PATH="$(dirname "$cmake_bin"):$PATH"
  export PATH
  echo "fetch-llamacpp-framework: $(cmake --version | head -n 1)"
fi

"$repo_root/Scripts/build-llamacpp-framework.sh"
verify || die "build completed but the artefact does not match SHA256SUMS"
