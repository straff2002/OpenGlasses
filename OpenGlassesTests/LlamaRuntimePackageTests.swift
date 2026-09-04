import CryptoKit
import XCTest
@testable import OpenGlasses

/// Guards the vendored llama.cpp package's pin and its recorded digests (Plan DZ P1/PR2).
///
/// The engine binary is not committed — it is built by `Scripts/build-llamacpp-framework.sh` and
/// obtained by `Scripts/fetch-llamacpp-framework.sh`. What *is* committed is the promise about it:
/// `REVISION` says which sources, `SHA256SUMS` says which bytes, `BUILD-INFO` says what produced
/// them. Those three files are only worth anything if they cannot quietly rot, so this asserts
/// their shape and their agreement with each other.
///
/// Two of the checks need the framework itself and are skipped with a message when it is absent,
/// so a clean clone that has not run the fetch script still passes the suite. Skipping is the
/// right call rather than failing: the file is deliberately not in the repository, and a suite
/// that cannot be run until a 50 MB build finishes is a suite people stop running. The fetch
/// script — wired into CI post-clone — is how the skip stops being taken.
final class LlamaRuntimePackageTests: XCTestCase {

    // MARK: - Repo anchor
    //
    // Same anchor as the telemetry and privacy-logging guards: `#filePath` is baked in at compile
    // time, and the simulator shares the host filesystem.

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static var packageRoot: URL { repoRoot.appendingPathComponent("Vendor/LlamaCpp") }

