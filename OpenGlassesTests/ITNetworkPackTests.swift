import XCTest
@testable import OpenGlasses

/// Tests for Plan G: NetworkCalcTool subnet math and the it_network vault/procedure registration.
@MainActor
final class ITNetworkPackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistDeveloperUnlocked")
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "fieldAssistDeveloperUnlocked")
        super.tearDown()
    }

    // MARK: - IPv4 subnetting

    func testSlash24() throws {
        let s = try XCTUnwrap(NetworkCalcTool.subnetIPv4("192.168.1.42/24"))
        XCTAssertEqual(s.network, "192.168.1.0")
        XCTAssertEqual(s.broadcast, "192.168.1.255")
        XCTAssertEqual(s.netmask, "255.255.255.0")
        XCTAssertEqual(s.usableRange, "192.168.1.1 – 192.168.1.254")
        XCTAssertEqual(s.usableHosts, "254")
    }

    func testSlash26() throws {
        let s = try XCTUnwrap(NetworkCalcTool.subnetIPv4("10.0.0.130/26"))
        XCTAssertEqual(s.network, "10.0.0.128")
        XCTAssertEqual(s.broadcast, "10.0.0.191")
        XCTAssertEqual(s.usableHosts, "62")
    }

    func testSlash31AndSlash32EdgeCases() throws {
        let p2p = try XCTUnwrap(NetworkCalcTool.subnetIPv4("172.16.0.0/31"))
        XCTAssertTrue(p2p.usableHosts.contains("2"))
        let host = try XCTUnwrap(NetworkCalcTool.subnetIPv4("172.16.0.5/32"))
        XCTAssertTrue(host.usableHosts.contains("1"))
        XCTAssertEqual(host.network, "172.16.0.5")
    }

    func testInvalidIPv4Rejected() {
        XCTAssertNil(NetworkCalcTool.subnetIPv4("999.1.1.1/24"))
        XCTAssertNil(NetworkCalcTool.subnetIPv4("10.0.0.0/33"))
        XCTAssertNil(NetworkCalcTool.subnetIPv4("not-an-ip"))
    }

    // MARK: - IPv6

    func testIPv6PrefixAndCount() throws {
        let s = try XCTUnwrap(NetworkCalcTool.subnetIPv6("2001:db8::/48"))
        XCTAssertEqual(s.prefixLength, 48)
        XCTAssertEqual(s.addressCount, "2^80")
        let small = try XCTUnwrap(NetworkCalcTool.subnetIPv6("2001:db8::/126"))
        XCTAssertEqual(small.addressCount, "4")
    }

    func testIPv6Invalid() {
        XCTAssertNil(NetworkCalcTool.subnetIPv6("gggg::/64"))
        XCTAssertNil(NetworkCalcTool.subnetIPv6("2001:db8::/129"))
    }

    // MARK: - Tool execution

    func testToolFormatsSubnet() async throws {
        let result = try await NetworkCalcTool().execute(args: ["operation": "subnet", "cidr": "192.168.1.0/24"])
        XCTAssertTrue(result.contains("192.168.1.255"))
        XCTAssertTrue(result.contains("Usable hosts"))
    }

    // MARK: - Vault registration + procedures

    func testITVaultRegisteredWithProcedures() throws {
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: "it_network"))
        XCTAssertEqual(manifest.gating.iap, "field_assist_it")
        XCTAssertEqual(manifest.proceduresDir, "procedures")

        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: "it_network"))
        XCTAssertFalse(store.readAll().isEmpty, "IT vault markdown should be bundled")

        let library = ProcedureLibrary(store: store)
        let ids = Set(library.all.map(\.id))
        XCTAssertTrue(ids.contains("network_troubleshoot"))
        XCTAssertTrue(ids.contains("server_cold_swap"))
        XCTAssertEqual(library.all.count, 5)
    }

    func testITProceduresHaveResolvableBranchTargets() throws {
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: "it_network"))
        let library = ProcedureLibrary(store: store)
        for procedure in library.all {
            let stepIds = Set(procedure.steps.map(\.id))
            XCTAssertNotNil(procedure.entry, "\(procedure.id) has no entry step")
            for step in procedure.steps {
                for branch in step.branches {
                    XCTAssertTrue(stepIds.contains(branch.next),
                                  "\(procedure.id): branch '\(branch.id)' → missing step '\(branch.next)'")
                }
                if let next = step.defaultNext {
                    XCTAssertTrue(stepIds.contains(next), "\(procedure.id): default_next → missing step '\(next)'")
                }
            }
        }
    }
}
