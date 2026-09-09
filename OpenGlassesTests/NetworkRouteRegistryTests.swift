import XCTest
@testable import OpenGlasses

/// Roadmap W04.2 — the test that keeps the outbound inventory honest.
///
/// `NetworkRouteRegistry` is only worth anything if it is complete. A registry maintained by hand
/// drifts the first time somebody adds a client, so this test does not trust the list: it scrapes
/// `OpenGlasses/Sources` for the types that own a transport (`URLSession`, `webSocketTask`,
/// `NWConnection`, and the task factories) and fails when one of them maps to neither a route nor
/// the short exemption list.
///
/// **Known limitation, stated rather than hidden:** the scrape attributes a hit to the innermost
/// enclosing top-level type declaration, or to the file's own name when the hit sits at file scope
/// (a free function or an `extension` body the brace tracker has already closed). A transport
/// obtained through a helper whose name contains none of these tokens would not be seen. The
/// trade is deliberate — the check is cheap, and its failure mode is a false alarm a human
/// resolves in seconds.
final class NetworkRouteRegistryTests: XCTestCase {

    // MARK: - The scrape

    private static let transportTokens = [
        "URLSession", "URLSessionWebSocketTask", "webSocketTask",
        "NWConnection", "dataTask", "uploadTask", "downloadTask"
    ]

    private static let declarationKeywords = ["class", "struct", "enum", "actor", "extension", "protocol"]

