#!/bin/bash
# Builds Vendor/LlamaCpp/Frameworks/llama.xcframework from the exact llama.cpp revision pinned in
# Vendor/LlamaCpp/REVISION (Plan DZ P1 — the GGUF local-inference runtime).
#
# The output is a *static* xcframework (one merged libllama.a per slice plus the C headers),
# matching the shape already vendored for sherpa-onnx. Static means no embedded dylib to sign,
# no install-name dance, and no framework bundle whose Info.plist can fail App Store validation.
#
# Slices: ios-arm64 (device) and an iOS simulator slice — arm64, plus x86_64 when the installed
# SDK still supports it, so an Intel Mac can run the simulator suite.
#
# Reproducibility, and its honest limit: the *sources* are reproducible — the revision is pinned
# by commit and cross-checked against its tag before anything compiles. The *bytes* are not, and
# saying otherwise would be a claim this script cannot back: a static archive carries build paths
# and a toolchain fingerprint, so a different Xcode produces a different digest from identical
# sources. So the drift check is conditioned on the thing that actually explains a difference:
#
#   * same revision, same options, same toolchain, different digest → unexplained. Hard failure.
#   * different revision, options or toolchain                      → explained. Says so loudly,
#                                                                     records the new digests.
#   * --strict                                                      → any difference fails.
#   * --update-sums                                                 → record without comparing.
#
# SHA256SUMS holds the digests; BUILD-INFO holds what produced them. Both are tracked; the
# xcframework itself is not.
#
# Usage:
#   Scripts/build-llamacpp-framework.sh [--update-sums] [--strict] [--clean] [--jobs N]
#                                       [--sim-archs "arm64;x86_64"]
#
# Idempotent: with the framework already present and matching SHA256SUMS, it validates and exits
# without recompiling. Pass --clean to force a from-scratch rebuild.
#
# Requires cmake (brew install cmake) and Xcode command line tools.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_dir="$repo_root/Vendor/LlamaCpp"
work_dir="$vendor_dir/.build"          # gitignored: checkout + cmake build trees
src_dir="$work_dir/llama.cpp"
frameworks_dir="$vendor_dir/Frameworks"
xcframework="$frameworks_dir/llama.xcframework"
sums_file="$vendor_dir/SHA256SUMS"
build_info_file="$vendor_dir/BUILD-INFO"

update_sums=0
strict=0
clean=0
jobs="$(sysctl -n hw.logicalcpu)"
sim_archs=""

while [ $# -gt 0 ]; do
  case "$1" in
    --update-sums) update_sums=1; shift ;;
    --strict)      strict=1; shift ;;
    --clean)       clean=1; shift ;;
    --jobs)        jobs="$2"; shift 2 ;;
    --sim-archs)   sim_archs="$2"; shift 2 ;;
    -h|--help)     sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "build-llamacpp-framework: $*" >&2; exit 1; }

command -v cmake >/dev/null 2>&1 || die "cmake not found. Install it (brew install cmake) and re-run."
command -v xcrun >/dev/null 2>&1 || die "xcrun not found. Install the Xcode command line tools."

# --- the pin -----------------------------------------------------------------------------------
[ -f "$vendor_dir/REVISION" ] || die "missing $vendor_dir/REVISION"
revision_value() { sed -n "s/^$1=//p" "$vendor_dir/REVISION" | head -n 1; }
LLAMA_REPO="$(revision_value repository)"
LLAMA_TAG="$(revision_value tag)"
LLAMA_COMMIT="$(revision_value commit)"
[ -n "$LLAMA_REPO" ] && [ -n "$LLAMA_TAG" ] && [ -n "$LLAMA_COMMIT" ] \
  || die "REVISION must define repository=, tag= and commit="
case "$LLAMA_COMMIT" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) die "commit= must be a full 40-character hex sha, got '$LLAMA_COMMIT'" ;;
esac
[ "${#LLAMA_COMMIT}" -eq 40 ] || die "commit= must be a full 40-character sha, got '$LLAMA_COMMIT'"

