import XCTest
@testable import OpenGlasses

/// Plan KD P0 — the partner's retest on 581, case by case: jobs that ended themselves, a name
/// heard as no answer, a vault name with "vault" on the end, chains and pages nobody asked for,
/// 4/0 answered as No. 4, and a printed page that was not the page asked for.
///
/// Headless: every tool takes the technician's words and the previous reply through seams, and
/// every table, row, value and vault here is invented — nothing is a fact from any code book.

// MARK: - What the words ask for

final class TechnicianRequestTests: XCTestCase {

    func testEndingTheJobNeedsAnEndWord() {
        for said in ["close the job", "OK we're finished here", "end it", "cancel this job",
                     "let's wrap it up", "wrap up the job please"] {
            XCTAssertTrue(TechnicianRequest.asksToEndJob(said), said)
        }
        // The retest's own sentences: naming a job, and an answer to the job-number question.
        for said in ["Name electric wall test 2.2", "call it vault test 1.3", "switch to the other vault",
                     "I'm done with the capacitor", "what's the ampacity of 4/0 copper"] {
            XCTAssertFalse(TechnicianRequest.asksToEndJob(said), said)
        }
    }

    func testAYesEndsTheJobOnlyAfterAQuestionAboutEndingIt() {
        XCTAssertTrue(TechnicianRequest.confirmsEndingJob("yes", previousReply: "Shall I close the job now?"))
        XCTAssertTrue(TechnicianRequest.confirmsEndingJob("yeah go ahead", previousReply: "Want me to finish the job?"))
        XCTAssertFalse(TechnicianRequest.confirmsEndingJob("yes", previousReply: "The ampacity is 85 A. Anything else?"))
        XCTAssertFalse(TechnicianRequest.confirmsEndingJob("yes", previousReply: nil))
        XCTAssertFalse(TechnicianRequest.confirmsEndingJob("yes, but what about the derating?",
                                                           previousReply: "Shall I close the job?"))
    }

    func testAChainIsNamedOnlyByItsNameNotByAWordOfIt() {
        let name = "Conductor sizing check"
        XCTAssertTrue(TechnicianRequest.names(chain: name, in: "run the conductor sizing check"))
        XCTAssertTrue(TechnicianRequest.names(chain: name, in: "can you start the sizing check for the conductor"))
        XCTAssertFalse(TechnicianRequest.names(chain: name, in: "what size conductor do I need for 40 amps"))
        XCTAssertFalse(TechnicianRequest.names(chain: name, in: "check the conductor size in the table"))
        // A chain whose name holds a run verb is not asked for by a question that uses the word.
        XCTAssertFalse(TechnicianRequest.names(chain: "Voltage drop on a run",
                                               in: "what's the voltage drop on a 30 metre run of 6 copper"))
    }

    func testAskingToRunAChainIsNotAskingWhatChainsThereAre() {
        XCTAssertTrue(TechnicianRequest.asksToRunChain("use a chain for that"))
        XCTAssertTrue(TechnicianRequest.asksToRunChain("run the chain"))
        XCTAssertFalse(TechnicianRequest.asksToRunChain("what chains can I use"))
        XCTAssertFalse(TechnicianRequest.asksToRunChain("what's the voltage drop on a 30 metre run"))
    }

    func testOfferedChainsAreTheOnesTheReplyNamed() {
        let names = ["Voltage drop on a run", "Check an installed conductor"]
        XCTAssertEqual(TechnicianRequest.chainsMentioned(
            in: "I can run the Voltage drop on a run chain for that — want me to?", among: names),
                       ["Voltage drop on a run"])
        XCTAssertEqual(TechnicianRequest.chainsMentioned(in: "The drop is within limits.", among: names), [])
    }

    func testSeeingAPageIsAskedForTypedOrSpoken() {
        for said in ["show me the table", "show me the page", "open it", "let me see",
                     "where does it say that", "can I see table 99", "pull up page 12"] {
            XCTAssertTrue(TechnicianRequest.asksToSee(said), said)
        }
        for said in ["what's the ampacity of 4/0 aluminum", "open it up and check the capacitor first",
                     "the reading is 240 volts"] {
            XCTAssertFalse(TechnicianRequest.asksToSee(said), said)
        }
    }
}

// MARK: - Ending and naming a job

