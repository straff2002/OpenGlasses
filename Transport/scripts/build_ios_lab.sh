#!/bin/sh
# Build the pinned embedded engine for the public phone app.
set -eu
transport_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
go_binary=${AVENKIN_GO_BINARY:-"$transport_root/.tools/go/bin/go"}
if [ ! -x "$go_binary" ]; then
  echo "Set AVENKIN_GO_BINARY to a Go 1.27.1 executable." >&2
  exit 1
fi
case "$("$go_binary" version)" in
  "go version go1.27.1 "*) ;;
  *) echo "The recorded iPhone lab toolchain is Go 1.27.1." >&2; exit 1 ;;
esac
export PATH="$(dirname -- "$go_binary"):$transport_root/.tools/bin:$PATH"
export GOMODCACHE="$transport_root/.tools/gomod"
export GOCACHE="$transport_root/.tools/gocache"
export GOBIN="$transport_root/.tools/bin"
export GOPATH="$transport_root/.tools/gopath"
export CLANG_MODULE_CACHE_PATH="$transport_root/.tools/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$transport_root/.tools/swift-module-cache"
mkdir -p "$transport_root/.tools"
cd "$transport_root/mobile-core"
upstream_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["moduleVersion"])' "$transport_root/vendor/syncthing/mobile-extension/pin.json")
"$go_binary" -C "$transport_root/.tools" mod download "github.com/syncthing/syncthing@$upstream_version"
python3 "$transport_root/scripts/prepare_mobile_source.py" "$GOMODCACHE" "$transport_root/.tools/syncthing-mobile"
"$go_binary" mod download
"$go_binary" test -tags noassets ./...
"$go_binary" install golang.org/x/mobile/cmd/gobind
# iOS bind needs the pinned gobind above. `gomobile init` is Android preparation and
# re-installs gobind@latest over the network, which would defeat this offline pinned build.
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
mkdir -p "$transport_root/Frameworks"
"$go_binary" tool gomobile bind -target ios/arm64,iossimulator/arm64,iossimulator/amd64 -iosversion 18.0 -tags noassets -o "$transport_root/Frameworks/Mobilecore.xcframework" .
