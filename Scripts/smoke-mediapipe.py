#!/usr/bin/env python3
"""Compile and run the holistic graph with Release-style linking on a booted iOS simulator.

Uses the same generated linker configuration as OpenGlasses. Supply a real model
and a photograph with a visible person: accepting blank frames is not a pass.
The model and photograph are test inputs, never copied into the shipping app.
"""

import argparse
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--simulator", required=True, help="UDID of a booted simulator")
    parser.add_argument("--output", type=Path, help="Directory for executable, linker map, and logs")
    args = parser.parse_args()
    for path in [args.model, args.image]:
        if not path.is_file():
            parser.error(f"Test input does not exist: {path}")
    frameworks = ROOT / "Vendor/MediaPipeTasks/Frameworks"
    config = frameworks / "holistic-linker-flags.xcconfig"
    if not config.is_file():
        parser.error("Run Scripts/fetch-mediapipe-frameworks.sh first")
    settings = [line.partition("=")[2].strip() for line in config.read_text().splitlines()
                if line.startswith("MEDIAPIPE_HOLISTIC_LDFLAGS =")]
    if len(settings) != 1:
        parser.error("Invalid generated MediaPipe linker configuration")
    linker_flags = shlex.split(settings[0])
    output = (args.output or Path(tempfile.mkdtemp(prefix="mediapipe-smoke-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    arch = platform.machine()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    command = ["xcrun", "clang", "-target", f"{arch}-apple-ios26.0-simulator", "-isysroot", sdk,
               "-fobjc-arc", "-fmodules", f"-fmodules-cache-path={output / 'modules'}", "-O2",
               str(ROOT / "Scripts/mediapipe-smoke/main.m"), "-o", str(output / "smoke"),
               "-Wl,-dead_strip", f"-Wl,-map,{output / 'link.map'}"] + linker_flags
    for name in ["MediaPipeTasksVision", "MediaPipeTasksCommon"]:
        command += ["-F", str(frameworks / f"{name}.xcframework/ios-arm64_x86_64-simulator"), "-framework", name]
    for name in ["Foundation", "UIKit", "Accelerate", "AudioToolbox", "AVFoundation", "CoreMedia",
                 "CoreVideo", "CoreImage", "QuartzCore"]:
        command += ["-framework", name]
    command += ["-lc++", str(frameworks / "graph_libraries/libMediaPipeTasksCommon_simulator_graph.a")]
    with (output / "build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    link_map = (output / "link.map").read_text(errors="replace")
    if re.search(r"\(fst_types\.o\)|FstRegisterer", link_map):
        raise ValueError("OpenFst registration unexpectedly linked; do not launch this binary")
    result = subprocess.run(["xcrun", "simctl", "spawn", args.simulator, str(output / "smoke"),
                             str(args.model.resolve()), str(args.image.resolve())],
                            capture_output=True, text=True, timeout=45)
    log = result.stdout + result.stderr
    (output / "run.log").write_text(log)
    print(log)
    print(f"Smoke artifacts: {output}")
    result.check_returncode()
    if "MediaPipe smoke: PASS" not in log:
        raise ValueError("Process exited without completing inference")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"MediaPipe smoke failed: {error}")
