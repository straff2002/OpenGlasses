#!/bin/bash
# Fetches the MediaPipe Tasks Vision iOS frameworks into Vendor/MediaPipeTasks/Frameworks/.
#
# The binaries are Google's official CocoaPods artefacts (Apache-2.0) and are too large to
# commit (the graph static libraries are 410 MB / 818 MB, over GitHub's 100 MB file limit),
# so both local checkouts and CI (ci_scripts/ci_post_clone.sh) populate them with this
# script. Pinned versions + sha256 so the build is reproducible; idempotent (skips work
# when the frameworks are already in place).
#
# Xcode Cloud caveat: GitHub egress works there (XcodeGen installs fine) but dl.google.com has
# been observed resetting the connection a few seconds in — `curl: (35) Recv failure:
# Connection reset by peer`, which fails the whole archive. The retry flags below are the first
# line of defence. If resets prove persistent rather than intermittent, the durable fix is to
# mirror these two tarballs as release assets on our own GitHub repo (assets allow up to 2 GB;
# the larger archive is ~351 MB) and point the URLs there, since GitHub is reachable from CI.
# Local archives are unaffected either way.
set -euo pipefail

VERSION="1.0.0"
VISION_URL="https://dl.google.com/cpdc/20260727-225049/MediaPipeTasksVision-${VERSION}.tar.gz"
VISION_SHA256="bd386a43caa40ae957e5f42907076c885992383e642188d64ed96dad5bbdcb76"
COMMON_URL="https://dl.google.com/cpdc/20260727-225047/MediaPipeTasksCommon-${VERSION}.tar.gz"
COMMON_SHA256="952403622f5f331ccdc65a1931f5fc6a4c798bd129579fb8accc94c16aed8369"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo_root/Vendor/MediaPipeTasks/Frameworks"
stamp="$dest/.fetched-$VERSION"

# Google ships these frameworks with no CFBundleVersion / CFBundleShortVersionString, which App
# Store Connect rejects on upload ("This bundle ... is invalid. The Info.plist file is missing the
# required key: CFBundleVersion"). Embedded frameworks must carry both, so stamp the pinned
# MediaPipe version into every slice. `plutil -replace` adds the key when absent, so this is
# idempotent — and it runs on the already-fetched path too, so existing checkouts and warm CI
# caches get repaired without a 1.2 GB re-download.
patch_bundle_versions() {
  local plist
  while IFS= read -r plist; do
    plutil -replace CFBundleVersion -string "$VERSION" "$plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
  done < <(find "$dest" -path "*.framework/Info.plist" -type f)
}

if [ -f "$stamp" ] \
   && [ -d "$dest/MediaPipeTasksVision.xcframework" ] \
   && [ -d "$dest/MediaPipeTasksCommon.xcframework" ] \
   && [ -f "$dest/graph_libraries/libMediaPipeTasksCommon_device_graph.a" ] \
   && [ -f "$dest/graph_libraries/libMediaPipeTasksCommon_simulator_graph.a" ]; then
  patch_bundle_versions
  echo "MediaPipeTasks ${VERSION} already fetched (bundle versions verified)."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # url sha256 out
  echo "Downloading $1 …"
  # `--retry` on its own only covers what curl classes as transient — timeouts, 5xx, 408, 429.
  # It does NOT retry a connection reset, which is exactly how Xcode Cloud fails on
  # dl.google.com: `curl: (35) Recv failure: Connection reset by peer`, aborting
  # ci_post_clone.sh with exit 35 on the first reset despite `--retry 3`. `--retry-all-errors`
  # is what covers it. `-C -` resumes rather than restarting a part-received archive (these are
  # ~350 MB+), and `--speed-limit/--speed-time` turn a stalled-but-open socket into a retryable
  # error instead of a hang.
  local rc=0
  curl -fsS -L \
       --retry 5 --retry-all-errors --retry-delay 5 \
       --speed-limit 1024 --speed-time 60 \
       -C - -o "$3" "$1" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "fetch failed for $1 (curl exit $rc)" >&2
    echo "  If this is Xcode Cloud: GitHub egress works there but dl.google.com resets — see the" >&2
    echo "  mirror note in the header comment." >&2
    exit "$rc"
  fi
  echo "$2  $3" | shasum -a 256 -c - >/dev/null || {
    echo "sha256 mismatch for $1" >&2; exit 1; }
}

fetch "$VISION_URL" "$VISION_SHA256" "$work/vision.tar.gz"
fetch "$COMMON_URL" "$COMMON_SHA256" "$work/common.tar.gz"

mkdir -p "$work/vision" "$work/common"
tar xzf "$work/vision.tar.gz" -C "$work/vision"
tar xzf "$work/common.tar.gz" -C "$work/common"

rm -rf "$dest"
mkdir -p "$dest/graph_libraries"
mv "$work/vision/frameworks/MediaPipeTasksVision.xcframework" "$dest/"
mv "$work/common/frameworks/MediaPipeTasksCommon.xcframework" "$dest/"
mv "$work/common/frameworks/graph_libraries/"*.a "$dest/graph_libraries/"

patch_bundle_versions

touch "$stamp"
echo "MediaPipeTasks ${VERSION} installed under Vendor/MediaPipeTasks/Frameworks."
