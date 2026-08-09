#!/bin/bash
# Fetches the MediaPipe Tasks Vision iOS frameworks into Vendor/MediaPipeTasks/Frameworks/.
#
# The binaries are Google's official CocoaPods artefacts (Apache-2.0) and are too large to
# commit (the graph static libraries are 410 MB / 818 MB, over GitHub's 100 MB file limit),
# so both local checkouts and CI (ci_scripts/ci_post_clone.sh) populate them with this
# script. Pinned versions + sha256 so the build is reproducible; idempotent (skips work
# when the frameworks are already in place).
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
  curl -fsSL --retry 3 -o "$3" "$1"
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
