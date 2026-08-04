# MediaPipeTasks (vendored, fetched)

Google's MediaPipe Tasks Vision iOS frameworks (Apache-2.0), used by the Plan CK
fingerspelling landmark pipeline (`HolisticLandmarkService`).

Unlike `Vendor/SherpaOnnx`, the binaries are **not committed**: the graph static libraries
(`libMediaPipeTasksCommon_{device,simulator}_graph.a`) are 410 MB / 818 MB — over GitHub's
100 MB per-file hard limit. Instead:

```bash
Scripts/fetch-mediapipe-frameworks.sh
```

downloads the pinned, sha256-verified official CocoaPods artefacts from `dl.google.com`
into `Frameworks/` (gitignored). CI runs the same script in `ci_scripts/ci_post_clone.sh`.

`Package.swift`, the shim source, and the upstream `LICENSE`/`NOTICE` are committed.
The per-SDK `-force_load` of the graph libraries lives on the app target in
`project.base.yml` (SPM cannot express sim-vs-device linker flags).
