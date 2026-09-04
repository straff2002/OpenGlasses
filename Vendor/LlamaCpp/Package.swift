// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Local SPM package vendoring the llama.cpp inference engine for the GGUF local-model runtime
// (Plan DZ P1). Two pieces:
//
//   * `llama` — a static xcframework built from the exact revision pinned in `REVISION` by
//     `Scripts/build-llamacpp-framework.sh`. The binary is NOT committed (repo policy for large
//     generated artefacts, as with MediaPipe); `Scripts/fetch-llamacpp-framework.sh` obtains it,
//     and `SHA256SUMS` is what a clean clone verifies it against.
//   * `LlamaCppWrapper` — a small Objective-C++ file behind an intentionally minimal C ABI. The
//     engine is C++ whose types move between releases; only C crosses into Swift, so an engine
//     bump is a rebuild here rather than a source break across the app.
//
// The platform line below is the floor for *this package's* sources. The engine binary's real
// minimum is the app's deployment target, which the build script reads out of project.base.yml
// rather than keeping a second copy of. Compile settings are recorded in NOTICES.md, and the
// build script asserts them back out of the cmake cache so a differently-configured engine
// cannot ship under the same revision.
let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LlamaCppWrapper", targets: ["LlamaCppWrapper"]),
    ],
    targets: [
        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
        .target(
            name: "LlamaCppWrapper",
            dependencies: ["llama"],
            cSettings: EnginePin.pairs.map { .define($0.name, to: $0.value) },
            cxxSettings: EnginePin.pairs.map { .define($0.name, to: $0.value) },
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)

/// The pin, read from `REVISION` so the binary reports the revision the repository actually
/// declares rather than a second copy of it typed into this manifest. When the file cannot be
/// read the defines are simply absent and the wrapper answers "unknown" — an honest gap beats a
/// stale constant that states the wrong thing with confidence.
private enum EnginePin {
    static let pairs: [(name: String, value: String)] = {
        guard let text = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("REVISION"),
            encoding: .utf8
        ) else { return [] }

        func value(_ key: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
                return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        guard let commit = value("commit"), let tag = value("tag") else { return [] }
        return [
            (name: "OG_LLAMA_ENGINE_REVISION", value: "\"\(commit)\""),
            (name: "OG_LLAMA_ENGINE_TAG", value: "\"\(tag)\""),
        ]
    }()
}
