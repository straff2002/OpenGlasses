import XCTest
@testable import OpenGlasses

/// Plan FY P3.1 — `avenkin://` is accepted everywhere `openglasses://` is, through one helper, and
/// `openglasses://` is never retired (decision D3).
///
/// The app's routing lives inline in `onOpenURL`, so "every route, same result" is asserted on the
/// pure pieces each route consults — the scheme helper, the trust policy, the privacy route and the
/// three link parsers — plus a source check that no handler compares the scheme by hand, which is
/// how one route could come to accept one scheme and refuse the other.
@MainActor
final class DeepLinkSchemeTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// One sample link per route the app handles, written without a scheme.
    private static let routes = [
        "shortcut-result?x=1", "shortcut-cancel", "shortcut-error?errorMessage=no",
        "skillpack?url=https%3A%2F%2Fpacks.example%2Fpack.zip&sig=QUJD",
        "skillpack?url=http%3A%2F%2Fevil.example%2Fpack.zip",
        "vault?src=https%3A%2F%2Fmanuals.example.com%2Fv%2Facme.vaultarchive",
        "vault?src=https%3A%2F%2Fa.example.com%2Fa&install=1",
        "enrol?url=https%3A%2F%2Fconfig.northbridge.example%2Fprofile.txt",
        "enrol?url=http%3A%2F%2Fa.example%2Fp",
        "persona/p-123", "connect", "disconnect",
        "action/ask", "action/photo", "action/describe",
        "listen/on", "listen/off", "listen/toggle",
        "quickaction/qa-1", "nowhere/at-all",
    ]

    private func url(_ scheme: String, _ route: String) -> URL {
        URL(string: "\(scheme)://\(route)")!
    }

    func testBothSchemesAreTheAppsInAnyCase() {
        for scheme in ["openglasses", "avenkin", "AVENKIN", "OpenGlasses", "Avenkin"] {
            XCTAssertTrue(DeepLinkScheme.isApp(url(scheme, "connect")), "\(scheme):// is the app's")
        }
        for scheme in ["https", "http", "mwdat-1234", "fb-viewapp", "avenkinx", "open-glasses", "evil"] {
            XCTAssertFalse(DeepLinkScheme.isApp(url(scheme, "connect")), "\(scheme):// is not the app's")
        }
        XCTAssertFalse(DeepLinkScheme.isApp(scheme: nil))
    }

    func testEveryRouteGivesTheSameResultUnderBothSchemes() {
        for route in Self.routes {
            let old = url("open" + "glasses", route)
            let new = url("avenkin", route)
            XCTAssertEqual(DeepLinkScheme.isApp(old), DeepLinkScheme.isApp(new), route)
            XCTAssertEqual(privacyRoute(for: old), privacyRoute(for: new), route)
            XCTAssertEqual(DeepLinkTrust.requiresTrustedCaller(host: old.host, action: old.lastPathComponent),
                           DeepLinkTrust.requiresTrustedCaller(host: new.host, action: new.lastPathComponent), route)
            XCTAssertEqual(SkillPackSideload.parse(old), SkillPackSideload.parse(new), route)
            XCTAssertEqual(VaultLinkPolicy.resolve(old), VaultLinkPolicy.resolve(new), route)
            XCTAssertEqual(OrgEnrolmentService.parse(old), OrgEnrolmentService.parse(new), route)
        }
    }

    /// The new scheme is not merely "not refused": each parser actually accepts it.
    func testTheNewSchemeIsAcceptedByEachParser() {
        XCTAssertNotNil(try? SkillPackSideload.parse(url("avenkin", "skillpack?url=https%3A%2F%2Fp.example%2Fp.zip")).get())
        XCTAssertEqual(try? VaultLinkPolicy.resolve(url("avenkin", "vault?src=https%3A%2F%2Fm.example%2Fv")).get(),
                       URL(string: "https://m.example/v"))
        XCTAssertEqual(try? OrgEnrolmentService.parse(url("avenkin", "enrol?url=https%3A%2F%2Fc.example%2Fp")).get(),
                       URL(string: "https://c.example/p"))
    }

    func testAnUnknownSchemeIsStillRefused() {
        let skill = url("evil", "skillpack?url=https%3A%2F%2Fp.example%2Fp.zip")
        XCTAssertEqual(SkillPackSideload.parse(skill), .failure(.notASideloadLink))
        let enrol = url("evil", "enrol?url=https%3A%2F%2Fc.example%2Fp")
        XCTAssertEqual(OrgEnrolmentService.parse(enrol), .failure(.notAnEnrolmentLink))
        let vault = url("evil", "vault?src=https%3A%2F%2Fm.example%2Fv")
        XCTAssertEqual(VaultLinkPolicy.resolve(vault), .failure(.insecureScheme("evil")))
    }

    /// Links are still generated on the old scheme until the build that accepts the new one is
    /// what users have (P3.3), so a link made today opens on a phone that has not updated.
    func testGeneratedLinksStayOnTheOldSchemeForNow() {
        XCTAssertEqual(DeepLinkScheme.generated, "open" + "glasses")
        XCTAssertEqual(VaultLinkPolicy.scheme, DeepLinkScheme.generated)
    }

    func testBothSchemesAreRegistered() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist"))
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                                    as? [String: Any])
        let schemes = ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        for scheme in DeepLinkScheme.accepted {
            XCTAssertTrue(schemes.contains(scheme), "\(scheme) is accepted but not registered with iOS")
        }
    }

    /// No handler compares a URL's scheme to the app's by hand: every one goes through
    /// `DeepLinkScheme`, so no path can accept only one of the two.
    func testNoHandlerComparesTheAppSchemeByHand() throws {
        let pattern = try NSRegularExpression(
            pattern: #"scheme[^\n]{0,40}==\s*"(open"# + "glasses" + #"|avenkin)""#, options: [.caseInsensitive])
        for directory in ["OpenGlasses/Sources", "GlassesActivityWidget", "OpenGlassesWatch",
                          "OpenGlassesWatchWidget", "OpenGlassesShareExtension"] {
            let base = Self.repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
                XCTAssertEqual(hits, 0, "\(file.lastPathComponent) compares the app's URL scheme by hand; "
                                   + "use DeepLinkScheme.isApp so both schemes are accepted")
            }
        }
    }
}
