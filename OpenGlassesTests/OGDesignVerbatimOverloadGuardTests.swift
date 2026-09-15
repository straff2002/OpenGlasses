import XCTest

/// Keeps literal copy in the design kit on the localized path.
///
/// Each component that takes a `LocalizedStringKey` also has a generic `StringProtocol`
/// initializer for runtime text (model names, self-test entries). Swift ranks a string literal's
/// default type, `String`, above `LocalizedStringKey`, so without `@_disfavoredOverload` on the
/// generic form every literal at a call site — `OGRow("Copy Report")` — quietly takes the verbatim
/// path. Nothing fails: the English reads the same, but the string never reaches
/// `Localizable.xcstrings` and is never translated. SwiftUI's own `Text` avoids this the same way.
///
/// That regression shipped once (and cost more than half the kit's row, status and notice copy
/// its catalog entries) because the attribute is invisible at the call site. This scan is the
/// thing that notices it going missing.
final class OGDesignVerbatimOverloadGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The design kit's source files.
    private static let componentsDirectory = "OpenGlasses/Sources/App/Views/Components"

    // MARK: - Scanner

    struct Finding: Equatable {
        let typeName: String
        let line: Int
        let disfavored: Bool
    }

    /// Every generic `StringProtocol` initializer that shares a top-level type or extension block
    /// with a `LocalizedStringKey` initializer, and whether `@_disfavoredOverload` sits among the
    /// attribute lines directly above it.
    static func verbatimSiblingInitializers(in source: String) -> [Finding] {
        let lines = source.components(separatedBy: "\n")
        let blockStart = try! NSRegularExpression(
            pattern: #"^(?:(?:public|internal|fileprivate|private)\s+)?(?:final\s+)?(?:struct|class|enum|extension)\s+(\w+)"#
        )
        // Split into top-level blocks. Declarations nested inside a type are indented, so only a
        // column-zero `struct`/`extension`/… starts a new block.
        var blocks: [(name: String, firstLine: Int, lines: [String])] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = blockStart.firstMatch(in: line, range: range),
               let nameRange = Range(match.range(at: 1), in: line) {
                blocks.append((String(line[nameRange]), index, [line]))
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].lines.append(line)
            }
        }

        let localizedInit = try! NSRegularExpression(pattern: #"\binit\s*\([^)]*LocalizedStringKey"#)
        var findings: [Finding] = []
        for block in blocks {
            let text = block.lines.joined(separator: "\n")
            guard localizedInit.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
                continue
            }
            for (offset, line) in block.lines.enumerated() {
                guard line.range(of: #"\binit\s*<"#, options: .regularExpression) != nil else { continue }
                // The signature runs to the body's opening brace; `where S: StringProtocol` counts too.
                let signature = block.lines[offset...].joined(separator: "\n")
                    .prefix { $0 != "{" }
                guard signature.contains("StringProtocol") else { continue }

                var disfavored = false
                var above = offset - 1
                while above >= 0 {
                    let attribute = block.lines[above].trimmingCharacters(in: .whitespaces)
                    guard attribute.hasPrefix("@") else { break }
                    if attribute.hasPrefix("@_disfavoredOverload") { disfavored = true }
                    above -= 1
                }
                findings.append(Finding(
                    typeName: block.name, line: block.firstLine + offset + 1, disfavored: disfavored
                ))
            }
        }
        return findings
    }

    // MARK: - The guard

    func testVerbatimInitializersBesideLocalizedOnesAreDisfavored() throws {
        let directory = Self.repoRoot.appendingPathComponent(Self.componentsDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(files.isEmpty, "No Swift files under \(Self.componentsDirectory)")

        var total = 0
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for finding in Self.verbatimSiblingInitializers(in: source) {
                total += 1
                XCTAssertTrue(
                    finding.disfavored,
                    "\(file):\(finding.line): the generic StringProtocol init on \(finding.typeName) "
                        + "needs @_disfavoredOverload directly above it. Without it, string literals "
                        + "at call sites resolve to this verbatim form instead of the "
                        + "LocalizedStringKey one and never reach the string catalog."
                )
            }
        }
        // OGRow ×2, OGBadge, OGNotice, OGStatusLabel. A lower count means the scan stopped
        // recognising the shape, not that the overloads went away — fail rather than pass vacuously.
        XCTAssertGreaterThanOrEqual(total, 5, "Scan found only \(total) verbatim initializers; has the pattern changed?")
    }

    /// The scanner has to be able to fail, or the guard above proves nothing.
    func testScannerFlagsAnUndecoratedOverload() {
        let fixture = """
        struct Chip: View {
            init(_ text: LocalizedStringKey) {}

            /// Runtime copy.
            init<S: StringProtocol>(_ text: S) {}
        }

        struct Tag: View {
            init(_ text: LocalizedStringKey) {}

            @MainActor
            @_disfavoredOverload
            init<S>(_ text: S) where S: StringProtocol {}
        }

        struct Plain: View {
            init<S: StringProtocol>(_ text: S) {}
        }
        """
        XCTAssertEqual(Self.verbatimSiblingInitializers(in: fixture), [
            Finding(typeName: "Chip", line: 5, disfavored: false),
            Finding(typeName: "Tag", line: 13, disfavored: true),
        ])
    }
}
