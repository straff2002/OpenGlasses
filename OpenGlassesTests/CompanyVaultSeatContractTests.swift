import XCTest
@testable import OpenGlasses

/// Plan LR P2 — the seat renewal's installed vaults, held to the licence core's `SeatRenewRequest`
/// and the shared fixture.
extension CompanyVaultContractTests {
    func testTheRenewalCarriesTheInstalledVaultsInTheCoresBytes() throws {
        XCTAssertEqual(DeviceSeatLease.maximumRequestBytes, SeatWire.maximumRequestBytes)
        XCTAssertEqual(DeviceSeatLease.maximumVaultsPerRenewal, SeatInstalledVault.maximumPerRenewal)
        let app = DeviceSeatLease.renewRequest(build: "680", lease: "fixture.lease",
                                               vaults: [.init(vaultId: "fixture_rtu", version: "1.0.0")])
        let fixture = try Self.fixture("seat-renew-v1.json")
        XCTAssertEqual(try DeviceSeatLease.encode(app) + Data("\n".utf8), fixture)
        let core = try SeatWire.decoder().decode(SeatRenewRequest.self, from: try DeviceSeatLease.encode(app))
        XCTAssertEqual(core.vaults, [SeatInstalledVault(vaultId: "fixture_rtu", version: "1.0.0")])
        // None installed: the renewal is the bytes it always was.
        XCTAssertEqual(try DeviceSeatLease.encode(DeviceSeatLease.renewRequest(build: "660", lease: "l", vaults: [])),
                       try SeatWire.encoder().encode(SeatRenewRequest(build: "660", lease: "l")))
        // Never more than the core keeps, and never a request the service would refuse for size.
        let many = (0..<40).map { DeviceSeatLease.InstalledVault(vaultId: "vault_\($0)", version: "1") }
        XCTAssertEqual(DeviceSeatLease.renewRequest(build: "680", lease: "l", vaults: many).vaults?.count,
                       DeviceSeatLease.maximumVaultsPerRenewal)
        let long = (0..<16).map { DeviceSeatLease.InstalledVault(vaultId: "vault_\($0)", version: String(repeating: "9", count: 300)) }
        XCTAssertNil(DeviceSeatLease.renewRequest(build: "680", lease: String(repeating: "l", count: 2_000), vaults: long).vaults)
    }
}
