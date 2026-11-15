import XCTest
@testable import OpenGlasses

/// Plan LW §6 — the vault check's scoring, over injected retrieval results.
final class VaultCheckTests: XCTestCase {

    typealias Ref = VaultCheck.PageRef
    typealias Got = VaultCheck.Retrieved

    private let charge = VaultCheck.Question(text: "Which refrigerant does it use?", expected: [Ref(key: "installation-manual", page: 70)])
    private let fan = VaultCheck.Question(text: "How do I test the outdoor fan motor?",
                                          expected: [Ref(key: "installation-manual", page: 41), Ref(key: "service-manual", page: 12)])
    private let wiring = VaultCheck.Question(text: "How is the thermostat wired?", expected: [])

    func testAQuestionIsFoundWhenAnExpectedPageIsAmongItsFirstPassages() {
        let score = VaultCheck.score([charge, fan, wiring], retrieved: [
            [Got(key: "installation-manual", pages: [69, 70])],
            [Got(key: "installation-manual", pages: [3]), Got(key: "service-manual", pages: [12])],
            []
        ])
        XCTAssertEqual(score.asked, 2)
        XCTAssertEqual(score.found, 2)
        XCTAssertEqual(score.misses, [])
        XCTAssertEqual(score.withoutPage, [wiring], "a question with no page is listed, not scored")
        XCTAssertEqual(score.fraction, 1)
    }

    func testAMissSaysWhatItFoundInstead() {
        let elsewhere = [Got(key: "installation-manual", pages: [41]), Got(key: "installation-manual", pages: [41]),
                         Got(key: "service-manual", pages: [3]), Got(key: "service-manual", pages: [4]),
                         Got(key: "service-manual", pages: [5])]
        let score = VaultCheck.score([charge], retrieved: [elsewhere])
        XCTAssertEqual(score.found, 0)
        XCTAssertEqual(score.misses.first?.foundInstead,
                       [Got(key: "installation-manual", pages: [41]), Got(key: "service-manual", pages: [3]),
                        Got(key: "service-manual", pages: [4])], "the first three, each once")
        XCTAssertFalse(score.meets(0.5))
    }

    func testThePageMustBeInTheRightManualAndNearTheTop() {
        XCTAssertFalse(VaultCheck.isFound(charge, in: [Got(key: "service-manual", pages: [70])]), "page 70 of another manual")
        let deep = Array(repeating: Got(key: "service-manual", pages: [1]), count: 5) + [Got(key: "installation-manual", pages: [70])]
        XCTAssertFalse(VaultCheck.isFound(charge, in: deep), "sixth is past the default depth")
        XCTAssertTrue(VaultCheck.isFound(charge, in: deep, depth: 6))
    }

    func testAQuestionWithNoRetrievalIsAMissWithNothingInstead() {
        let score = VaultCheck.score([charge, fan], retrieved: [[]])
        XCTAssertEqual(score.asked, 2)
        XCTAssertEqual(score.misses.map(\.foundInstead), [[], []])
    }

    func testThresholdsAndAnEmptyCheck() {
        let score = VaultCheck.score([charge, fan], retrieved: [[Got(key: "installation-manual", pages: [70])], []])
        XCTAssertEqual(score.fraction, 0.5)
        XCTAssertTrue(score.meets(0.5))
        XCTAssertFalse(score.meets(0.6))
        XCTAssertTrue(VaultCheck.score([wiring], retrieved: [[]]).meets(1), "nothing asked fails nothing")
    }

    func testStarterQuestionsComeFromTheTemplateWithTheAuthorsPages() {
        let template = OpenGlasses.TradeTemplate.hvacR
        let first = template.checkQuestions[0].text
        let questions = VaultCheck.starterQuestions(template, answers: [first: [Ref(key: "installation-manual", page: 41)]])
        XCTAssertEqual(questions.map(\.text), template.checkQuestions.map(\.text))
        XCTAssertEqual(questions[0].expected, [Ref(key: "installation-manual", page: 41)])
        XCTAssertTrue(questions.dropFirst().allSatisfy(\.expected.isEmpty))
        XCTAssertEqual(VaultCheck.score(questions, retrieved: []).withoutPage.count, template.checkQuestions.count - 1)
    }
}

/// Plan LW §7 — the manuals an export says the vault was written against.
final class VaultExpectsTests: XCTestCase {

    private let digest = String(repeating: "ab", count: 32)
    private let otherDigest = String(repeating: "cd", count: 32)

