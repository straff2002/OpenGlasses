import XCTest
@testable import OpenGlasses

/// Keeps DAT's Mock Device Kit in its development lane (Plan KV P4).
///
/// The simulated Display links `MWDATMockDevice` only through `project.mock-display.yml`, which
/// `generate-xcodeproj.sh` adds only under `AVENKIN_DAT_MOCK_DISPLAY=1` and refuses under CI or
/// Xcode Cloud. Meta's guidance is that the mock and its preview stay out of production builds;
/// this guard fails the ordinary, unflagged suite when that stops being true by construction:
/// - a Swift file under `OpenGlasses/Sources` imports `MWDATMockDevice` or names a mock type
///   outside `Sources/Glasses/MockDisplay/`;
/// - a file in that folder is not wrapped whole in `#if DAT_MOCK_DISPLAY … #endif`;
/// - a committed spec other than `project.mock-display.yml` names the mock product;
/// - the lane loses its refusals (the CI markers in the script, the Debug-and-Simulator phase).
final class MockDisplayLaneGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static let folder = "OpenGlasses/Sources/Glasses/MockDisplay/"
    private static let laneSpec = "project.mock-display.yml"
    /// What only the mock lane may say: the module, and the mock's types.
    private static let mockTokens = ["MWDATMockDevice", "MockDeviceKit", "MockDisplayKit", "MockGlasses",
                                     "MockDeviceTestClient", "MockCameraKit", "MockInputKit"]

    private func swiftSources() throws -> [(path: String, text: String)] {
        let root = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("no sources at \(root.path)"); return []
        }
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(files.count, 500, "the source scan found too few files to be the app")
        return files
    }

    /// Code lines only: a comment may name the mock (this lane is documented in comments).
    private func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("//") && !line.hasPrefix("///") && !line.hasPrefix("*") && !line.hasPrefix("/*")
        }
    }

    func testMockIsUsedOnlyInsideItsFolder() throws {
        var offenders: [String] = []
        for (path, text) in try swiftSources() where !path.hasPrefix(Self.folder) {
            for line in codeLines(text) where Self.mockTokens.contains(where: { line.contains($0) }) {
                offenders.append("\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "DAT's Mock Device Kit may be used only in \(Self.folder), under #if DAT_MOCK_DISPLAY")
    }

    func testEveryFileInTheFolderIsWrappedWhole() throws {
        let inFolder = try swiftSources().filter { $0.path.hasPrefix(Self.folder) }
        XCTAssertFalse(inFolder.isEmpty, "the simulated Display's folder has gone; update this guard with it")
        for (path, text) in inFolder {
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            XCTAssertEqual(lines.first, "#if DAT_MOCK_DISPLAY", "\(path) must open with #if DAT_MOCK_DISPLAY")
            XCTAssertEqual(lines.last, "#endif", "\(path) must close with the #endif of that #if")
            // One top-level conditional: every #if inside is closed before the last line.
            var depth = 0
            for (index, line) in lines.enumerated() {
                if line.hasPrefix("#if") { depth += 1 }
                if line.hasPrefix("#endif") { depth -= 1 }
                if depth == 0, index < lines.count - 1 {
                    XCTFail("\(path): code after the DAT_MOCK_DISPLAY block closes (line \(index + 1) of non-blank lines)")
                    break
                }
            }
        }
    }

    func testOnlyTheLaneSpecNamesTheMockProduct() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.path)
            .filter { $0.hasPrefix("project.") && ($0.hasSuffix(".yml") || $0.hasSuffix(".yml.example")) }
        XCTAssertTrue(names.contains(Self.laneSpec))
        for name in names {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(name), encoding: .utf8)
            if name == Self.laneSpec {
                XCTAssertTrue(text.contains("product: MWDATMockDevice"), "\(name) is the lane: it links the mock")
                XCTAssertTrue(text.contains("DAT_MOCK_DISPLAY"))
                // The build phase that fails anything but a Debug build for the Simulator.
                XCTAssertTrue(text.contains("\"${CONFIGURATION}\" != \"Debug\""), "\(name) must refuse a non-Debug build")
                XCTAssertTrue(text.contains("\"${PLATFORM_NAME}\" != \"iphonesimulator\""), "\(name) must refuse a device build")
                XCTAssertTrue(text.contains("\"${ACTION}\" = \"install\""), "\(name) must refuse an archive")
            } else {
                XCTAssertFalse(text.contains("MWDATMockDevice"), "\(name) names the mock product; only \(Self.laneSpec) may")
                XCTAssertFalse(text.contains("DAT_MOCK_DISPLAY"), "\(name) defines the mock lane's condition")
            }
        }
    }

    func testTheGeneratorAddsTheLaneOnlyOnRequestAndNeverUnderCI() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("Scripts/generate-xcodeproj.sh"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("if [[ \"$mock_display\" == \"1\" ]]; then\n    echo \"  - \(Self.laneSpec)\""),
                      "the lane spec is included only when AVENKIN_DAT_MOCK_DISPLAY=1")
        for marker in ["CI", "CI_XCODE_CLOUD", "CI_WORKFLOW", "GITHUB_ACTIONS"] {
            XCTAssertTrue(script.range(of: "for marker in [^\\n]*\\b\(marker)\\b", options: .regularExpression) != nil,
                          "the generator must refuse the mock lane when \(marker) is set")
        }
        XCTAssertEqual(script.components(separatedBy: Self.laneSpec).count - 1, 1,
                       "the lane spec is named once, in its guarded include")
    }

    /// The ordinary build, the one every PR tests and every archive is made from, has no mock.
    func testTheOrdinaryBuildDoesNotCompileTheMock() {
        #if DAT_MOCK_DISPLAY
        XCTFail("DAT_MOCK_DISPLAY is defined: this suite ran on a project generated with the simulated Display")
        #endif
    }
}