@MainActor
final class JobEndAndNameTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobEndAndNameTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func liveSession(reference: String? = "1027") throws -> FieldSessionService {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions"))
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: reference)
        return service
    }

    func testNamingAJobDoesNotEndIt() async throws {
        let service = try liveSession()
        let tool = FieldSessionTool(service: service, currentUtterance: { "Name electric wall test 2.2" },
                                    previousReply: { nil })
        let reply = try await tool.execute(args: ["action": "end", "outcome": "resolved"])
        XCTAssertTrue(reply.hasPrefix("Not ended"), reply)
        XCTAssertTrue(reply.contains("set_job_details"), reply)
        XCTAssertNotNil(service.activeSession, "the job stays open")
    }

    func testAJobEndsWhenTheTechnicianSaysSoOrSaysYesToTheQuestion() async throws {
        let service = try liveSession()
        let told = FieldSessionTool(service: service, currentUtterance: { "right, close the job" },
                                    previousReply: { nil })
        let ended = try await told.execute(args: ["action": "end"])
        XCTAssertTrue(ended.hasPrefix("Session ended"), ended)
        XCTAssertNil(service.activeSession)

        let again = try liveSession()
        let agreed = FieldSessionTool(service: again, currentUtterance: { "yes" },
                                      previousReply: { "That's everything on the list. Shall I close the job?" })
        let closed = try await agreed.execute(args: ["action": "end"])
        XCTAssertTrue(closed.hasPrefix("Session ended"), closed)
    }

    func testCancellingNeedsTheTechniciansWordsEvenWithNoTurnCaptured() {
        XCTAssertEqual(FieldSessionTool.endRefusal(outcome: .cancelled, said: nil, previousReply: nil),
                       FieldSessionTool.cancelRefusal)
        XCTAssertNil(FieldSessionTool.endRefusal(outcome: .resolved, said: nil, previousReply: nil),
                     "an agent or live-session turn may still end a job, as before")
        XCTAssertNil(FieldSessionTool.endRefusal(outcome: .cancelled, said: "cancel this job", previousReply: nil))
        XCTAssertEqual(FieldSessionTool.endRefusal(outcome: .cancelled, said: "use the other vault", previousReply: nil),
                       FieldSessionTool.cancelRefusal)
    }

    func testARefusedEndRecordsNoPassedCheck() async throws {
        let service = try liveSession()
        let tool = FieldSessionTool(service: service, currentUtterance: { "the test run passed fine" },
                                    previousReply: { nil })
        _ = try await tool.execute(args: ["action": "end", "test_result": "test run passed"])
        XCTAssertFalse(try XCTUnwrap(service.activeSession).tasks.contains { $0.isVerificationTask })
    }

    func testTheDescriptionNeverSuggestsEndingAJobToChangeItsVault() {
        let description = FieldSessionTool().description
        XCTAssertFalse(description.contains("keeps its vault until ended"))
        XCTAssertTrue(description.contains("never end a job to change its vault or its name"))
        XCTAssertTrue(description.contains("set_job_details"))
    }

    func testSetJobDetailsRenamesTheOpenJobInPlace() async throws {
        let service = try liveSession(reference: nil)
        let tool = FieldSessionTool(service: service)
        let reply = try await tool.execute(args: ["action": "set_job_details", "name": "Electric vault test 1.3"])
        XCTAssertTrue(reply.contains("now named Electric vault test 1.3"), reply)
        XCTAssertTrue(reply.contains("stays open"), reply)
        XCTAssertEqual(service.activeSession?.assetId, "Electric vault test 1.3")

        let same = try await tool.execute(args: ["action": "set_job_details", "name": "Electric vault test 1.3"])
        XCTAssertTrue(same.contains("already named"), same)

        let both = try await tool.execute(args: ["action": "set_job_details", "name": "Wall test 2.2",
                                                 "job_reference": "2.2"])
        XCTAssertEqual(service.activeSession?.assetId, "Wall test 2.2")
        XCTAssertEqual(service.activeSession?.jobReference, "2.2")
        XCTAssertTrue(both.contains("Job reference 2.2 is recorded"), both)

        let nothing = try await tool.execute(args: ["action": "set_job_details"])
        XCTAssertTrue(nothing.hasPrefix("Nothing was changed"), nothing)
    }

    func testAJobReferenceSaidAgainIsNotRecordedTwice() async throws {
        let service = try liveSession(reference: nil)
        let tool = FieldSessionTool(service: service)
        _ = try await tool.execute(args: ["action": "set_job_reference", "job_reference": "1005"])
        let again = try await tool.execute(args: ["action": "set_job_reference", "job_reference": "1005"])
        XCTAssertTrue(again.contains("already recorded"), again)
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
    }
}

