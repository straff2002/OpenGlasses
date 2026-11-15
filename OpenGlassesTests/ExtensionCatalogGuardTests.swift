import XCTest

/// The widget, the watch app and the watch widget each run in their own bundle. A
/// `String(localized:)` or `Text("…")` in them looks up that bundle's strings, not the app's, so
/// each carries a small `Localizable.xcstrings` with the keys it shows. Without one, a phone set to
/// Japanese gets a Japanese app and an English widget.
///
/// Translations are made once, in the app's catalog. `Scripts/sync-extension-catalogs.py` copies
/// each key's entry into the extension catalogs, and this guard fails when a copy has drifted.
/// That covers a translation corrected in the app's catalog but not re-copied, or a key added to
/// a widget but never translated.
final class ExtensionCatalogGuardTests: XCTestCase {

    /// The extension catalogs, and the spec that bundles each one by including its whole folder.
    private static let extensionCatalogs: [(path: String, spec: String, folder: String)] = [
        ("GlassesActivityWidget/Localizable.xcstrings", "project.base.yml", "GlassesActivityWidget"),
        ("OpenGlassesWatch/Localizable.xcstrings", "project.watch.yml", "OpenGlassesWatch"),
        ("OpenGlassesWatchWidget/Localizable.xcstrings", "project.watch.yml", "OpenGlassesWatchWidget"),
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static func strings(at path: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
        XCTAssertEqual(root["sourceLanguage"] as? String, "en", path)
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]], path)
    }

    func testEveryExtensionCatalogMatchesTheAppCatalog() throws {
        let app = try Self.strings(at: "OpenGlasses/Sources/Resources/Localizable.xcstrings")
        for catalog in Self.extensionCatalogs {
            let strings = try Self.strings(at: catalog.path)
            XCTAssertFalse(strings.isEmpty, "\(catalog.path) is empty")
            var drifted: [String] = []
            for (key, entry) in strings {
                guard var expected = app[key] else {
                    drifted.append("\(key) — not in the app's catalog")
                    continue
                }
                expected.removeValue(forKey: "extractionState")
                var actual = entry
                actual.removeValue(forKey: "extractionState")
                if !NSDictionary(dictionary: expected).isEqual(to: actual) { drifted.append(key) }
            }
            XCTAssertTrue(drifted.isEmpty, "\(catalog.path) differs from the app's catalog; run "
                          + "python3 -I Scripts/sync-extension-catalogs.py:\n" + drifted.sorted().joined(separator: "\n"))
        }
    }

    /// Each catalog reaches its bundle only because the target takes its whole folder as sources.
    /// A switch to a file list would drop the catalog without a build error.
    func testEachTargetBundlesItsFolder() throws {
        for catalog in Self.extensionCatalogs {
            let spec = try String(contentsOf: Self.repoRoot.appendingPathComponent(catalog.spec), encoding: .utf8)
            XCTAssertTrue(spec.components(separatedBy: "\n").contains("      - path: \(catalog.folder)"),
                          "\(catalog.spec) no longer takes \(catalog.folder)/ whole, so \(catalog.path) isn't bundled")
        }
    }
}
