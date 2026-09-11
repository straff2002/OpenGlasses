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
// The graph runtime also needs a per-SDK archive and selective registration anchors.
// Scripts/fetch-mediapipe-frameworks.sh validates holistic-link-anchors.json and generates
// Frameworks/holistic-linker-flags.rsp. The app applies it plus -ObjC in project.base.yml
// because SPM cannot express these per-SDK archive paths. Do not force-load the full archive:
// its OpenFst static initialisers hang before main (issues #304 and #309).
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
