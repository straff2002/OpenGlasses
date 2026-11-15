import XCTest
@testable import OpenGlasses

/// Plan LV P0 — `ExpectedManualMatch` (a published vault's expected manuals × the documents held)
/// and `CitationEditionCheck` (the revision line an answer carries, decision 6). Headless.
final class ExpectedManualMatchTests: XCTestCase {

    typealias Match = ExpectedManualMatch
    typealias Expected = CompanyVaultCatalog.ExpectedManual

    static let installRevision = String(repeating: "1", count: 64)
    static let serviceRevision = String(repeating: "2", count: 64)

    let expects: [Expected] = [
        .init(key: "install-manual", title: "Installation manual", edition: "Rev C", revision: installRevision),
        .init(key: "service-manual", title: "Service manual", edition: "Rev B", revision: serviceRevision),
        .init(key: "wiring-diagram", title: "Wiring diagram", edition: "2024"),
    ]

    func document(_ title: String, file: String? = nil, edition: String? = nil, revision: String? = nil,
                  origin: VaultDocument.Origin? = .company) -> VaultDocument {
        VaultDocument(file: file ?? title + ".pdf", title: title, kind: "company_manual", edition: edition,
                      revision: revision, origin: origin)
    }

    // MARK: - Matching

    func testEachExpectedManualIsMatchedAtAnotherRevisionOrMissing() {
        let documents = [document("Installation manual", revision: Self.installRevision),
                         document("Service manual", revision: String(repeating: "9", count: 64)),
                         document("Site photos", origin: .technician)]
        let summary = Match.match(expects: expects, documents: documents)
        XCTAssertEqual(summary.entries.map(\.status), [.matched(file: "Installation manual.pdf"),
                                                       .differentRevision(file: "Service manual.pdf"), .missing])
        XCTAssertEqual(summary.extras.map(\.title), ["Site photos"])
        XCTAssertEqual(summary.extras.first?.origin, .technician)
        XCTAssertEqual(summary.expectedCount, 3)
        XCTAssertEqual(summary.matchedCount, 1)
        XCTAssertEqual(summary.differentRevisionCount, 1)
        XCTAssertEqual(summary.missingCount, 1)
        XCTAssertEqual(summary.heldCount, 2, "\"2 of 3 manuals\": held at all, whatever the revision")
    }

    func testARevisionMatchWinsWhateverTheTitle() {
        let summary = Match.match(expects: [expects[0]], documents: [document("Install guide (company scan)", revision: Self.installRevision)])
        XCTAssertEqual(summary.entries[0].status, .matched(file: "Install guide (company scan).pdf"))
        XCTAssertEqual(summary.extras, [])
    }

    func testTitlesCompareWithoutCaseOrSpacing() {
        let summary = Match.match(expects: [expects[2]], documents: [document("  wiring   DIAGRAM ", edition: "2024")])
        XCTAssertEqual(summary.entries[0].status, .matched(file: "  wiring   DIAGRAM .pdf"))
    }

    func testWithoutRevisionsTheEditionDecides() {
        let other = Match.match(expects: [expects[2]], documents: [document("Wiring diagram", edition: "2019")])
        XCTAssertEqual(other.entries[0].status, .differentRevision(file: "Wiring diagram.pdf"))
        let same = Match.match(expects: [expects[2]], documents: [document("Wiring diagram", edition: " 2024")])
        XCTAssertEqual(same.entries[0].status, .matched(file: "Wiring diagram.pdf"))
    }

    /// A company manual is laid in with its revision and no edition; a partner may name a manual by
    /// title and edition only. Something known on one side only is no evidence of a difference.
    func testWhatOnlyOneSideKnowsIsNoDifference() {
        let noEdition = Match.match(expects: [expects[2]], documents: [document("Wiring diagram", revision: Self.serviceRevision)])
        XCTAssertEqual(noEdition.entries[0].status, .matched(file: "Wiring diagram.pdf"))
        let noRevision = Match.match(expects: [expects[0]], documents: [document("Installation manual", edition: "rev c", revision: nil)])
        XCTAssertEqual(noRevision.entries[0].status, .matched(file: "Installation manual.pdf"))
        let neither = Match.match(expects: [.init(key: "k", title: "Installation manual")], documents: [document("Installation manual")])
        XCTAssertEqual(neither.entries[0].status, .matched(file: "Installation manual.pdf"))
    }

    func testRevisionsThatDifferWinOverAnAgreeingEdition() {
        let summary = Match.match(expects: [expects[1]],
                                  documents: [document("Service manual", edition: "Rev B", revision: String(repeating: "8", count: 64))])
        XCTAssertEqual(summary.entries[0].status, .differentRevision(file: "Service manual.pdf"))
    }

    func testTheCopyWhoseEditionAgreesIsPreferred() {
        let documents = [document("Wiring diagram", file: "old.pdf", edition: "2019"),
                         document("Wiring diagram", file: "unknown.pdf"),
                         document("Wiring diagram", file: "current.pdf", edition: "2024")]
        let summary = Match.match(expects: [expects[2]], documents: documents)
        XCTAssertEqual(summary.entries[0].status, .matched(file: "current.pdf"))
        XCTAssertEqual(summary.extras.map(\.file), ["old.pdf", "unknown.pdf"], "extras keep the vault's order")
    }

