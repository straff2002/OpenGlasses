// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeGlasses",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "ClaudeGlasses",
            targets: ["ClaudeGlasses"]
        ),
    ],
    dependencies: [
        // Meta Wearables Device Access Toolkit
        .package(url: "https://github.com/facebook/meta-wearables-dat-ios.git", from: "0.3.0"),

        // WhisperKit for on-device speech-to-text
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ClaudeGlasses",
            dependencies: [
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATCamera", package: "meta-wearables-dat-ios"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "ClaudeGlasses/Sources"
        ),
    ]
)