# --- the deployment target, taken from the project spec rather than duplicated -------------------
# A framework built for an older minimum than the app's is a link-time surprise nobody looks for,
# so read it from the one place that defines it and fail if the spec stops looking like this.
IOS_MIN_OS_VERSION="$(sed -n '/^  deploymentTarget:/,/^  [a-zA-Z]/p' "$repo_root/project.base.yml" \
                      | sed -n 's/^ *iOS: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' | head -n 1)"
[ -n "$IOS_MIN_OS_VERSION" ] \
  || die "could not read options.deploymentTarget.iOS from project.base.yml — the spec's shape changed"

# --- simulator architectures --------------------------------------------------------------------
# x86_64 costs a second compile of every translation unit, so only ask for it when the installed
# simulator SDK still has the slice. Apple removes architectures from SDKs over time; when that
# happens this quietly narrows to arm64 instead of failing a build nobody changed.
if [ -z "$sim_archs" ]; then
  sim_sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
  probe_dir="$(mktemp -d)"
  printf 'int main(void){return 0;}\n' > "$probe_dir/probe.c"
  if [ -n "$sim_sdk_path" ] && xcrun --sdk iphonesimulator clang -arch x86_64 \
       -target "x86_64-apple-ios${IOS_MIN_OS_VERSION}-simulator" \
       -c "$probe_dir/probe.c" -o "$probe_dir/probe.o" >/dev/null 2>&1; then
    sim_archs="arm64;x86_64"
  else
    sim_archs="arm64"
    echo "note: the installed iphonesimulator SDK cannot build x86_64 — simulator slice is arm64 only."
  fi
  rm -rf "$probe_dir"
fi

# --- build options ------------------------------------------------------------------------------
# Everything that is not the inference library is off: no CLI tools, examples, tests, server, web
# UI, common utils, OpenSSL, or multimodal projector (mtmd). Text-only is the shipping phase; the
# vision phase flips LLAMA_BUILD_MTMD and re-pins.
#
# GGML_METAL_EMBED_LIBRARY embeds the kernel *source* into a __ggml_metallib data section, so
# there is no default.metallib resource to ship or fail to find at runtime.
COMMON_CMAKE_ARGS=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN_OS_VERSION}"
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_APP=OFF
  -DLLAMA_BUILD_COMMON=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_TOOLS=OFF
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DLLAMA_BUILD_UI=OFF
  -DLLAMA_USE_PREBUILT_UI=OFF
  -DLLAMA_BUILD_MTMD=OFF
  -DLLAMA_OPENSSL=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS=ON
  -DGGML_BLAS_VENDOR=Apple
  -DGGML_ACCELERATE=ON
  -DGGML_OPENMP=OFF
  -DGGML_NATIVE=OFF
  -DCMAKE_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
  -DCMAKE_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
)

# Cache entries asserted after configure. Configuring is not the same as configuring the way we
# asked: a stale cache, a renamed upstream option, or a default that moved would all otherwise
# ship a differently-built engine under the same revision.
EXPECTED_CACHE=(
  "BUILD_SHARED_LIBS:OFF"
  "LLAMA_BUILD_COMMON:OFF"
  "LLAMA_BUILD_EXAMPLES:OFF"
  "LLAMA_BUILD_TOOLS:OFF"
  "LLAMA_BUILD_TESTS:OFF"
  "LLAMA_BUILD_SERVER:OFF"
  "LLAMA_BUILD_MTMD:OFF"
  "GGML_METAL:ON"
  "GGML_METAL_EMBED_LIBRARY:ON"
  "GGML_BLAS:ON"
  "GGML_ACCELERATE:ON"
  "GGML_OPENMP:OFF"
  "GGML_NATIVE:OFF"
)

# Public headers copied into the xcframework. llama-cpp.h is deliberately excluded: it is a C++
# RAII convenience header, and this package's whole point is that only C crosses into Swift.
HEADERS=(
  "include/llama.h"
  "ggml/include/ggml.h"
  "ggml/include/ggml-alloc.h"
  "ggml/include/ggml-backend.h"
  "ggml/include/ggml-blas.h"
  "ggml/include/ggml-cpu.h"
  "ggml/include/ggml-metal.h"
  "ggml/include/ggml-opt.h"
  "ggml/include/gguf.h"
)