    private static var appSourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses")
            .appendingPathComponent("Sources")
    }

    /// Owning type name -> the files it was seen in.
    private static func scrapeTransportOwners() throws -> [String: Set<String>] {
        let root = appSourcesDirectory
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Could not enumerate \(root.path)")
        }
        var owners: [String: Set<String>] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallbackName = url.deletingPathExtension().lastPathComponent
            var depth = 0
            var stack: [(name: String, depth: Int)] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let raw = String(line)
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let code = raw.components(separatedBy: "//").first ?? raw

                if Self.transportTokens.contains(where: { Self.containsToken($0, in: code) }) {
                    owners[stack.first?.name ?? fallbackName, default: []].insert(url.lastPathComponent)
                }
                if code.contains("{"), let declared = Self.declaredTypeName(in: code) {
                    stack.append((declared, depth))
                }
                depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
                while let last = stack.last, depth <= last.depth { stack.removeLast() }
            }
        }
        return owners
    }

    /// A whole-word match, so `URLSessionGatewaySocket` is not read as a `URLSession` use.
    private static func containsToken(_ token: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex
                || !Self.isIdentifierCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !Self.isIdentifierCharacter(text[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.upperBound < text.endIndex else { return false }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func declaredTypeName(in code: String) -> String? {
        for keyword in declarationKeywords {
            guard let keywordRange = code.range(of: keyword),
                  keywordRange.lowerBound == code.startIndex
                    || !isIdentifierCharacter(code[code.index(before: keywordRange.lowerBound)])
            else { continue }
            let rest = code[keywordRange.upperBound...].drop(while: { $0 == " " })
            let name = String(rest.prefix(while: { isIdentifierCharacter($0) }))
            if !name.isEmpty { return name }
        }
        return nil
    }

    // MARK: - The guard itself

    func testEveryTransportOwningTypeMapsToARouteOrAJustifiedExemption() throws {
        let owners = try Self.scrapeTransportOwners()
        XCTAssertGreaterThan(owners.count, 30,
                             "The scrape found almost nothing — it has broken, not the codebase.")

        var unmapped: [String] = []
        for (type, files) in owners {
            if NetworkRouteRegistry.route(owningType: type) != nil { continue }
            if NetworkRouteRegistry.exemptTransportTypes[type] != nil { continue }
            unmapped.append("\(type) (\(files.sorted().joined(separator: ", ")))")
        }
        XCTAssertEqual(
            unmapped.sorted(), [],
            "These types own a network transport but declare no NetworkRoute. Add a case to "
            + "NetworkRoute (with its purpose, dataClasses, endpointClass and medicalPolicy) and "
            + "guard it, or add a justified entry to NetworkRouteRegistry.exemptTransportTypes."
        )
    }

    func testEveryRegisteredOwningTypeStillExistsInTheSources() throws {
        let owners = try Self.scrapeTransportOwners()
        let declared = Set(NetworkRoute.allCases.flatMap(\.owningTypes))
        let stale = declared.subtracting(owners.keys).sorted()
        XCTAssertEqual(stale, [],
                       "The registry names owning types the scrape no longer finds. Either the "
                       + "client moved (update owningTypes) or the route is dead (delete it).")
    }

    func testTheExemptionListStaysShortAndJustified() {
        XCTAssertLessThanOrEqual(
            NetworkRouteRegistry.exemptTransportTypes.count, 4,
            "The exemption list is the escape hatch. Growing it is how the inventory stops meaning anything.")
        for (type, reason) in NetworkRouteRegistry.exemptTransportTypes {
            XCTAssertGreaterThan(reason.count, 40, "\(type)'s exemption needs a real reason, not a label.")
        }
    }

    // MARK: - Registry shape

    func testEveryRouteDescribesItself() {
        for route in NetworkRoute.allCases {
            XCTAssertTrue(!route.owningTypes.isEmpty || route.transportDelegatedTo != nil,
                          "\(route.rawValue) names neither an owning type nor a borrowed transport")
            XCTAssertFalse(route.dataClasses.isEmpty, "\(route.rawValue) declares no data classes")
            XCTAssertGreaterThan(route.purpose.count, 20, "\(route.rawValue) needs a real purpose line")
            XCTAssertTrue(route.purpose.hasSuffix("."), "\(route.rawValue)'s purpose should read as a sentence")
        }
    }

    func testEveryMedicalExceptionCarriesAJustification() {
        for route in NetworkRoute.allCases {
            switch route.medicalPolicy {
            case .blockedWhenLocalOnly:
                XCTAssertNil(route.medicalPolicy.justification)
            case .allowedLocalOnly(let why), .notApplicable(let why):
                XCTAssertGreaterThan(why.count, 40,
                                     "\(route.rawValue) escapes the local-only rule on a one-word excuse")
            }
        }
    }

    func testOnlyContentFreeRoutesEscapeTheLocalOnlyRule() {
        // The exceptions are allowed to be a small, specific set. Anything that can carry captured
        // content — audio, transcript, frames, health facts, location, prompt text — must be blocked.
        let contentClasses: Set<NetworkDataClass> =
            [.audio, .transcript, .frame, .location, .promptText, .contactData]
        for route in NetworkRoute.allCases where !route.medicalPolicy.blocksLocalOnly {
            if case .notApplicable = route.medicalPolicy { continue }  // documented, reviewed separately
            XCTAssertTrue(route.dataClasses.isDisjoint(with: contentClasses),
                          "\(route.rawValue) is allowed in local-only mode but can carry captured content")
        }
    }

    /// A type may own more than one route — `TextToSpeechService` synthesizes speech and lists
    /// voices, which are different purposes with different payloads. What must not differ is where
    /// those routes go or how the medical rule treats them, because `route(owningType:)` returns
    /// the first match and the scrape check would otherwise be satisfied by the lenient one.
    func testRoutesSharingAnOwningTypeAgreeOnEndpointAndMedicalPolicy() {
        var seen: [String: NetworkRoute] = [:]
        for route in NetworkRoute.allCases {
            for type in route.owningTypes {
                guard let existing = seen[type] else { seen[type] = route; continue }
                XCTAssertEqual(existing.endpointClass, route.endpointClass, type)
                XCTAssertEqual(existing.medicalPolicy, route.medicalPolicy, type)
            }
        }
    }

    func testABorrowedTransportNamesARouteThatOwnsOne() {
        for route in NetworkRoute.allCases {
            guard let lender = route.transportDelegatedTo else { continue }
            XCTAssertTrue(route.owningTypes.isEmpty,
                          "\(route.rawValue) both owns and borrows a transport; pick one")
            XCTAssertFalse(lender.owningTypes.isEmpty,
                           "\(route.rawValue) borrows from \(lender.rawValue), which owns nothing")
            XCTAssertNil(lender.transportDelegatedTo, "borrowing must not chain")
        }
    }

    /// The private-network exception is a short, named list. Pinning it here means widening it is
    /// an edit somebody has to justify, not a side effect of adding a route.
    func testPrivateNetworkIsOnlyReachableFromTheNamedLocalClasses() {
        let permitted: Set<NetworkEndpointClass> = [.localNetwork, .loopback, .gateway]
        for endpointClass in NetworkEndpointClass.allCases {
            XCTAssertEqual(endpointClass.permitsPrivateNetwork, permitted.contains(endpointClass),
                           endpointClass.rawValue)
        }
        for route in NetworkRoute.allCases {
            XCTAssertEqual(route.endpointClass.permitsPrivateNetwork,
                           permitted.contains(route.endpointClass), route.rawValue)
        }
    }
}
