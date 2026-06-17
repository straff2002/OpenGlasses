// swift-tools-version: 5.9
import PackageDescription

// Local SPM wrapper that vendors the sherpa-onnx + onnxruntime static iOS xcframeworks for the
// on-device Kokoro TTS tier (Additional Capabilities #1). The binaries are built from k2-fsa source
// (sherpa-onnx 1.13.3, Apache-2.0) paired with onnxruntime 1.26.0 (MIT) and committed under
// Frameworks/. `SherpaOnnxWrapper` re-exports the `sherpa_onnx` C module and carries the link
// settings the static libs need (libc++, Accelerate).
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