// MARK: - The job-number question hears a name

final class JobNameAnswerTests: XCTestCase {

    private func reference(_ text: String) -> String? {
        if case .reference(let value) = JobReferenceClassifier.classify(text) { return value }
        return nil
    }

    func testTheRetestsAnswersAreTakenWithTheCarrierOff() {
        XCTAssertEqual(reference("Name electric wall test 2.2"), "electric wall test 2.2")
        XCTAssertEqual(reference("Job number Electric Vault Test 1.3"), "Electric Vault Test 1.3")
        XCTAssertEqual(reference("call it vault test 4.1"), "vault test 4.1")
        XCTAssertEqual(reference("the job name is pump room 3"), "pump room 3")
    }

    /// "Drop number" is "job number" as the recogniser heard it on site. Only ever a leading
    /// carrier, so a voltage-drop question is never taken for an answer.
    func testDropNumberIsAMishearingButAVoltageDropQuestionIsNot() {
        XCTAssertEqual(reference("Drop number electric vault test 3.2"), "electric vault test 3.2")
        XCTAssertNil(reference("voltage drop number 3 on the feeder"))
        XCTAssertNil(reference("what's the voltage drop on 30 metres of number 6"))
    }

    func testTheLongerLimitNeedsACarrier() {
        XCTAssertNil(reference("electric wall test 2.2 again"), "five words with no carrier is not an answer")
        XCTAssertNil(reference("Name the electric wall test job 2.2 for the customer please"),
                     "a carrier allows six words, not a sentence")
    }
}

@MainActor
final class TypedJobAnswerTests: XCTestCase {

    private var sessionsRoot: URL!
    private var storeDirectory: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        sessionsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TypedJob-s-\(unique)")
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TypedJob-c-\(unique)")
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sessionsRoot)
        try? FileManager.default.removeItem(at: storeDirectory)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    func testATypedAnswerToTheJobQuestionIsRecordedWithoutAReadBack() async throws {
        let service = FieldSessionService(sessionsRoot: sessionsRoot)
        var spoken: [String] = []
        let flow = GuidedJobFlow(sessions: service, store: ConversationStore(directory: storeDirectory),
                                 seams: .init(speak: { spoken.append($0) }))
        _ = try flow.startJob(vaultId: "refrigeration")
        XCTAssertNil(flow.handleTypedAnswer("Name electric wall test 2.2"), "nothing is asked until the question is put")
        await flow.speakPendingQuestionIfDue()
        XCTAssertEqual(spoken.last, JobIntakePrompt.ask.spoken)

        XCTAssertNil(flow.handleTypedAnswer("what's the ampacity of 4/0 copper?"), "a question goes to the model")
        XCTAssertTrue(flow.intakeState.awaitsAnswer)

        let reply = flow.handleTypedAnswer("Name electric wall test 2.2")
        XCTAssertEqual(reply, JobIntakePrompt.confirmed("electric wall test 2.2").spoken)
        XCTAssertEqual(service.activeSession?.jobReference, "electric wall test 2.2")
        XCTAssertNil(flow.handleTypedAnswer("job 1005"), "once recorded, the question is closed")
    }

    func testTheModelIsToldToRecordAnAnswerItHears() throws {
        let service = FieldSessionService(sessionsRoot: sessionsRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let lines = FieldSessionContextSnapshot.jobFlowLines(session: try XCTUnwrap(service.activeSession))
        let line = try XCTUnwrap(lines.first { $0.hasPrefix("JOB NUMBER: outstanding") })
        XCTAssertTrue(line.contains("set_job_reference"), line)
        XCTAssertTrue(line.contains("verbatim"), line)
    }
}

// MARK: - Vault names

final class VaultNameMatchingTests: XCTestCase {

    private let code = VaultManifest(id: "invented_code", name: "2030-29 Invented code", version: "1", files: [])
    private let other = VaultManifest(id: "other", name: "Refrigeration", version: "1", files: [])