    private func packageText(_ name: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(name), encoding: .utf8)
    }

    /// `key=value` lines, `#` comments ignored — the format the two shell scripts parse.
    private func keyedValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }   // first wins, as `head -n 1` does
        }
        return values
    }

    private func revision() throws -> [String: String] { keyedValues(try packageText("REVISION")) }

    // MARK: - The pin

    func testRevisionPinsAnExactCommitOnTheExpectedRepository() throws {
        let pin = try revision()

        let repository = try XCTUnwrap(pin["repository"], "REVISION must declare repository=")
        XCTAssertEqual(repository, "https://github.com/ggml-org/llama.cpp.git",
                       "the engine is expected to come from upstream llama.cpp, not a fork")
        XCTAssertTrue(repository.hasPrefix("https://"), "the engine source must be fetched over HTTPS")

        let tag = try XCTUnwrap(pin["tag"], "REVISION must declare tag=")
        XCTAssertFalse(tag.isEmpty)

        let commit = try XCTUnwrap(pin["commit"], "REVISION must declare commit=")
        XCTAssertEqual(commit.count, 40, "commit= must be a full sha, not an abbreviation: \(commit)")
        XCTAssertTrue(commit.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "commit= must be lowercase hex: \(commit)")
    }

    /// The plan's rule is "never build a moving branch". A `branch=` key would be exactly that,
    /// and a tag alone would be one too — tags can be repointed.
    func testRevisionDoesNotPinAMovingTarget() throws {
        let pin = try revision()
        XCTAssertNil(pin["branch"], "REVISION must not pin a branch — pin the commit")
        XCTAssertNotNil(pin["commit"], "a tag alone is not a pin; tags can be moved")
    }

    // MARK: - The digests

    func testChecksumsAreWellFormedAndCoverBothSlices() throws {
        let lines = try packageText("SHA256SUMS")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertFalse(lines.isEmpty, "SHA256SUMS is empty — nothing is being verified")

        var paths: [String] = []
        for line in lines {
            // `shasum -a 256` format: 64 hex, two spaces, path. `shasum -c` reads exactly this,
            // so a line that does not match is a line that silently verifies nothing.
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(parts.count, 2, "malformed SHA256SUMS line: \(line)")
            guard parts.count == 2 else { continue }
            XCTAssertEqual(parts[0].count, 64, "not a sha256 digest: \(parts[0])")
            XCTAssertTrue(parts[0].allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          "digest must be lowercase hex: \(parts[0])")
            XCTAssertTrue(parts[1].hasPrefix("Frameworks/llama.xcframework/"),
                          "SHA256SUMS must only cover the vendored framework, found: \(parts[1])")
            XCTAssertFalse(parts[1].contains(".."), "no traversal in a recorded path: \(parts[1])")
            paths.append(parts[1])
        }

        XCTAssertTrue(paths.contains("Frameworks/llama.xcframework/Info.plist"),
                      "the xcframework manifest itself must be covered")
        let libraries = paths.filter { $0.hasSuffix("/libllama.a") }
        XCTAssertEqual(libraries.count, 2,
                       "expected a device and a simulator slice, found: \(libraries)")
        XCTAssertTrue(libraries.contains { $0.contains("simulator") },
                      "no simulator slice recorded: \(libraries)")
        XCTAssertTrue(libraries.contains { !$0.contains("simulator") },
                      "no device slice recorded: \(libraries)")
    }

    func testBuildInfoAgreesWithThePin() throws {
        let pin = try revision()
        let info = keyedValues(try packageText("BUILD-INFO"))

        XCTAssertEqual(info["revision"], pin["commit"],
                       "BUILD-INFO records digests for a different revision than REVISION pins")
        XCTAssertEqual(info["tag"], pin["tag"])
        XCTAssertNotNil(info["options_digest"], "BUILD-INFO must fingerprint the build options")
        XCTAssertNotNil(info["xcodebuild"], "BUILD-INFO must record the toolchain")

        // The engine's minimum has to be the app's, otherwise the binary is built against a
        // different floor than everything linking it.
        let spec = try String(contentsOf: Self.repoRoot.appendingPathComponent("project.base.yml"),
                              encoding: .utf8)
        let target = try XCTUnwrap(info["ios_deployment_target"])
        XCTAssertTrue(spec.contains("iOS: \"\(target)\""),
                      "the framework targets iOS \(target), which project.base.yml no longer declares")
    }

    // MARK: - The binary, when it is here

    /// The whole point of recorded digests is that they match something. Verifying every file
    /// keeps the check honest about the artefact rather than about the file listing.
    func testRecordedChecksumsMatchTheBuiltFramework() throws {
        let frameworkPath = Self.packageRoot.appendingPathComponent("Frameworks/llama.xcframework")
        try skipUnlessFrameworkPresent(frameworkPath)

        for line in try packageText("SHA256SUMS").split(separator: "\n") {
            let parts = line.components(separatedBy: "  ")
            guard parts.count == 2 else { continue }
            let url = Self.packageRoot.appendingPathComponent(parts[1])
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Self.sha256Hex(data), parts[0],
                           "\(parts[1]) does not match its recorded digest — rebuild or re-fetch")
        }
    }

    /// The engine reports its own revision, stamped in at build time from `REVISION`. This is the
    /// check that catches a framework built from some *other* revision sitting in a working copy
    /// whose `REVISION` file says otherwise.
    func testEngineReportsThePinnedRevision() throws {
        try skipUnlessFrameworkPresent(
            Self.packageRoot.appendingPathComponent("Frameworks/llama.xcframework"))
        let pin = try revision()

        XCTAssertEqual(LlamaRuntimeAvailability.engineRevision, pin["commit"],
                       "the linked engine reports a different revision than REVISION pins")
        XCTAssertEqual(LlamaRuntimeAvailability.engineTag, pin["tag"])
        XCTAssertTrue(LlamaRuntimeAvailability.engineDescription.contains(pin["tag"] ?? "—"))
    }

    // MARK: - Linked is not enabled

    /// PR2's exit criterion: linking the engine changes nothing about how the app behaves. The
    /// availability shim is the app's only contact with it, and it is inert while the flag is off.
    func testLinkingTheEngineDoesNotEnableIt() {
        XCTAssertEqual(LlamaRuntimeAvailability.isEnabled, Config.ggufModelsEnabled,
                       "the shim must read the shipping flag, not a second copy of it")
        XCTAssertFalse(Config.ggufModelsEnabled, "GGUF models ship off")
    }

    // MARK: - The notices

    func testNoticesRecordTheLicenceAndTheRevision() throws {
        let notices = try packageText("NOTICES.md")
        let pin = try revision()

        XCTAssertTrue(notices.contains("MIT"), "llama.cpp's MIT licence must be recorded")
        XCTAssertTrue(notices.contains("The ggml authors"), "attribution must be recorded")
        XCTAssertTrue(notices.contains(try XCTUnwrap(pin["commit"])),
                      "NOTICES.md names a different revision than REVISION pins")
    }

    /// The binary is deliberately not committed; an ignore rule that goes missing is how a 50 MB
    /// artefact ends up in a source commit.
    func testTheFrameworkIsIgnoredAndThePinIsNot() throws {
        let ignores = try String(contentsOf: Self.repoRoot.appendingPathComponent(".gitignore"),
                                 encoding: .utf8)
        XCTAssertTrue(ignores.contains("Vendor/LlamaCpp/Frameworks/"),
                      ".gitignore must keep the built engine out of commits")
        XCTAssertTrue(ignores.contains("Vendor/LlamaCpp/.build/"),
                      ".gitignore must keep the upstream checkout and cmake trees out of commits")
        XCTAssertFalse(ignores.contains("Vendor/LlamaCpp/REVISION"),
                       "the pin is the tracked half of this arrangement")
    }

    // MARK: - Helpers

    private func skipUnlessFrameworkPresent(_ url: URL,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("""
                Vendor/LlamaCpp/Frameworks/llama.xcframework is not present. It is built, not \
                committed — run Scripts/fetch-llamacpp-framework.sh to obtain it. The pin and \
                digest checks in this file still ran.
                """, file: file, line: line)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
