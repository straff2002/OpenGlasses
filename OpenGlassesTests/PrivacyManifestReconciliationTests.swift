import XCTest
@testable import OpenGlasses

/// Roadmap W04.5 — reconcile what the app says it sends with what it actually sends.
///
/// `PrivacyInfo.xcprivacy` was written from a source audit at a point in time. An audit is a
/// photograph; this is the thing that keeps the photograph current. The registry says which data
/// classes leave on which routes, so the manifest can be checked against it both ways: a class
/// with no declaration is an undisclosed egress, and a declaration no route justifies is a claim
/// the app has stopped standing behind.
final class PrivacyManifestReconciliationTests: XCTestCase {

    // MARK: - Reading the manifest

    private static var manifestURL: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Resources")
            .appendingPathComponent("PrivacyInfo.xcprivacy")
    }

    private static func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            throw XCTSkip("PrivacyInfo.xcprivacy did not parse as a dictionary")
        }
        return plist
    }

    private static func declaredCollectedTypes() throws -> Set<String> {
        let entries = try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        return Set(entries.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
    }

    // MARK: - The reconciliation

    func testTheManifestIsReadable() throws {
        let plist = try Self.manifest()
        XCTAssertNotNil(plist["NSPrivacyCollectedDataTypes"])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    }

    /// The direction that matters: nothing leaves on a route whose category the manifest omits.
    func testEveryRouteSDataClassesAreDeclared() throws {
        let declared = try Self.declaredCollectedTypes()
        var missing: [String] = []
        for route in NetworkRoute.allCases {
            for dataClass in route.dataClasses {
                guard let type = dataClass.privacyManifestType else { continue }
                guard !declared.contains(type) else { continue }
                missing.append("\(route.rawValue) sends \(dataClass.rawValue), needing \(type)")
            }
            if route == .webSearch {
                XCTAssertTrue(declared.contains("NSPrivacyCollectedDataTypeSearchHistory"),
                              "a search query is sent but SearchHistory is not declared")
            }
        }
        XCTAssertEqual(missing.sorted(), [],
                       "Add the declaration to PrivacyInfo.xcprivacy in the same change that adds "
                       + "the route — an undisclosed egress contradicts the manifest the moment it starts.")
    }

    /// The other direction: a declaration nothing justifies is a claim that has gone stale, and a
    /// manifest that over-declares is as misleading as one that under-declares.
    func testEveryDeclarationIsJustifiedByARouteOrAWrittenNote() throws {
        let declared = try Self.declaredCollectedTypes()
        let required = NetworkRouteRegistry.requiredPrivacyManifestTypes
        let noted = Set(NetworkRouteRegistry.manifestDeclarationsWithoutADedicatedRoute.keys)
        let unjustified = declared.subtracting(required).subtracting(noted).sorted()
        XCTAssertEqual(unjustified, [],
                       "Either a route stopped sending this and the declaration should go, or the "
                       + "route exists and should say so in its dataClasses.")
    }

    func testTheNotedDeclarationsStayShortAndExplained() {
        let noted = NetworkRouteRegistry.manifestDeclarationsWithoutADedicatedRoute
        XCTAssertLessThanOrEqual(noted.count, 3,
                                 "Notes are the escape hatch from reconciliation; a growing list "
                                 + "means the registry has stopped describing the app.")
        for (type, reason) in noted {
            XCTAssertGreaterThan(reason.count, 60, "\(type) needs a real explanation, not a label.")
        }
    }

    /// Health facts can leave on several routes, and Apple's Health category is the one an App
    /// Review reader looks for, so pin the link rather than leaving it to the loop above.
    func testHealthCarryingRoutesAreCoveredByTheHealthDeclaration() throws {
        let declared = try Self.declaredCollectedTypes()
        let healthRoutes = NetworkRouteRegistry.routes(sending: .healthFact)
        XCTAssertFalse(healthRoutes.isEmpty, "no route carries a health fact — has one been renamed?")
        XCTAssertTrue(declared.contains("NSPrivacyCollectedDataTypeHealth"))
    }

    /// Routes that carry nothing about the user need no declaration, and saying they do would
    /// overstate what the app sends. Model downloads are the case that matters: they are also the
    /// routes permitted in medical local-only mode, and that permission rests on this claim.
    func testContentFreeRoutesRequireNoDeclaration() {
        for route: NetworkRoute in [.localModelDownload, .localModelRepositoryMetadata,
                                    .ttsVoiceModelDownload, .asrModelDownload,
                                    .fingerspellingModelDownload, .currencyRates] {
            let needed = route.dataClasses.compactMap(\.privacyManifestType)
            XCTAssertEqual(needed, [], "\(route.rawValue) claims to send user data")
        }
    }

    /// The required-reason API declarations are the other half of the manifest, and the app's use
    /// of UserDefaults is pervasive enough that losing this entry would be a submission failure.
    func testRequiredReasonAPIDeclarationsAreStillPresent() throws {
        let entries = try Self.manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        let categories = Set(entries.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategoryDiskSpace"))
        for entry in entries {
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            XCTAssertFalse(reasons.isEmpty,
                           "\(entry["NSPrivacyAccessedAPIType"] ?? "?") declares no reason code")
        }
    }

    /// The manifest claims no tracking and no tracking domains. Both are load-bearing for the
    /// "no analytics SDK" statement the in-app privacy copy makes.
    func testTheNoTrackingClaimIsIntact() throws {
        let plist = try Self.manifest()
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
        let entries = plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        for entry in entries {
            let name = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, name)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false, name)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"], name)
        }
    }
}