    func testATrailingVaultAndALeadingTheAreLeftOut() throws {
        for asked in ["2030\u{2013}29 Invented code vault", "the 2030-29 Invented code vault", "The 2030-29 INVENTED Code"] {
            XCTAssertEqual(try VaultSelection.resolve(asked, defaultId: other.id, manifests: [code, other]),
                           code.id, asked)
        }
    }

    func testAVaultNamedVaultStillMatchesAndAWordAloneStillDoesNot() throws {
        let named = VaultManifest(id: "named", name: "Field Vault", version: "1", files: [])
        XCTAssertEqual(try VaultSelection.resolve("Field Vault", defaultId: other.id, manifests: [named, other]), named.id)
        XCTAssertThrowsError(try VaultSelection.resolve("vault", defaultId: other.id, manifests: [named, other]))
        XCTAssertThrowsError(try VaultSelection.resolve("Invented", defaultId: other.id, manifests: [code, other]))
    }
}

// MARK: - Chains start on request

@MainActor
final class ChainStartRequestTests: XCTestCase {

    private let chainName = "Voltage drop on a run"

    func testAQuestionAChainHappensToAnswerStartsNothing() {
        XCTAssertEqual(RuleChainTool.startRefusal(chain: chainName, said: "what's the voltage drop on 30 metres of 6 copper",
                                                  previousReply: nil, proposed: nil),
                       RuleChainTool.notAskedRefusal)
        XCTAssertTrue(RuleChainTool.notAskedRefusal.contains("you may offer the chain by name"))
    }

    func testNamingItAskingForAChainOrSayingYesToTheOfferStartsIt() {
        XCTAssertNil(RuleChainTool.startRefusal(chain: chainName, said: "run voltage drop on a run",
                                                previousReply: nil, proposed: nil))
        XCTAssertNil(RuleChainTool.startRefusal(chain: chainName, said: "use a chain for it", previousReply: nil, proposed: nil))
        XCTAssertNil(RuleChainTool.startRefusal(chain: chainName, said: "yes please",
                                                previousReply: "The Voltage drop on a run chain answers that. Run it?",
                                                proposed: nil))
        XCTAssertEqual(RuleChainTool.startRefusal(chain: chainName, said: "yes please",
                                                  previousReply: "The drop is 2.1%. Anything else?", proposed: nil),
                       RuleChainTool.notAskedRefusal, "a yes to something else is not a yes to a chain")
        XCTAssertNil(RuleChainTool.startRefusal(chain: chainName, said: "go", previousReply: nil, proposed: chainName),
                     "the proposal read back is waiting for go")
        XCTAssertNil(RuleChainTool.startRefusal(chain: chainName, said: nil, previousReply: nil, proposed: nil))
    }
}

// MARK: - 4/0 is 4/0

final class AWGSizeTests: XCTestCase {

    func testEveryWayOfWritingOrSayingAnAughtSizeIsOneForm() {
        for text in ["4/0", "4 / 0", "4/0 AWG", "No. 4/0", "#4/0", "0000", "four aught", "4 ought",
                     "quadruple aught", "four oh", "4/0 copper"] {
            XCTAssertEqual(AWGSize.canonical(text), "4/0", text)
        }
        XCTAssertEqual(AWGSize.canonical("00"), "2/0")
        XCTAssertEqual(AWGSize.canonical("double aught"), "2/0")
        XCTAssertEqual(AWGSize.canonical("1/0"), "1/0")
        XCTAssertEqual(AWGSize.canonical("0"), "1/0")
    }

    func testNumbersThatAreNotAughtSizesStayNumbers() {
        for text in ["4", "40", "0.5", "1.5 mm²", "10/0", "250 kcmil", "22/8841"] {
            XCTAssertNil(AWGSize.canonical(text), text)
        }
        XCTAssertNil(AWGSize.find(in: "the reading is 0 volts"), "a zero in a sentence is a zero")
        XCTAssertNil(AWGSize.find(in: "back at four o'clock"))
        XCTAssertNil(AWGSize.find(in: "two oh eight volts"))
    }

    func testFourOutIsASizeOnlyBesideAConductorWord() {
        XCTAssertEqual(AWGSize.find(in: "what about four out aluminum"), "4/0")
        XCTAssertNil(AWGSize.find(in: "four out of five breakers tripped"))
        XCTAssertEqual(AWGSize.find(in: "ampacity of 0000 copper"), "4/0")
    }

