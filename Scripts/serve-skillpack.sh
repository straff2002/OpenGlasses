#!/usr/bin/env bash
# Plan BX P3 — the pack-author dev loop: serve a pack folder over LAN and print the install QR.
#
#   ./Scripts/serve-skillpack.sh <packDir> [port]
#
# Zips <packDir> (which must contain skillpack.json), serves it over plain HTTP on the LAN, and
# prints an openglasses://skillpack?url=… link + QR code. Scan with the iPhone camera → the app
# fetches, previews, and asks to install. Plain HTTP is fine here BY DESIGN: the app only accepts
# http: sources on private/LAN addresses (SkillPackSideload.isPermittedSource), and unsigned packs
# need Developer Mode on in Settings → Skill Packs.
#
# QR rendering uses qrencode when available (brew install qrencode); otherwise the link prints
# for manual entry.
set -euo pipefail

PACK_DIR="${1:?usage: serve-skillpack.sh <packDir> [port]}"
PORT="${2:-8787}"

[[ -f "$PACK_DIR/skillpack.json" ]] || { echo "error: no skillpack.json in $PACK_DIR" >&2; exit 1; }

PACK_ID=$(python3 -c "import json;print(json.load(open('$PACK_DIR/skillpack.json'))['id'])")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ZIP_NAME="$PACK_ID.zip"
(cd "$PACK_DIR" && zip -q -X -r "$STAGE/$ZIP_NAME" .)

# LAN IP: first non-loopback IPv4.
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
[[ -n "$LAN_IP" ]] || { echo "error: no LAN address found (is Wi-Fi on?)" >&2; exit 1; }

PACK_URL="http://$LAN_IP:$PORT/$ZIP_NAME"
LINK="openglasses://skillpack?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$PACK_URL")"

echo "Serving $PACK_ID at $PACK_URL"
echo
echo "Install link: $LINK"
echo
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$LINK"
else
  echo "(brew install qrencode for a scannable QR; meanwhile AirDrop or type the link)"
fi
echo
echo "Reminder: unsigned sideloads need Developer Mode ON in Settings → Skill Packs."
echo "Serving until Ctrl-C…"
cd "$STAGE" && python3 -m http.server "$PORT" --bind 0.0.0.0
