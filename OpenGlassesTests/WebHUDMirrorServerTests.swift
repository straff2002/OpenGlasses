import UIKit
import XCTest
@testable import OpenGlasses

/// Plan LT §7 — the web mirror's launcher files: two PNG icons and a manifest, read-only and behind
/// the same token as `hud.json`; the page links them from its `<head>`.
@MainActor
final class WebHUDMirrorServerTests: XCTestCase {

    private func route(_ target: String, method: String = "GET", hipaa: Bool = false,
                       icon: @escaping (WebHUDLauncher.IconSize) -> Data? = { _ in Data([0x89, 0x50]) })
        -> WebHUDMirrorServer.Response {
        WebHUDMirrorServer.routeResponse(method: method, target: target, hipaa: hipaa,
                                         expectedToken: "tok_en-1", payload: .empty, icon: icon)
    }

    func testTheLauncherFilesNeedTheToken() {
        for path in ["/manifest.webmanifest", "/icon-192.png", "/icon-512.png"] {
            XCTAssertEqual(route(path).status, "401 Unauthorized", path)
            XCTAssertEqual(route(path + "?t=wrong").status, "401 Unauthorized", path)
            XCTAssertEqual(route(path + "?t=tok_en-1").status, "200 OK", path)
        }
    }

    func testTheLauncherFilesAreReadOnlyAndOffUnderHIPAA() {
        for path in ["/manifest.webmanifest?t=tok_en-1", "/icon-192.png?t=tok_en-1"] {
            XCTAssertEqual(route(path, method: "POST").status, "405 Method Not Allowed", path)
            XCTAssertEqual(route(path, hipaa: true).status, "503 Service Unavailable", path)
        }
        XCTAssertEqual(route("/icon-64.png?t=tok_en-1").status, "404 Not Found", "only the two sizes")
    }

    func testTheIconsArePNGsOfTheirSize() throws {
        for size in WebHUDLauncher.IconSize.allCases {
            let response = WebHUDMirrorServer.routeResponse(
                method: "GET", target: size.path + "?t=tok_en-1", hipaa: false,
                expectedToken: "tok_en-1", payload: .empty)
            XCTAssertEqual(response.status, "200 OK")
            XCTAssertEqual(response.contentType, "image/png")
            XCTAssertEqual(Array(response.body.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                           "a PNG, not an SVG")
            let image = try XCTUnwrap(UIImage(data: response.body))
            XCTAssertEqual(image.size.width * image.scale, CGFloat(size.rawValue))
            XCTAssertEqual(image.size.height * image.scale, CGFloat(size.rawValue))
        }
        XCTAssertEqual(WebHUDLauncher.IconSize.allCases.map(\.rawValue), [192, 512])
    }

    func testAMissingIconIsAServerErrorNotAnEmptyImage() {
        XCTAssertEqual(route("/icon-192.png?t=tok_en-1", icon: { _ in nil }).status, "500 Internal Server Error")
    }

    func testTheManifestIsStandaloneBlackAndCarriesTheToken() throws {
        let response = route("/manifest.webmanifest?t=tok_en-1")
        XCTAssertEqual(response.contentType, "application/manifest+json")
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, "Avenkin HUD")
        XCTAssertEqual(manifest["display"] as? String, "standalone")
        XCTAssertEqual(manifest["theme_color"] as? String, "#000000")
        XCTAssertEqual(manifest["background_color"] as? String, "#000000")
        XCTAssertEqual(manifest["start_url"] as? String, "/#t=tok_en-1", "the launched page can poll")
        let icons = try XCTUnwrap(manifest["icons"] as? [[String: String]])
        XCTAssertEqual(icons.map { $0["sizes"] }, ["192x192", "512x512"])
        XCTAssertEqual(icons.map { $0["src"] }, ["/icon-192.png?t=tok_en-1", "/icon-512.png?t=tok_en-1"])
        XCTAssertTrue(icons.allSatisfy { $0["type"] == "image/png" })
    }

    func testThePageHeadLinksBothAndTheScriptAddsTheToken() {
        let html = WebHUDRenderer.page(mode: .polling(intervalSeconds: 2))
        let head = html.components(separatedBy: "</head>").first ?? ""
        XCTAssertTrue(head.contains("<link rel=\"manifest\" id=\"launcher-manifest\">"))
        XCTAssertTrue(head.contains("rel=\"icon\""))
        XCTAssertTrue(head.contains("rel=\"apple-touch-icon\""))
        XCTAssertTrue(head.contains("<meta name=\"theme-color\" content=\"#000000\">"))
        XCTAssertFalse(head.contains("href=\""), "no link carries a URL without the token")
        XCTAssertTrue(html.contains("\"manifest.webmanifest\" + t"))
        XCTAssertTrue(html.contains("\"icon-192.png\" + t"))
        XCTAssertTrue(html.contains("\"icon-512.png\" + t"))
        XCTAssertFalse(html.contains("http://"), "still self-contained")
    }
}
