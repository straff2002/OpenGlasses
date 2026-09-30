import XCTest
@testable import OpenGlasses

/// The app asks Apple Health for access in three places (the fitness coach, the tool permission
/// gate and health summaries), and every one of those requests fails in a signed build unless the
/// app carries `com.apple.developer.healthkit`. It shipped without it for a long time: the key was
/// in neither the spec nor either entitlements file, so authorisation silently failed on device.
///
/// These checks read the authored files rather than the built product, because the committed
/// entitlements file is generated from the spec and the personal example is copied by the setup
/// script — three places that must agree, and any one of them drifting is the old bug again.
final class HealthEntitlementGuardTests: XCTestCase {

    /// `#filePath` is baked in at compile time, so it resolves the same on a developer machine and
    /// in CI, and the simulator shares the host filesystem.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(path))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any], "\(path) is not a dictionary plist")
    }

    func testTheSpecDeclaresHealthKitOnTheAppTarget() throws {
        let spec = try text("project.base.yml")
        XCTAssertTrue(spec.contains("com.apple.developer.healthkit: true"),
                      "project.base.yml must declare the HealthKit entitlement on the app target")
    }

    func testTheCommittedEntitlementsCarryHealthKit() throws {
        let entitlements = try plist("OpenGlasses/OpenGlasses.entitlements")
        XCTAssertEqual(entitlements["com.apple.developer.healthkit"] as? Bool, true)
    }

    /// The personal copy replaces the committed file when a developer signs for a device, so the
    /// example it is made from has to carry the key as well.
    func testThePersonalEntitlementsExampleCarriesHealthKit() throws {
        let example = try plist("Config/Entitlements/Personal/OpenGlasses.entitlements.example")
        XCTAssertEqual(example["com.apple.developer.healthkit"] as? Bool, true)
    }

    /// An existing personal copy is never overwritten, so the setup script patches the key in.
    func testTheSetupScriptAddsHealthKitToAnExistingPersonalCopy() throws {
        let script = try text("Scripts/setup-local-dev.sh")
        XCTAssertTrue(script.contains("Add :com.apple.developer.healthkit bool true"))
        XCTAssertTrue(script.contains("\nensure_personal_capabilities\n"),
                      "the helper must actually be called, not only defined")
    }
}
