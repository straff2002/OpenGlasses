// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenGlasses",
    platforms: [
        .iOS(.v26)
    ],
    dependencies: [
        // Meta Wearables Device Access Toolkit
        .package(url: "https://github.com/facebook/meta-wearables-dat-ios.git", from: "0.3.0"),

    ],
    targets: [
        .target(
            name: "OpenGlasses",
            dependencies: [
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATCamera", package: "meta-wearables-dat-ios"),
            ],
            path: "OpenGlasses/Sources",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