# --- fast path ----------------------------------------------------------------------------------
if [ "$clean" -eq 0 ] && [ -d "$xcframework" ] && [ -f "$sums_file" ]; then
  if (cd "$vendor_dir" && shasum -a 256 -c "$sums_file" >/dev/null 2>&1); then
    echo "llama.xcframework already built at ${LLAMA_TAG} (${LLAMA_COMMIT:0:12}) and matches SHA256SUMS."
    exit 0
  fi
  echo "llama.xcframework present but does not match SHA256SUMS — rebuilding."
fi

# --- source ---------------------------------------------------------------------------------------
mkdir -p "$work_dir"
if [ ! -d "$src_dir/.git" ]; then
  echo "Cloning $LLAMA_REPO …"
  git clone --filter=blob:none --no-checkout "$LLAMA_REPO" "$src_dir"
fi
git -C "$src_dir" remote set-url origin "$LLAMA_REPO"
if ! git -C "$src_dir" cat-file -e "${LLAMA_COMMIT}^{commit}" 2>/dev/null; then
  git -C "$src_dir" fetch --tags --force origin
fi
git -C "$src_dir" cat-file -e "${LLAMA_COMMIT}^{commit}" 2>/dev/null \
  || die "pinned commit $LLAMA_COMMIT is not in $LLAMA_REPO"

# Tag/commit cross-check. An upstream tag that has been moved off the pinned commit is exactly the
# supply-chain drift this pin exists to catch, so say so and stop; the build itself still uses the
# commit, never the tag.
upstream_tag_commit="$(git -C "$src_dir" ls-remote "$LLAMA_REPO" "refs/tags/${LLAMA_TAG}^{}" 2>/dev/null | awk '{print $1}')"
if [ -z "$upstream_tag_commit" ]; then
  upstream_tag_commit="$(git -C "$src_dir" ls-remote "$LLAMA_REPO" "refs/tags/${LLAMA_TAG}" 2>/dev/null | awk '{print $1}')"
fi
if [ -n "$upstream_tag_commit" ] && [ "$upstream_tag_commit" != "$LLAMA_COMMIT" ]; then
  die "upstream tag ${LLAMA_TAG} now points at ${upstream_tag_commit}, not the pinned ${LLAMA_COMMIT}.
     Either the tag moved or REVISION is wrong. Resolve it deliberately; do not build."
fi
[ -n "$upstream_tag_commit" ] || echo "warning: could not reach $LLAMA_REPO to cross-check tag ${LLAMA_TAG}; building the pinned commit."

git -C "$src_dir" checkout --quiet --detach "$LLAMA_COMMIT"
head_commit="$(git -C "$src_dir" rev-parse HEAD)"
[ "$head_commit" = "$LLAMA_COMMIT" ] || die "checkout landed on $head_commit, expected $LLAMA_COMMIT"
echo "Building llama.cpp ${LLAMA_TAG} (${LLAMA_COMMIT}) for iOS ${IOS_MIN_OS_VERSION}."

# --- build ------------------------------------------------------------------------------------
# Cache values carry a type (BOOL, STRING, UNINITIALIZED …) that varies with how the entry was
# declared, so match on the key and take whatever follows the type rather than assuming one.
cache_value() { sed -n "s/^$2:[A-Z]*=//p" "$1/CMakeCache.txt" | head -n 1; }

assert_cache() { # build_dir sysroot archs
  local build_dir="$1" sysroot="$2" archs="$3" entry key want got
  [ -f "$build_dir/CMakeCache.txt" ] || die "no CMakeCache.txt in $build_dir"
  for entry in "${EXPECTED_CACHE[@]}"; do
    key="${entry%%:*}"; want="${entry##*:}"
    got="$(cache_value "$build_dir" "$key")"
    [ -n "$got" ] || die "cmake cache has no ${key} — upstream renamed or removed the option"
    [ "$got" = "$want" ] || die "cmake cache has ${key}=${got}, expected ${want}"
  done
  got="$(cache_value "$build_dir" CMAKE_OSX_DEPLOYMENT_TARGET)"
  [ "$got" = "$IOS_MIN_OS_VERSION" ] \
    || die "cmake cache targets iOS '${got}', expected ${IOS_MIN_OS_VERSION}"
  got="$(cache_value "$build_dir" CMAKE_OSX_SYSROOT)"
  [ "$got" = "$sysroot" ] || die "cmake cache sysroot is '${got}', expected ${sysroot}"
  got="$(cache_value "$build_dir" CMAKE_OSX_ARCHITECTURES)"
  [ "$got" = "$archs" ] || die "cmake cache architectures are '${got}', expected ${archs}"
}

