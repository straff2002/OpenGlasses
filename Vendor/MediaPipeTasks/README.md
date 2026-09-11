# MediaPipeTasks (vendored, fetched)

Google's MediaPipe Tasks Vision iOS frameworks (Apache-2.0), used by the Plan CK
fingerspelling landmark pipeline (`HolisticLandmarkService`). The large binaries
are fetched rather than committed. Run:

```sh
Scripts/fetch-mediapipe-frameworks.sh
```

This downloads the pinned, SHA-256-verified official CocoaPods artifacts into
`Frameworks/` (gitignored). Xcode Cloud runs it in `ci_scripts/ci_post_clone.sh`;
GitHub Actions uses the same fetch script. `Package.swift`, the shim, and the
upstream `LICENSE`/`NOTICE` remain committed.

## Holistic graph linking

MediaPipe Tasks 1.0.0 ships static framework binaries plus separate device and
simulator graph archives. The graph looks up calculators, subgraphs, inference
implementations, stream handlers, and executors by name. Ordinary linking drops
unreferenced registration objects. Blanket `-force_load` restores them but also
pulls in `fst_types.o`; its OpenFst initialisers hung before `main` in device
Release builds and XCTest (issues #304 and #309).

`holistic-link-anchors.json` retains 53 objects needed by `HolisticLandmarkService`:
the holistic face/pose/hand graph in video mode with the default CPU delegate,
including the Cpu and Xnnpack implementations. It does not promise GPU delegation
or unrelated MediaPipe tasks. Normal symbol references still pull in dependencies.

Some registration variables have local linkage (`b` in `nm`) and cannot satisfy
`-u`. Each entry instead names an external symbol in the same registration object.
The fetch script runs `Scripts/prepare-mediapipe-linking.py` on cache hits as well
as downloads. It verifies the version and unique symbol-to-object mapping in all
three architectures (device arm64, simulator arm64 and x86_64), then writes
`Frameworks/holistic-linker-flags.rsp`. Both Debug and Release consume that file.
`-ObjC` retains Tasks API categories, including `NSString`'s `cppString`; otherwise
the API throws an unrecognised-selector exception before constructing the graph.

## Reproducing the smoke test

After fetching the frameworks, supply the holistic model and a photograph with a
visible person, then run against an already booted simulator:

```sh
python3 -B -m unittest discover -s Scripts/tests -p test_mediapipe_linking.py -v
python3 Scripts/smoke-mediapipe.py \
  --model /absolute/path/holistic_landmarker.task \
  --image /absolute/path/pose.jpg \
  --simulator <simulator-udid> --output /tmp/mediapipe-smoke
```

The smoke uses optimisation and dead stripping, consumes the production linker
response file, rejects a link map containing `fst_types.o` or `FstRegisterer`, and
requires three video-mode inferences with 33 finite pose landmarks. It records
the face and hand counts too. The CI test job downloads checksum-pinned public
MediaPipe fixtures and runs this test before the app's unit suite.

This checks the graph itself. Before closing #309, also cold-launch the full
Release app on hardware without a debugger, verify the UI remains responsive
past the 20-second watchdog window, and run the CK P3 fingerspelling smoke with
the downloaded model. Simulator inference does not prove device startup or
end-to-end decoding.

## Updating MediaPipe

Update the fetch version and checksums, then rederive the manifest from graph
construction errors and the new archive's external symbols. Verify both the
owning object and its registration initialiser; a matching class name alone is
insufficient. Repeat the real graph smoke and hardware checks. Do not restore
blanket `-force_load` or `-all_load` to get past a missing registration.