    func testADocumentAnswersForOneExpectationOnly() {
        let twice: [Expected] = [.init(key: "a", title: "Service manual", edition: "Rev B"),
                                 .init(key: "b", title: "Service manual", edition: "Rev A")]
        let summary = Match.match(expects: twice, documents: [document("Service manual", edition: "Rev B")])
        XCTAssertEqual(summary.entries.map(\.status), [.matched(file: "Service manual.pdf"), .missing])
        // An exact revision match is taken first, so a title match cannot steal its document.
        let byRevision: [Expected] = [.init(key: "a", title: "Service manual"),
                                      .init(key: "b", title: "Other title", revision: Self.serviceRevision)]
        let taken = Match.match(expects: byRevision, documents: [document("Service manual", revision: Self.serviceRevision)])
        XCTAssertEqual(taken.entries.map(\.status), [.missing, .matched(file: "Service manual.pdf")])
    }

    func testNoExpectationsMakeEveryDocumentAnExtra() {
        let summary = Match.match(expects: [], documents: [document("Installation manual")])
        XCTAssertEqual(summary.entries, [])
        XCTAssertEqual(summary.extras.map(\.title), ["Installation manual"])
        XCTAssertEqual(summary.heldCount, 0)
    }

    func testLookupsByKeyAndByDocument() {
        let summary = Match.match(expects: expects, documents: [document("Service manual", revision: Self.installRevision.replacingOccurrences(of: "1", with: "3"))])
        XCTAssertEqual(summary.entry(key: "service-manual")?.status, .differentRevision(file: "Service manual.pdf"))
        XCTAssertEqual(summary.entry(documentFile: "Service manual.pdf")?.expected.key, "service-manual")
        XCTAssertNil(summary.entry(key: "nothing"))
        XCTAssertNil(summary.entry(documentFile: "nothing.pdf"))
    }

    /// The shared fixture: what the company uploaded against what its published vault expects.
    func testTheGoldenPublishedVaultsChecklist() throws {
        let catalog = try CompanyVaultPublishedContractTests.catalog()
        let base = try XCTUnwrap(catalog.vaults.first)
        let documents = catalog.manuals(in: base.vaultId).map {
            VaultDocument(file: $0.fileName, title: $0.title, kind: "company_manual", revision: $0.revision, origin: .company)
        }
        let summary = Match.match(expects: base.expects ?? [], documents: documents)
        XCTAssertEqual(summary.entries.map(\.status), [.matched(file: "Installation manual.md"),
                                                       .differentRevision(file: "Service manual.md"), .missing])
        XCTAssertEqual(summary.extras, [])
    }

    // MARK: - The revision line (CitationEditionCheck)

    typealias Check = CitationEditionCheck

    var summary: Match.Summary {
        Match.match(expects: expects, documents: [document("Installation manual", revision: Self.installRevision),
                                                  document("Service manual", revision: String(repeating: "9", count: 64)),
                                                  document("Site photos", origin: .technician)])
    }

    func testAPageInADifferentRevisionIsNamed() {
        XCTAssertEqual(Check.note(for: .init(key: "service-manual", page: 42), in: summary),
                       .differentRevision(title: "Service manual", page: 42))
        XCTAssertEqual(Check.note(for: .init(documentFile: "Service manual.pdf", page: 12), in: summary),
                       .differentRevision(title: "Service manual", page: 12))
    }

    func testNothingIsSaidOnMostAnswers() {
        XCTAssertNil(Check.note(for: .init(key: "install-manual", page: 4), in: summary), "a matched manual")
        XCTAssertNil(Check.note(for: .init(documentFile: "Site photos.pdf", page: 2), in: summary), "a manual the vault never expected")
        XCTAssertNil(Check.note(for: .init(key: "service-manual"), in: summary), "no page cited")
        XCTAssertNil(Check.note(for: .init(), in: summary))
        XCTAssertNil(Check.note(for: .init(key: "unknown-key", page: 1), in: summary))
    }

    func testAMissingExpectedManualIsNamedByTitle() {
        XCTAssertEqual(Check.note(for: .init(key: "wiring-diagram", page: 3), in: summary), .missing(title: "Wiring diagram"))
        XCTAssertEqual(Check.note(for: .init(key: "wiring-diagram"), in: summary), .missing(title: "Wiring diagram"))
    }

    func testAnAnswerSaysEachNoteOnce() {
        let notes = Check.notes(for: [.init(key: "service-manual", page: 42), .init(key: "install-manual", page: 4),
                                      .init(documentFile: "Service manual.pdf", page: 42), .init(key: "wiring-diagram"),
                                      .init(key: "service-manual", page: 43)],
                                in: summary)
        XCTAssertEqual(notes, [.differentRevision(title: "Service manual", page: 42), .missing(title: "Wiring diagram"),
                               .differentRevision(title: "Service manual", page: 43)])
    }

    func testAKeyIsPreferredToAFileWhenACitationCarriesBoth() {
        XCTAssertEqual(Check.note(for: .init(key: "wiring-diagram", documentFile: "Service manual.pdf", page: 5), in: summary),
                       .missing(title: "Wiring diagram"))
    }
}