    func testKeysComeFromFileNamesAndStayUnique() {
        XCTAssertEqual(VaultExpects.keys(forFiles: ["Installation Manual.pdf", "service_manual_rev2.md", "QX-100 wiring.PDF"]),
                       ["installation-manual", "service-manual-rev2", "qx-100-wiring"])
        XCTAssertEqual(VaultExpects.keys(forFiles: ["guide.pdf", "guide.md", "Guide.pdf"]),
                       ["guide-pdf", "guide-md", "guide-pdf-2"], "a shared stem keeps the extension; beyond that, a number")
        XCTAssertEqual(VaultExpects.keys(forFiles: ["手册.pdf"]), ["manual"])
        XCTAssertEqual(VaultExpects.key(forFile: "guide.md", among: ["guide.pdf", "guide.md"]), "guide-md")
        XCTAssertNil(VaultExpects.key(forFile: "other.pdf", among: ["guide.pdf"]))
        let long = VaultExpects.keys(forFiles: [String(repeating: "x", count: 120) + ".pdf"])[0]
        XCTAssertEqual(long.count, 80)
        for key in VaultExpects.keys(forFiles: ["a b.pdf", "-x-.md", "Q.X.100.pdf"]) {
            XCTAssertTrue(CompanyVaultCatalog.safeIdentifier(key), key)
        }
    }

    func testTheKeysAreTheSameEveryTime() {
        let files = ["b.pdf", "a.pdf", "a.md"]
        XCTAssertEqual(VaultExpects.keys(forFiles: files), VaultExpects.keys(forFiles: files))
    }

    func testEntriesCarryTitleEditionAndAKnownRevision() {
        let documents = [
            VaultDocument(file: "install.pdf", title: "Installation manual", edition: " Rev C ", revision: digest),
            VaultDocument(file: "service.pdf", title: "Service manual"),
            VaultDocument(file: "parts.pdf", title: "  ", edition: "", revision: "not-a-digest")
        ]
        let expects = VaultExpects.expects(for: documents, ledgerHashes: ["service.pdf": otherDigest, "parts.pdf": "ABC"])
        XCTAssertEqual(expects, [
            .init(key: "install", title: "Installation manual", edition: "Rev C", revision: digest),
            .init(key: "service", title: "Service manual", edition: nil, revision: otherDigest),
            .init(key: "parts", title: "parts.pdf", edition: nil, revision: nil)
        ], "the document's revision, else the ledger's hash; never a value that is not a digest")
    }

    func testTheDocumentsOwnRevisionWinsOverTheLedgers() {
        let expects = VaultExpects.expects(for: [VaultDocument(file: "a.pdf", title: "A", revision: digest)],
                                           ledgerHashes: ["a.pdf": otherDigest])
        XCTAssertEqual(expects.first?.revision, digest)
    }

    func testTitlesAreCappedAndAVaultWithNoManualsHasNoExpects() {
        let title = String(repeating: "t", count: 250)
        XCTAssertEqual(VaultExpects.expects(for: [VaultDocument(file: "a.pdf", title: title)]).first?.title.count, 200)
        XCTAssertEqual(VaultExpects.expects(for: []), [])
    }

    func testTheLedgersHashesByFile() {
        let ledger = VaultDocumentLedger(entries: [
            .init(file: "a.pdf", title: "A", documentId: "d1", contentHash: digest, chunkCount: 3)
        ])
        XCTAssertEqual(VaultExpects.ledgerHashes(ledger), ["a.pdf": digest])
    }

    // MARK: - The export's manifest

    private func manifest(documents: [VaultDocument]) -> VaultManifest {
        VaultManifest(id: "units", name: "Units", version: "1.0.0", files: ["models.md"], documentsDir: "documents",
                      documents: documents, gating: .init(iap: "enterprise"),
                      promptRules: ["Never fabricate.", "Cite the page."]).markingDocumentsNotIncluded()
    }

    func testWithNoExpectsTheManifestIsTheBytesItAlwaysWas() throws {
        let plain = manifest(documents: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertEqual(try VaultExporter.manifestJSON(plain, expects: []), try encoder.encode(plain))
        let withManual = manifest(documents: [VaultDocument(file: "install.pdf", title: "Installation manual")])
        XCTAssertEqual(try VaultExporter.manifestJSON(withManual, expects: []), try encoder.encode(withManual))
    }

    func testExpectsSitsBesideTheManifestsOwnKeysAndAnImportStillReadsIt() throws {
        let withManual = manifest(documents: [VaultDocument(file: "install.pdf", title: "Installation manual", edition: "Rev C")])
        let expects = VaultExpects.expects(for: withManual.documents, ledgerHashes: ["install.pdf": digest])
        let data = try VaultExporter.manifestJSON(withManual, expects: expects)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let listed = try XCTUnwrap(object["expects"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["key"] as? String, "install")
        XCTAssertEqual(listed[0]["title"] as? String, "Installation manual")
        XCTAssertEqual(listed[0]["edition"] as? String, "Rev C")
        XCTAssertEqual(listed[0]["revision"] as? String, digest)
        XCTAssertEqual(object["documents_included"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(VaultManifest.self, from: data), withManual,
                       "the phone's decoder ignores expects and reads the manifest unchanged")
        // The entries are what the company catalog contract accepts.
        let decoded = try JSONDecoder().decode([CompanyVaultCatalog.ExpectedManual].self,
                                               from: JSONSerialization.data(withJSONObject: listed))
        XCTAssertEqual(decoded, expects)
        XCTAssertTrue(decoded.allSatisfy { CompanyVaultCatalog.safeIdentifier($0.key) && VaultExpects.isDigest($0.revision ?? digest) })
    }
}