build_slice() { # name sysroot archs
  local name="$1" sysroot="$2" archs="$3"
  local build_dir="$work_dir/build-$name"
  [ "$clean" -eq 1 ] && rm -rf "$build_dir"
  echo "--- configuring $name ($archs, $sysroot) ---"
  cmake -B "$build_dir" -S "$src_dir" -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$sysroot" >/dev/null
  assert_cache "$build_dir" "$sysroot" "$archs"
  echo "--- building $name ---"
  cmake --build "$build_dir" --config Release -j "$jobs" -- -quiet
}

merge_slice() { # name archs -> writes $work_dir/merged/<name>/libllama.a
  local name="$1" archs="$2"
  local build_dir="$work_dir/build-$name"
  local out_dir="$work_dir/merged/$name"
  rm -rf "$out_dir"; mkdir -p "$out_dir"

  # Collect every static archive the build produced rather than naming them: upstream moves and
  # adds libraries (vendor/hash arrived this way), and a hard-coded list silently drops symbols.
  local archives=()
  while IFS= read -r a; do archives+=("$a"); done < <(find "$build_dir" -name '*.a' -type f | sort)
  [ "${#archives[@]}" -gt 0 ] || die "$name produced no static archives"
  local names; names="$(printf '%s\n' "${archives[@]}" | xargs -n 1 basename | sort)"
  for required in libllama.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a libggml-blas.a; do
    printf '%s\n' "$names" | grep -qx "$required" \
      || die "$name is missing $required — check the build options"
  done

  # Multiple architectures mean libtool sees objects that do not match whichever it is scanning;
  # those warnings are noise, the error path is still checked by the exit status.
  xcrun libtool -static -o "$out_dir/libllama.a" "${archives[@]}" 2>/dev/null \
    || die "libtool failed merging $name"

  local want got
  want="$(printf '%s' "$archs" | tr ';' ' ')"
  got="$(xcrun lipo -archs "$out_dir/libllama.a")"
  for arch in $want; do
    printf '%s\n' $got | grep -qx "$arch" \
      || die "$name libllama.a has architectures '$got', missing $arch"
  done
  echo "$name: $(printf '%s' "$got") — $(du -h "$out_dir/libllama.a" | cut -f1)"
}

build_slice ios-device iphoneos "arm64"
build_slice ios-sim iphonesimulator "$sim_archs"
merge_slice ios-device "arm64"
merge_slice ios-sim "$sim_archs"

# --- headers ------------------------------------------------------------------------------------
headers_dir="$work_dir/Headers"
rm -rf "$headers_dir"; mkdir -p "$headers_dir"
for h in "${HEADERS[@]}"; do
  [ -f "$src_dir/$h" ] || die "expected header $h is missing at this revision"
  cp "$src_dir/$h" "$headers_dir/"
done
# Deliberately no module.modulemap. Xcode copies a static xcframework's headers into
# $BUILT_PRODUCTS_DIR/include, so two vendored xcframeworks that each ship one collide there —
# "Multiple commands produce .../include/module.modulemap", which is how this was found. The
# wrapper only needs the headers on the search path to #include "llama.h", and nothing should be
# importing the raw engine from Swift anyway: the C ABI in LlamaCppWrapper.h is the whole surface.

# --- xcframework ----------------------------------------------------------------------------------
rm -rf "$xcframework"
mkdir -p "$frameworks_dir"
xcrun xcodebuild -create-xcframework \
  -library "$work_dir/merged/ios-device/libllama.a" -headers "$headers_dir" \
  -library "$work_dir/merged/ios-sim/libllama.a"    -headers "$headers_dir" \
  -output "$xcframework" >/dev/null

slice_count="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$xcframework/Info.plist" \
               | grep -c 'LibraryIdentifier')"
[ "$slice_count" -eq 2 ] || die "xcframework has $slice_count slices, expected 2"
echo "Wrote $xcframework ($(du -sh "$xcframework" | cut -f1))"

