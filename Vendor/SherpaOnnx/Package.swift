// swift-tools-version: 5.9
import PackageDescription

// Local SPM wrapper that vendors the sherpa-onnx + onnxruntime static iOS xcframeworks for the
// on-device Kokoro TTS tier (Additional Capabilities #1). The binaries are built from k2-fsa
// source paired with onnxruntime and committed under Frameworks/. `SherpaOnnxWrapper` re-exports
// the `sherpa_onnx` C module and carries the link settings the static libs need (libc++,
// Accelerate).
//
// The upstream versions and licences live in REVISION beside this file, in the machine-readable
// shape Scripts/generate-sbom.sh reads. They used to live only in this comment, where nothing
// could read them and nothing would notice them going stale.
let package = Package(
    name: "SherpaOnnx",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SherpaOnnxWrapper", targets: ["SherpaOnnxWrapper"]),
    ],
    targets: [
        .binaryTarget(name: "sherpa-onnx", path: "Frameworks/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Frameworks/onnxruntime.xcframework"),
        .target(
            name: "SherpaOnnxWrapper",
            dependencies: ["sherpa-onnx", "onnxruntime"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
