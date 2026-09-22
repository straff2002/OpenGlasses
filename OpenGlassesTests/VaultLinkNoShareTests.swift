import SwiftUI
import XCTest
@testable import OpenGlasses

/// Plan FS decision 2 — **the app receives vaults and never helps pass one on.**
///
/// An in-app "share this vault" would make every subscriber a redistributor of manufacturers'
/// manuals, so there is no share-as-link, no QR generation and no upload anywhere in the app. That
/// is a property of the whole source tree rather than of one screen, so it is asserted by scraping
/// the sources: a future change that renders a vault URL as a code, or hands an archive to the
/// share sheet, fails here rather than shipping.
final class VaultLinkNoShareTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var sourcePaths: [String] {
        let root = repoRoot.appendingPathComponent("OpenGlasses/Sources")
        let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        return subpaths.filter { $0.hasSuffix(".swift") }.map { "OpenGlasses/Sources/\($0)" }.sorted()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Lines that mention a vault link or archive, with their file and line number.
    private func vaultLines() throws -> [(path: String, line: Int, text: String)] {
        var hits: [(String, Int, String)] = []
        for path in Self.sourcePaths {
            for (index, line) in try source(path).split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let text = String(line)
                let lower = text.lowercased()
                guard lower.contains("vaultarchive") || lower.contains("vaultlink")
                        || lower.contains("vaultreceipt") else { continue }
                hits.append((path, index + 1, text))
            }
        }
        return hits
    }

    // MARK: - No QR is ever produced

    func testNothingInTheAppGeneratesAQRCode() throws {
        // The two APIs that turn data into a code on iOS. Neither has any business in this app:
        // the QR story is entirely the receiving half.
        let generators = ["CIQRCodeGenerator", "CIFilter.qrCode", "AztecCodeGenerator",
                          "CIPDF417BarcodeGenerator", "CICode128BarcodeGenerator"]
        for path in Self.sourcePaths {
            let text = try source(path)
            for generator in generators {
                XCTAssertFalse(text.contains(generator),
                               "\(path) builds a barcode with \(generator). The app receives vault "
                               + "links and never renders one — see Plan FS decision 2.")
            }
        }
    }

    // MARK: - No archive reaches a share sheet or an upload

    func testNoVaultArchiveOrLinkIsHandedToAShareSheetOrAnUpload() throws {
        let outbound = ["UIActivityViewController", "ShareLink(", "ShareSheet(", "ShareItem(",
                        "httpMethod = \"POST\"", "httpMethod = \"PUT\"", "upload(", "uploadTask"]
        for hit in try vaultLines() {
            for marker in outbound where hit.text.contains(marker) {
                XCTFail("\(hit.path):\(hit.line) puts a vault link or archive through \(marker). "
                        + "The app never shares a vault — see Plan FS decision 2.\n\(hit.text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// The receive path's own files carry no outbound machinery at all, which is the stronger
    /// statement and the one that would catch a helper added just out of sight of the line scan.
    func testTheReceivePathHasNoOutboundMachinery() throws {
        let receivePath = Self.sourcePaths.filter {
            $0.contains("/Vault/VaultLink") || $0.contains("/Vault/VaultArchive")
                || $0.contains("/Vault/VaultPublisher") || $0.contains("/Vault/VaultReceipt")
                || $0.contains("Views/VaultLinkViews.swift")
        }
        XCTAssertGreaterThanOrEqual(receivePath.count, 6, "sanity: the scan should be finding the receive path")
        for path in receivePath {
            let text = try source(path)
            for marker in ["UIActivityViewController", "ShareLink(", "ShareSheet(",
                           "CIQRCodeGenerator", "httpMethod", "uploadTask", "multipart/form-data"] {
                XCTAssertFalse(text.contains(marker), "\(path) contains \(marker)")
            }
        }
    }

    /// The one export path a vault has is the folder export, and Plan FS PR1 already took the
    /// manuals out of it. Named here so the two halves of "a vault does not leave this phone" are
    /// asserted in one place.
    func testTheOnlyVaultExportIsTheManualFreeFolderExport() throws {
        let exporter = try source("OpenGlasses/Sources/Services/Vault/VaultExporter.swift")
        XCTAssertTrue(exporter.contains("markingDocumentsNotIncluded()"),
                      "the folder export must still mark its manuals as not included")
        XCTAssertFalse(exporter.contains("VaultArchiveHeader"),
                       "the exporter must not learn to write a vault archive")
    }

    // MARK: - The URL route takes one parameter and offers nothing

    func testTheSchemeRouteIsReceiveOnly() throws {
        let app = try source("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        XCTAssertTrue(app.contains("url.host == \"vault\""), "the vault route must be registered")
        XCTAssertEqual(VaultLinkPolicy.sourceParameterName, "src")
        // A vault link built by the app would be the first half of sharing one. Comments are
        // skipped: the route is documented in several of them, and a sentence about a link is not
        // a link. What is looked for is the shape a *constructed* one has — the scheme inside a
        // string literal.
        for path in Self.sourcePaths {
            for (index, line) in try source(path).split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let text = String(line)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                XCTAssertFalse(text.contains("\"openglasses://vault"),
                               "\(path):\(index + 1) builds a vault link; the app only ever parses one")
            }
        }
    }
}