# --- checksums and provenance ---------------------------------------------------------------------
new_sums="$work_dir/SHA256SUMS.new"
( cd "$vendor_dir" && find Frameworks/llama.xcframework -type f | LC_ALL=C sort \
    | xargs shasum -a 256 ) > "$new_sums"

# What produced these digests. Options are hashed rather than listed so the file stays short and
# a single changed flag still changes the fingerprint.
options_digest="$(printf '%s\n' "${COMMON_CMAKE_ARGS[@]}" "sim_archs=$sim_archs" \
                  | shasum -a 256 | cut -d' ' -f1)"
new_info="$work_dir/BUILD-INFO.new"
{
  echo "revision=$LLAMA_COMMIT"
  echo "tag=$LLAMA_TAG"
  echo "ios_deployment_target=$IOS_MIN_OS_VERSION"
  echo "simulator_architectures=$sim_archs"
  echo "options_digest=$options_digest"
  echo "xcodebuild=$(xcrun xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  echo "cmake=$(cmake --version | head -n 1)"
  # Release object files carry DWARF, and DWARF carries absolute source paths — so a checkout at a
  # different path produces different bytes from identical sources. Recording it is what lets that
  # difference be recognised as explained rather than raising a false supply-chain alarm on a CI
  # runner, which never clones to the same directory a developer does.
  echo "build_root=$repo_root"
} > "$new_info"

previous_field() { [ -f "$build_info_file" ] && sed -n "s/^$1=//p" "$build_info_file" | head -n 1; }

if [ "$update_sums" -eq 1 ] || [ ! -f "$sums_file" ]; then
  mv "$new_sums" "$sums_file"; mv "$new_info" "$build_info_file"
  echo "Recorded $sums_file ($(wc -l < "$sums_file" | tr -d ' ') files) and $build_info_file."
elif diff -q "$sums_file" "$new_sums" >/dev/null; then
  mv "$new_info" "$build_info_file"
  echo "SHA256SUMS verified ($(wc -l < "$sums_file" | tr -d ' ') files)."
else
  # A digest difference is only alarming when nothing that could explain it has changed.
  explained=""
  [ "$(previous_field revision)" = "$LLAMA_COMMIT" ] || explained="the pinned revision"
  [ -n "$explained" ] || [ "$(previous_field options_digest)" = "$options_digest" ] \
    || explained="the build options"
  [ -n "$explained" ] || [ "$(previous_field xcodebuild)" = "$(sed -n 's/^xcodebuild=//p' "$new_info")" ] \
    || explained="the Xcode toolchain"
  [ -n "$explained" ] || [ "$(previous_field cmake)" = "$(sed -n 's/^cmake=//p' "$new_info")" ] \
    || explained="the cmake version"
  [ -n "$explained" ] || [ "$(previous_field build_root)" = "$repo_root" ] \
    || explained="the checkout path (debug info records absolute source paths)"

  if [ -z "$explained" ] || [ "$strict" -eq 1 ]; then
    echo "" >&2
    echo "DRIFT: the built artefact does not match the recorded Vendor/LlamaCpp/SHA256SUMS," >&2
    if [ -z "$explained" ]; then
      echo "and nothing in BUILD-INFO explains it: same revision, options, Xcode and cmake." >&2
    else
      echo "and --strict was requested (the difference is attributable to ${explained})." >&2
    fi
    diff "$sums_file" "$new_sums" | head -n 40 >&2
    echo "" >&2
    die "Resolve this deliberately. Re-run with --update-sums only once you know why the bytes
     changed, and say so in the commit — the recorded digests are what
     fetch-llamacpp-framework.sh validates a downloaded engine against."
  fi

  echo ""
  echo "NOTE: the artefact's digests changed, explained by ${explained}."
  echo "      Recording the new digests. Review the SHA256SUMS/BUILD-INFO diff before committing."
  mv "$new_sums" "$sums_file"; mv "$new_info" "$build_info_file"
fi
rm -f "$new_sums" "$new_info"

( cd "$vendor_dir" && shasum -a 256 -c SHA256SUMS >/dev/null ) || die "SHA256SUMS does not verify"
echo "llama.cpp ${LLAMA_TAG} (${LLAMA_COMMIT:0:12}) built and verified."