    func testTheElectricalDictationPassWritesSpokenSizesAsPrinted() {
        XCTAssertEqual(DictationVocabulary.postProcess("ampacity of four aught copper", trades: [.electrical]),
                       "ampacity of 4/0 copper")
        XCTAssertEqual(DictationVocabulary.postProcess("four out aluminum at 75", trades: [.electrical]),
                       "4/0 aluminum at 75")
        XCTAssertEqual(DictationVocabulary.postProcess("two oh eight volts", trades: [.electrical]),
                       "two oh eight volts")
        XCTAssertEqual(DictationVocabulary.postProcess("four aught copper", trades: [.refrigerationHVAC]),
                       "four aught copper", "only the electrical trade rewrites")
        XCTAssertTrue(DictationVocabulary.electricalGlossary.contains("0000"))
        XCTAssertTrue(DictationVocabulary.electricalGlossary.contains("four aught"))
    }
}

/// An invented ampacity table: rows printed "4", "3", "0000" and "250", one value column.
@MainActor
final class AughtSizeLookupTests: XCTestCase {

    private func table(rows: [(String, Double)]) -> TableLookup.Source {
        let page = ManualTable.Page(physical: 9, printed: "31")
        let table = ManualTable(
            label: "Table 99", title: "Invented ampacities", page: page, rowHeaders: ["Size"],
            columns: [.init(path: ["Copper"], unit: "A")],
            rows: rows.map { size, amps in
                ManualTable.Row(path: [size], cells: [.init(text: String(Int(amps)), value: amps, unit: "A")], page: page)
            })
        return .init(documentId: "inv", documentName: "Invented Book", table: table)
    }

    private var aughtsAsZeros: TableLookup.Source { table(rows: [("4", 11), ("3", 13), ("0000", 47), ("250", 52)]) }
    private var aughtsAsSlashes: TableLookup.Source { table(rows: [("4", 11), ("3", 13), ("4/0", 47), ("250", 52)]) }

    private func lookup(_ row: String, in source: TableLookup.Source) -> TableLookup.Outcome {
        TableLookup.resolve(.init(table: "Table 99", row: row), in: [source])
    }

    func testFourAughtFindsTheRowPrintedFourZeros() throws {
        for asked in ["4/0", "4/0 AWG", "0000", "four aught"] {
            guard case .found(let found) = lookup(asked, in: aughtsAsZeros) else {
                return XCTFail("\(asked) found nothing")
            }
            XCTAssertEqual(found.rows.map(\.path), [["0000"]], asked)
            XCTAssertNotEqual(found.basis, .number, asked)
        }
        guard case .found(let slash) = lookup("0000", in: aughtsAsSlashes) else { return XCTFail("0000 found nothing") }
        XCTAssertEqual(slash.rows.map(\.path), [["4/0"]])
        XCTAssertEqual(slash.basis, .awg)
    }

    func testAnAughtSizeNoRowPrintsIsNotFoundNeverRowFour() {
        let noAughts = table(rows: [("4", 11), ("3", 13), ("250", 52)])
        for asked in ["4/0", "0000", "four aught"] {
            guard case .notFound(.row, _, _) = lookup(asked, in: noAughts) else {
                return XCTFail("\(asked) must not be answered from row 4: \(lookup(asked, in: noAughts))")
            }
        }
    }

    func testANumberNoRowPrintsIsNeverDroppedAsALeftover() {
        guard case .notFound(.row, _, _) = lookup("4 0", in: table(rows: [("4", 11), ("3", 13)])) else {
            return XCTFail("a 0 left over must not be dropped")
        }
    }

    func testABareZeroIsANumberInATableWithNoAughtSizes() throws {
        let temperatures = table(rows: [("-10", 1), ("0", 2), ("10", 3)])
        guard case .found(let found) = lookup("0", in: temperatures) else { return XCTFail("0 is a row here") }
        XCTAssertEqual(found.rows.map(\.path), [["0"]])
    }

