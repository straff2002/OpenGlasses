import XCTest
@testable import OpenGlasses

/// Keeps the Rokid MFi protocol strings out of the committed `Info.plist`.
///
/// `RokidMFITransport` can only open an `EASession` for a protocol listed under
/// `UISupportedExternalAccessoryProtocols`, so a hardware spike adds them locally. App Review
/// rejects a build that declares an MFi accessory protocol unless the accessory maker has
/// registered that app with Apple's MFi program. Registration is per app, and Rokid has registered
/// its own app but not this one — so the local edit must never reach a commit. This reads the authored plist the way `TelemetryOptOutGuardTests` does.
final class RokidAccessoryProtocolGuardTests: XCTestCase {

    // `#filePath` is baked in at compile time, so it resolves the same on a developer machine and
    // in CI, and the simulator shares the host filesystem.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private func authoredAccessoryProtocols() throws -> [String] {
        let url = Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let info = try XCTUnwrap(parsed as? [String: Any], "OpenGlasses/Info.plist is not a dictionary")
        return info["UISupportedExternalAccessoryProtocols"] as? [String] ?? []
    }

    func testCommittedInfoPlistDeclaresNoRokidProtocol() throws {
        let declared = try authoredAccessoryProtocols()
        for rokid in RokidMFITransport.protocolStrings {
            XCTAssertFalse(
                declared.contains(rokid),
                "\(rokid) is in the committed Info.plist. Keep it as a local edit for the hardware spike — App Review rejects an MFi protocol the accessory maker has not registered the app for."
            )
        }
    }

    /// The positive control: the guard reads the real key, so the Meta protocol it sits beside
    /// is found. Without this, a renamed key would make the test above pass vacuously.
    func testGuardReadsTheAccessoryProtocolList() throws {
        XCTAssertTrue(try authoredAccessoryProtocols().contains("com.meta.ar.wearable"))
    }
}
