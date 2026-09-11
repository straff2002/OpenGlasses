#!/usr/bin/env python3
"""Validate the pinned holistic registration anchors and emit an ld response file.

Run by fetch-mediapipe-frameworks.sh on both a download and a cache hit. Validate
each shipped architecture: a library update must fail here rather than silently
producing a shipping build whose graph cannot be constructed.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/MediaPipeTasks"
SYMBOL_LINE = re.compile(r":([^:]+):\s+[0-9a-fA-F]+\s+[A-Z]\s+(\S+)$")


def validate_symbols(anchors, lines):
    found = {symbol: set() for symbol in anchors.values()}
    for line in lines:
        match = SYMBOL_LINE.search(line)
        if match and match[2] in found:
            found[match[2]].add(match[1])
    errors = []
    for member, symbol in anchors.items():
        if found[symbol] != {member}:
            errors.append(f"{member}: expected unique external anchor {symbol}; "
                          f"found in {sorted(found[symbol])}")
    if errors:
        raise ValueError("\n".join(errors))


def response_text(anchors):
    return "".join(f"-u\n{symbol}\n" for symbol in anchors.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Version pinned by the fetch script")
    args = parser.parse_args()
    manifest = json.loads((VENDOR / "holistic-link-anchors.json").read_text())
    if manifest["mediapipe_version"] != args.version:
        raise ValueError("MediaPipe version changed: rederive and smoke-test the holistic anchors")
    anchors = manifest["anchors"]
    if not anchors or len(set(anchors.values())) != len(anchors):
        raise ValueError("Expected a nonempty list of unique registration anchors")
    for member, symbol in anchors.items():
        if not re.fullmatch(r"[a-z0-9_]+\.o", member) or not re.fullmatch(r"__Z\w+", symbol):
            raise ValueError(f"Invalid anchor: {member}: {symbol}")
        if member == "fst_types.o" or "FstRegisterer" in symbol:
            raise ValueError("OpenFst registration must not be forced into the holistic graph")

    output = VENDOR / "Frameworks/holistic-linker-flags.rsp"
    # Do not leave a stale response file usable after a failed validation.
    output.unlink(missing_ok=True)
    for sdk, arch in [("device", "arm64"), ("simulator", "arm64"), ("simulator", "x86_64")]:
        archive = VENDOR / f"Frameworks/graph_libraries/libMediaPipeTasksCommon_{sdk}_graph.a"
        # -g -U excludes local and undefined symbols: -u cannot anchor those.
        result = subprocess.run(
            ["xcrun", "nm", "-arch", arch, "-g", "-U", "-A", str(archive)],
            capture_output=True, text=True, check=True,
        )
        try:
            validate_symbols(anchors, result.stdout.splitlines())
        except ValueError as error:
            raise ValueError(f"{sdk}/{arch}: {error}") from error
        print(f"MediaPipe {args.version}: {len(anchors)} anchors verified ({sdk}/{arch})")
    output.write_text(response_text(anchors))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"MediaPipe linking validation failed: {error}")
