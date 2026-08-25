// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenGlasses",
    platforms: [
        .iOS(.v26)
    ],
    dependencies: [
        // Meta Wearables Device Access Toolkit
        .package(url: "https://github.com/facebook/meta-wearables-dat-ios.git", from: "0.7.0"),
        // HaishinKit — RTMP live streaming
        .package(url: "https://github.com/shogo4405/HaishinKit.swift.git", from: "2.2.5"),
        // MLX Swift LM — on-device LLM inference. Pinned to the same revision as
        // `project.base.yml` (see the note there): no released tag carries the Gemma 4
        // VLM load fix, and a floating branch would silently move under us.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git",
                 revision: "d6614025fa1f6133e34c4fe0cea2815d672d8742"),
        // WebRTC — real peer-to-peer expert transport (Plan L)
        .package(url: "https://github.com/stasel/WebRTC.git", from: "120.0.0"),
    ],
    targets: [
        .target(
            name: "OpenGlasses",
            dependencies: [
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATCamera", package: "meta-wearables-dat-ios"),
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "OpenGlasses/Sources",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
