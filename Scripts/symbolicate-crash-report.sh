#!/usr/bin/env bash
#
# Name our own frames in a crash a support report carries (Plan MB P2).
#
# Usage: Scripts/symbolicate-crash-report.sh <report.txt> <path.xcarchive>
#
# A support report, or a diagnostics export, prints each crash the phone recorded under
# "Crashes the phone recorded", "Ended in a crash …" or "A crash the phone recorded (run not
# identified)", with the crashed thread's frames as
#
#      0  OpenGlasses  9F8E7D6C-5B4A-3928-1716-151413121110  +0x18000
#
# — index, binary, binary UUID, offset into the binary's __TEXT segment. Nothing is symbolicated on
# the phone: Release builds carry no symbols. This reads every dSYM in the archive, matches each
# frame's UUID to one, and runs `atos` on it, printing the report with the symbol after each frame
# it could name. System frames stay as offsets (the Mac rarely has the device's system symbols).
#
# Prints to stdout; the report itself is not changed. Exits 2 on bad arguments, 1 when the report
# has no crash frames, and 0 otherwise — a frame with no matching dSYM is left as it was, and the
# summary on stderr says how many were named.
set -uo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <report.txt> <path.xcarchive>" >&2
  exit 2
fi
report=$1
archive=$2
if [[ ! -f "$report" ]]; then
  echo "error: no report at $report" >&2
  exit 2
fi
if [[ ! -d "$archive/dSYMs" ]]; then
  echo "error: $archive has no dSYMs folder (is it an .xcarchive?)" >&2
  exit 2
fi

frame_pattern='^[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}[[:space:]]+\+0x[0-9a-f]+[[:space:]]*$'
if ! grep -Eq "$frame_pattern" "$report"; then
  echo "error: no crash frames in $report" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# UUID → DWARF binary, one line each: "<UUID> <arch> <path>".
for dsym in "$archive"/dSYMs/*.dSYM; do
  [[ -d "$dsym" ]] || continue
  for binary in "$dsym"/Contents/Resources/DWARF/*; do
    [[ -f "$binary" ]] || continue
    dwarfdump --uuid "$binary" 2>/dev/null \
      | sed -nE 's/^UUID: ([0-9A-F-]+) \(([^)]+)\) .*$/\1 \2/p' \
      | while read -r uuid arch; do printf '%s %s %s\n' "$uuid" "$arch" "$binary"; done
  done
done > "$work/uuids"

# The __TEXT segment's load address in a binary: 0x100000000 for an arm64 executable, 0 for a
# framework.
text_vmaddr() {
  otool -arch "$2" -l "$1" 2>/dev/null | awk '
    $1 == "segname" && $2 == "__TEXT" { found = 1; next }
    found && $1 == "vmaddr" { print $2; exit }'
}

named=0
frames=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ $frame_pattern ]]; then
    frames=$((frames + 1))
    read -r _ _ uuid offset <<< "$line"
    entry=$(grep -m1 "^$uuid " "$work/uuids" || true)
    if [[ -n "$entry" ]]; then
      read -r _ arch binary <<< "$entry"
      base=$(text_vmaddr "$binary" "$arch")
      if [[ -n "$base" ]]; then
        address=$(printf '0x%x' $(( base + ${offset#+} )))
        symbol=$(atos -arch "$arch" -o "$binary" -l "$base" "$address" 2>/dev/null | head -1)
        if [[ -n "$symbol" && "$symbol" != "$address" ]]; then
          named=$((named + 1))
          printf '%s  %s\n' "$line" "$symbol"
          continue
        fi
      fi
    fi
  fi
  printf '%s\n' "$line"
done < "$report"

echo "symbolicate-crash-report: named $named of $frames frames from $(wc -l < "$work/uuids" | tr -d ' ') dSYM slices" >&2
exit 0
