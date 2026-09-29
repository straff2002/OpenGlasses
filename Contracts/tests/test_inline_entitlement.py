#!/usr/bin/env python3
"""Run the production setup and pairing verification code on Mac without booting iOS."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "OpenGlasses/Sources/Services/LicenseService.swift",
    "OpenGlasses/Sources/Services/OrgProfile/ConfigProfile.swift",
    "OpenGlasses/Sources/Services/OrgProfile/ProfileVerification.swift",
    "OpenGlasses/Sources/Services/OfficeSync/OfficeManualAssignment.swift",
    "OpenGlasses/Sources/Services/OfficeSync/OfficePeerBinding.swift",
    "OpenGlasses/Sources/Services/OfficeSync/OfficeInlineEntitlement.swift",
    "OpenGlasses/Sources/Services/OfficeSync/OfficeSetupPackage.swift",
    "OpenGlasses/Sources/Services/OfficeSync/OfficePairingService.swift",
]
TESTS = [
    "OpenGlassesTests/OfficeInlineEntitlementTests.swift",
    "Contracts/tests/PortableOfficePairingGateTests.swift",
]


def main() -> None:
    tools = ROOT / "Transport/.tools"
    tools.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="inline-entitlement-check-", dir=tools) as folder:
        package = Path(folder)
        source_dir = package / "Sources/OpenGlasses"
        test_dir = package / "Tests/OpenGlassesTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        for relative in SOURCES:
            shutil.copyfile(ROOT / relative, source_dir / Path(relative).name)
        for relative in TESTS:
            shutil.copyfile(ROOT / relative, test_dir / Path(relative).name)
        (source_dir / "AppSeams.swift").write_text(
            """import Foundation
enum FieldAssistTier: String { case solo, team, enterprise }
enum Config { static func setFieldAssistLicenseValid(_ valid: Bool) {} }
enum ProfileLease {
    enum Status { case live, lapsed
        var isInForce: Bool { self == .live }
    }
}
struct OrgEnrolmentRecord {
    var document: String
    var source: ProfileSource
    var enrolmentId: String
    var activatedLicenceCode: String?
    var revoked: Bool?
}
@MainActor final class OrgProfileManager {
    static let shared = OrgProfileManager()
    var record: OrgEnrolmentRecord?
    var profile: ConfigProfile?
    var contentLocked = false
    var status: ProfileLease.Status? = .live
    func evaluateLease() -> ProfileLease.Status? { status }
}
actor OfficeTransportIdentity {
    static let shared = OfficeTransportIdentity()
    private var running = false
    func deviceID() throws -> String { "unused" }
    func startManagedOffice(transportID: String, lanAddress: String) throws { running = true }
    func stop() { running = false }
    func isRunning() -> Bool { running }
}
actor OfficePhoneIdentity {
    static let shared = OfficePhoneIdentity()
    func publicKey() throws -> Data { Data(repeating: 0, count: 32) }
}
actor OfficePeerHighWaterStore {
    struct HighWater: Sendable { let generation: Int64; let payloadSHA256: String }
    enum Decision: Sendable { case accepted, replay }
    static let shared = OfficePeerHighWaterStore()
    private var state: HighWater?
    func read(organizationID: String, enrolmentID: String) throws -> HighWater? { state }
    func accept(_ binding: OfficePeerBinding.Verified) throws -> Decision {
        if state?.generation == binding.payload.generation { return .replay }
        state = HighWater(generation: binding.payload.generation, payloadSHA256: binding.payloadSHA256)
        return .accepted
    }
}
actor OfficeApprovedPeerStore {
    struct Stored: Sendable {
        let officeID: String
        let officeTransportID: String
        let officeApplicationKey: Data
        let signedBinding: Data
    }
    static let shared = OfficeApprovedPeerStore()
    private var state: Stored?
    func save(_ signedBinding: Data, organizationID: String, enrolmentID: String,
              officeID: String, officeTransportID: String, officeApplicationKey: Data) throws {
        state = Stored(officeID: officeID, officeTransportID: officeTransportID,
                       officeApplicationKey: officeApplicationKey, signedBinding: signedBinding)
    }
    func read(organizationID: String, enrolmentID: String) throws -> Stored? { state }
}
"""
        )
        (package / "Package.swift").write_text(
            '// swift-tools-version: 5.9\n'
            'import PackageDescription\n'
            'let package = Package(name: "OpenGlasses", platforms: [.macOS(.v14)], targets: [\n'
            '  .target(name: "OpenGlasses"),\n'
            '  .testTarget(name: "OpenGlassesTests", dependencies: ["OpenGlasses"]),\n'
            '])\n'
        )
        environment = os.environ.copy()
        environment.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/avenkin-clang-cache")
        environment.setdefault("SWIFT_MODULECACHE_PATH", "/private/tmp/avenkin-swift-cache")
        # This package contains only copied local sources and fixtures. Avoid SwiftPM's nested
        # sandbox, which cannot initialize inside some CI/agent filesystem sandboxes.
        subprocess.run(["swift", "test", "--disable-sandbox", "--package-path", str(package)], check=True, env=environment)


if __name__ == "__main__":
    main()
