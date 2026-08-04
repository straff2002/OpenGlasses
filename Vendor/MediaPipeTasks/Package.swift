// swift-tools-version: 5.9
import PackageDescription

// Local SPM wrapper that vendors the MediaPipe Tasks Vision iOS static xcframeworks for the
// Plan CK fingerspelling landmark pipeline (hand + pose + face via the holistic landmarker).
// The binaries are Google's official CocoaPods artefacts (MediaPipeTasksVision +
// MediaPipeTasksCommon 1.0.0, Apache-2.0) but are too large to commit (the graph static
// libraries alone are 1.2 GB, over GitHub's file limit) — run
// `Scripts/fetch-mediapipe-frameworks.sh` once after cloning to populate `Frameworks/`
// (CI does this in `ci_scripts/ci_post_clone.sh`).
//
// The graph runtime additionally needs a per-SDK `-force_load` of
// `Frameworks/graph_libraries/libMediaPipeTasksCommon_{device,simulator}_graph.a` — SPM cannot
// express sim-vs-device linker flags, so the app target carries those in `project.base.yml`
// (`OTHER_LDFLAGS[sdk=...]`).
let package = Package(
    name: "MediaPipeTasks",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MediaPipeTasksShim", targets: ["MediaPipeTasksShim"]),
    ],
    targets: [
        .binaryTarget(name: "MediaPipeTasksVision",
                      path: "Frameworks/MediaPipeTasksVision.xcframework"),
        .binaryTarget(name: "MediaPipeTasksCommon",
                      path: "Frameworks/MediaPipeTasksCommon.xcframework"),
        .target(
            name: "MediaPipeTasksShim",
            dependencies: ["MediaPipeTasksVision", "MediaPipeTasksCommon"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
