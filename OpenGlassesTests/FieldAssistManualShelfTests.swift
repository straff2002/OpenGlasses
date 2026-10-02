import XCTest
@testable import OpenGlasses

/// Plan HB — the Field Assist tab's manuals: which are listed, in what order, what a search finds,
/// and when one can be asked.
final class FieldAssistManualShelfTests: XCTestCase {

    private typealias Shelf = FieldAssistManualShelf

    private let refrigeration = Shelf.Vault(
        id: "refrigeration", name: "Refrigeration", unlocked: true,
        documents: [VaultDocument(file: "rtu500.txt", title: "RTU-500 Service Manual", kind: "service_manual"),
                    VaultDocument(file: "ahu.pdf", title: "AHU Install Guide", kind: "install_guide")])
    private let network = Shelf.Vault(
        id: "it_network", name: "IT & Network", unlocked: true,
        documents: [VaultDocument(file: "switch.pdf", title: "Core Switch Manual", kind: nil)])
    private let electrical = Shelf.Vault(
        id: "electrical", name: "Électrical", unlocked: false,
        documents: [VaultDocument(file: "panel.pdf", title: "Panel Manual")])

    func testTheActiveVaultComesFirstThenTheRestByName() {
        let manuals = Shelf.manuals(vaults: [network, refrigeration, electrical], activeVaultId: "refrigeration")
        XCTAssertEqual(manuals.map(\.title),
                       ["AHU Install Guide", "RTU-500 Service Manual", "Core Switch Manual"])
        XCTAssertEqual(manuals.map(\.isActiveVault), [true, true, false])
        XCTAssertEqual(manuals.first?.id, "refrigeration/ahu.pdf")
    }

    func testALockedVaultsManualsAreNotListed() {
        let manuals = Shelf.manuals(vaults: [electrical], activeVaultId: "electrical")
        XCTAssertTrue(manuals.isEmpty)
    }

    func testAManualThatCannotBeOpenedIsNotListed() {
        var vault = refrigeration
        vault.unavailableFiles = ["rtu500.txt"]
        XCTAssertEqual(Shelf.manuals(vaults: [vault], activeVaultId: "refrigeration").map(\.title),
                       ["AHU Install Guide"])
    }

    func testSearchMatchesTitleVaultAndKindIgnoringCaseAndAccents() {
        let all = [network, refrigeration]
        XCTAssertEqual(Shelf.manuals(vaults: all, activeVaultId: "x", query: "rtu").map(\.title),
                       ["RTU-500 Service Manual"])
        XCTAssertEqual(Shelf.manuals(vaults: all, activeVaultId: "x", query: "  NETWORK ").map(\.title),
                       ["Core Switch Manual"])
        XCTAssertEqual(Shelf.manuals(vaults: all, activeVaultId: "x", query: "install guide").map(\.title),
                       ["AHU Install Guide"])
        var accented = electrical
        accented = Shelf.Vault(id: accented.id, name: accented.name, unlocked: true, documents: accented.documents)
        XCTAssertEqual(Shelf.manuals(vaults: [accented], activeVaultId: "x", query: "electrical").count, 1)
        XCTAssertTrue(Shelf.manuals(vaults: all, activeVaultId: "x", query: "boiler").isEmpty)
    }

    func testTheRowDetailNamesTheKindAndTheVault() {
        let manual = Shelf.manuals(vaults: [refrigeration], activeVaultId: "refrigeration")[1]
        XCTAssertEqual(manual.detail, "Service manual · Refrigeration")
        let plain = Shelf.manuals(vaults: [network], activeVaultId: "it_network")[0]
        XCTAssertEqual(plain.detail, "IT & Network")
    }

    /// `manual_lookup` answers only inside a job on the manual's vault, so Ask is offered only there.
    func testAManualCanBeAskedOnlyDuringAJobOnItsVault() {
        let manual = Shelf.manuals(vaults: [refrigeration], activeVaultId: "refrigeration")[0]
        XCTAssertTrue(Shelf.canAsk(manual, openJobVaultId: "refrigeration"))
        XCTAssertFalse(Shelf.canAsk(manual, openJobVaultId: "it_network"))
        XCTAssertFalse(Shelf.canAsk(manual, openJobVaultId: nil))
    }

    func testTheAskPromptNamesTheManualAndAsksForThePage() {
        let manual = Shelf.manuals(vaults: [refrigeration], activeVaultId: "refrigeration")[1]
        let prompt = Shelf.askPrompt(manual: manual, question: "  what is fault E4? ")
        XCTAssertEqual(prompt,
                       "Look this up in the \u{201C}RTU-500 Service Manual\u{201D} manual and cite the page: what is fault E4?")
        XCTAssertNil(Shelf.askPrompt(manual: manual, question: "   "), "an empty question sends nothing")
    }
}