    func testARowFoundByNumberThatIsNotTheRowAskedSaysSo() throws {
        let source = aughtsAsZeros
        let four = source.table.rows[0]
        let wrong = TableLookup.Found(source: source, rows: [four], columns: [0], between: nil, unreadPages: [],
                                      basis: .number, askedRow: "4/0")
        let line = try XCTUnwrap(TableLookup.mismatchLine(wrong))
        XCTAssertEqual(line, "Asked for row \"4/0\"; matched row \"4\" by number — not the same row. "
                       + "Do not answer from it; ask which size.")
        XCTAssertTrue(TableLookup.render(.found(wrong)).contains(line))

        let right = TableLookup.Found(source: source, rows: [four], columns: [0], between: nil, unreadPages: [],
                                      basis: .number, askedRow: "4")
        XCTAssertNil(TableLookup.mismatchLine(right))
    }

    func testTheToolRefusesABareFourWhenTheTechnicianSaidFourAught() {
        XCTAssertNotNil(TableLookupTool.sizeRefusal(row: "4", said: "what's the ampacity of four aught copper"))
        XCTAssertNotNil(TableLookupTool.sizeRefusal(row: "No. 4", said: "ampacity of 4/0 aluminum"))
        XCTAssertNil(TableLookupTool.sizeRefusal(row: "4/0", said: "ampacity of four aught copper"))
        XCTAssertNil(TableLookupTool.sizeRefusal(row: "4", said: "compare 4 and 4/0"), "they said 4 as well")
        XCTAssertNil(TableLookupTool.sizeRefusal(row: "4", said: "ampacity of 4 copper"))
    }
}

// MARK: - Printed pages and pages on request

@MainActor
final class PrintedPageTests: XCTestCase {

    func testAPrintedPageIsReadFromTheWords() {
        XCTAssertEqual(ManualFigureTool.printedPage(in: "open printed page 57"), "57")
        XCTAssertEqual(ManualFigureTool.printedPage(in: "go to printed page number iv"), "iv")
        XCTAssertEqual(ManualFigureTool.printedPage(in: "show me page 12 as printed"), "12")
        XCTAssertNil(ManualFigureTool.printedPage(in: "show me page 63"))
    }

    func testTheLabelMapNamesEveryPageCarryingALabel() {
        let map = PageLabelMap([PageLabel(page: 3, label: "3", source: .printed),
                                PageLabel(page: 15, label: "3", source: .printed),
                                PageLabel(page: 63, label: "57", source: .printed)])
        XCTAssertEqual(map.physicalPages(forPrinted: "3"), [3, 15])
        XCTAssertNil(map.physical(forPrinted: "3"))
        XCTAssertEqual(map.physicalPages(forPrinted: "57"), [63])
        XCTAssertEqual(map.physicalPages(forPrinted: "400"), [])
    }

    func testAnUnknownOrRepeatedLabelIsRefusedNeverOpenedAsThePDFPage() {
        let unknown = ManualFigureTool.printedPageRefusal("57", repeatedIn: [])
        XCTAssertTrue(unknown.contains("nothing was opened"), unknown)
        XCTAssertTrue(unknown.contains("not PDF page 57 either"), unknown)
        let repeated = ManualFigureTool.printedPageRefusal("3", repeatedIn: ["Invented Book"])
        XCTAssertTrue(repeated.contains("more than one page of Invented Book"), repeated)
        XCTAssertEqual(ManualFigureTool.openedPageLine(physical: 63, printed: "57", documentTitle: "Invented Book"),
                       "Opened PDF page 63 (printed page 57) of Invented Book. Say this page, not the one you asked for.")
    }

    func testShowSourceOpensOnlyWhenTheTurnAskedToSee() {
        XCTAssertTrue(ShowSourceTool.mayOpen(said: "show me the table"))
        XCTAssertTrue(ShowSourceTool.mayOpen(said: nil), "a live-session turn is not gated")
        XCTAssertFalse(ShowSourceTool.mayOpen(said: "what's the ampacity of 4/0 copper at 75 degrees"))
        XCTAssertEqual(ShowSourceTool.notAskedReply, "Not opened — the technician didn't ask to see a page; offer it.")
    }

    func testTheToolOpensNothingOnATurnThatDidNotAsk() async throws {
        let tool = ShowSourceTool(documentStore: nil, currentUtterance: { "what's the ampacity of 4/0 copper" })
        let reply = try await tool.execute(args: ["which": "table"])
        XCTAssertEqual(reply, ShowSourceTool.notAskedReply)
    }
}
