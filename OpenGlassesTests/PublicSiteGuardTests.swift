import XCTest
@testable import OpenGlasses

/// Plan FY P0 item 7 — every public address the app reads comes from one base, `PublicSite.baseURL`.
///
/// Two halves. The derived addresses are pinned to the base *and* to the paths the old Pages
/// addresses used, because shipped builds reach this site through a redirect that keeps the path:
/// a derived path that drifted would 404 for new builds while old ones kept working, and nothing
/// else would notice. And the sources are scraped for an old Pages or repository address written
/// out anywhere else, so a new hard-coded link cannot quietly bypass the base.
final class PublicSiteGuardTests: XCTestCase {

    // MARK: - The derived addresses

    func testTheBaseIsAvenkin() {
        XCTAssertEqual(PublicSite.baseURL.absoluteString, "https://avenkin.com")
    }

    func testEveryDerivedAddressIsUnderTheBaseAtItsPublishedPath() {
        let expected: [(String, URL, String)] = [
            ("privacy", PublicSite.privacy, "/privacy.html"),
            ("support", PublicSite.support, "/support.html"),
            ("about", PublicSite.about, "/about.html"),
            ("skillPackCatalog", PublicSite.skillPackCatalog, "/skillpacks/catalog.json"),
            ("vaultPackCatalog", PublicSite.vaultPackCatalog, "/vaultpacks/catalog.json"),
            ("activationDirectory", PublicSite.activationDirectory, "/activation/"),
        ]
        for (name, url, path) in expected {
            XCTAssertEqual(url.scheme, "https", name)
            XCTAssertEqual(url.host, PublicSite.baseURL.host, "\(name) is not under the base")
            XCTAssertTrue(url.absoluteString.hasPrefix(PublicSite.baseURL.absoluteString + "/"),
                          "\(name) is not under the base")
            XCTAssertEqual(url.absoluteString, PublicSite.baseURL.absoluteString + path,
                           "\(name) must keep the path the old Pages address redirects to")
        }
    }

    /// The consumers read the base, not a copy of it.
    func testTheConsumersReadTheBase() {
        XCTAssertEqual(ActivationKey.defaultDirectory, PublicSite.activationDirectory)
        XCTAssertEqual(ActivationKeyResolver().directory.appendingPathComponent("abc").absoluteString,
                       "https://avenkin.com/activation/abc")
        XCTAssertEqual(DiagnosticsReportBuilder.issueBaseURL, PublicSite.support.absoluteString)

        let defaults = UserDefaults.standard
        let savedSkill = defaults.object(forKey: "skillPackCatalogURL")
        let savedVault = defaults.object(forKey: "vaultPackCatalogURL")
        defer {
            defaults.set(savedSkill, forKey: "skillPackCatalogURL")
            defaults.set(savedVault, forKey: "vaultPackCatalogURL")
        }
        defaults.removeObject(forKey: "skillPackCatalogURL")
        defaults.removeObject(forKey: "vaultPackCatalogURL")
        XCTAssertEqual(Config.skillPackCatalogURL, PublicSite.skillPackCatalog.absoluteString)
        XCTAssertEqual(Config.vaultPackCatalogURL, PublicSite.vaultPackCatalog.absoluteString)

        // The existing override hooks keep working; only their defaults moved.
        Config.setSkillPackCatalogURL("https://packs.example.org/catalog.json")
        XCTAssertEqual(Config.skillPackCatalogURL, "https://packs.example.org/catalog.json")
        Config.setVaultPackCatalogURL("https://vaults.example.org/catalog.json")
        XCTAssertEqual(Config.vaultPackCatalogURL, "https://vaults.example.org/catalog.json")
    }

    // MARK: - No address outside the base

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// Spellings of the old public addresses. Assembled in pieces so this file is not itself a hit
    /// for a scan of the test sources, and so a rename's find-and-replace cannot rewrite them.
    private static let forbidden = [
        "github" + ".io",
        "github.com/" + "straff2002/" + "Open" + "Glasses",
        "githubusercontent.com/" + "straff2002/" + "Open" + "Glasses",
    ]

    /// The one line allowed to name the repository: the downloadable translations, which are read
    /// from the repository rather than the published site, so they do not move with its domain.
    private static let allowedLines: [(file: String, contains: String)] = [
        ("OpenGlasses/Sources/Services/LocalizationManager.swift",
         "raw.githubusercontent.com/" + "straff2002/" + "Open" + "Glasses/main/"),
    ]

    /// A comment line (`//`, `///`, or a line inside a block comment) documents; it does not
    /// fetch. Doc comments may name the old addresses to explain where things came from.
    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    func testNoSourceFileWritesAnOldPublicAddress() throws {
        let sourcesRoot = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            return XCTFail("could not enumerate OpenGlasses/Sources — the guard lost sight of the sources")
        }

        var scanned = 0
        var findings: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let relative = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard Self.forbidden.contains(where: { line.contains($0) }) else { continue }
                if Self.isComment(line) { continue }
                if Self.allowedLines.contains(where: { relative == $0.file && line.contains($0.contains) }) {
                    continue
                }
                findings.append("\(relative):\(index + 1)")
            }
        }

        XCTAssertGreaterThan(scanned, 500, "the scan found too few files to be looking at the sources")
        XCTAssertTrue(findings.isEmpty,
                      "An old public address is written outside PublicSite. Read it from "
                      + "PublicSite (Utils/PublicSite.swift) instead: " + findings.joined(separator: ", "))
    }

    /// The allowlist is not a loophole: its one entry is still there, and still the only kind of
    /// address it lets through.
    func testTheAllowlistStillMatchesTheTranslationsAddress() throws {
        let entry = try XCTUnwrap(Self.allowedLines.first)
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(entry.file), encoding: .utf8)
        XCTAssertTrue(text.contains(entry.contains),
                      "\(entry.file) no longer reads the translations from the repository; drop the allowlist entry")
        XCTAssertEqual(Self.allowedLines.count, 1)
    }
}
