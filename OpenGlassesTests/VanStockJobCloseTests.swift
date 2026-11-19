import XCTest
@testable import OpenGlasses

/// Plan IH P4 — a part used and never recorded is asked about before the job closes.
@MainActor
final class VanStockJobCloseTests: XCTestCase {

    private func part(_ number: String, _ description: String? = nil) -> TaskPart {
        TaskPart(number: number, partDescription: description, verified: true)
    }

    private func use(_ number: String?, _ description: String = "Igniter", quantity: Int = 1) -> VanStockUse {
        VanStockUse(id: UUID().uuidString, number: number, description: description, quantity: quantity,
                    unit: .each, verified: true, at: Date(timeIntervalSince1970: 1_790_000_000))
    }

    // MARK: The reconciler

    func testAPartOnAFinishedTaskWithNoUseIsListed() {
        let unrecorded = VanStockReconciler.unrecorded(partsUsed: [part("22B22"), part("14T65")],
                                                       uses: [use("22B22")], notFromVan: [])
        XCTAssertEqual(unrecorded.map(\.number), ["14T65"])
    }

    func testAUseHoweverItWasWrittenAccountsForThePart() {
        XCTAssertEqual(VanStockReconciler.unrecorded(partsUsed: [part("22B22")], uses: [use(" #22b22. ")], notFromVan: []), [])
    }

    func testADismissedPartStaysDismissedAndOthersAreStillAsked() {
        let unrecorded = VanStockReconciler.unrecorded(partsUsed: [part("22B22"), part("14T65")],
                                                       uses: [], notFromVan: ["14t65"])
        XCTAssertEqual(unrecorded.map(\.number), ["22B22"])
    }

    func testAPartNamedTwiceIsAskedAboutOnceAndAUseWithNoNumberAccountsForNothing() {
        let unrecorded = VanStockReconciler.unrecorded(partsUsed: [part("22B22"), part("22B22")],
                                                       uses: [use(nil, "Wire nuts")], notFromVan: [])
        XCTAssertEqual(unrecorded.map(\.number), ["22B22"])
    }

    func testNaming() {
        XCTAssertEqual(VanStockReconciler.named([]), "")
        XCTAssertEqual(VanStockReconciler.named([part("22B22", "Igniter")]), "Igniter (22B22)")
        XCTAssertEqual(VanStockReconciler.named([part("22B22", "Igniter"), part("14T65"), part("62-1", "Flame sensor")]),
                       "Igniter (22B22), 14T65 and Flame sensor (62-1)")
    }

    func testAUseReadsAsALineOfTheRecord() {
        XCTAssertEqual(use("22B22", quantity: 2).summary, "2 × Igniter (22B22)")
        XCTAssertEqual(use(nil, "Wire nuts").summary, "1 × Wire nuts")
        XCTAssertEqual(use("22B22", "").summary, "1 × 22B22")
    }

    // MARK: The close

    private var closing: JobCloseSequence.Inputs {
        JobCloseSequence.Inputs(requestedOutcome: .resolved, openVerifications: [], evidenceCount: 0,
                                evidenceDecided: true, signOff: .allowed, route: .voice)
    }

    func testWithNothingUnrecordedTheCloseProceeds() {
        XCTAssertEqual(JobCloseSequence.decide(closing), .proceed(outcome: .resolved))
    }

    func testByVoiceAnUnrecordedPartIsAskedAboutAndNamesBothAnswers() {
        var inputs = closing
        inputs.unrecordedVanParts = "Igniter (22B22)"
        guard case .ask(let question) = JobCloseSequence.decide(inputs) else { return XCTFail("it is asked about") }
        XCTAssertTrue(question.contains("Igniter (22B22)"), question)
        XCTAssertTrue(question.contains("'use'"), question)
        XCTAssertTrue(question.contains("'not_from_van'"), question)
    }

    func testTheScreensCloseIsNotHeldForIt() {
        var inputs = closing
        inputs.unrecordedVanParts = "Igniter (22B22)"
        inputs.route = .screen
        XCTAssertEqual(JobCloseSequence.decide(inputs), .proceed(outcome: .resolved))
    }

    func testASignOffRuleStillRefusesOnceThePartsAreAnswered() {
        var inputs = closing
        inputs.signOff = .blocked("sign")
        XCTAssertEqual(JobCloseSequence.decide(inputs), .refuse("sign"))
    }

    // MARK: The service tells the job

    func testAUseOnAnOpenJobIsToldToTheJobAndAnUndoTakesItBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-job-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        var job: VanStockService.Job? = .init(sessionID: "s1", reference: "job-2031")
        var recorded: [VanStockUse] = []
        var dismissed: [String] = []
        let service = VanStockService(
            store: VanStockStore(directory: directory, now: clock),
            verify: { TaskPart(number: VaultPartsIndex.normalise($0), verified: true) },
            partsIndex: { VaultPartsIndex(files: []) },
            activeJob: { job },
            now: { clock },
            jobUses: .init(record: { recorded.append($0) },
                           remove: { ids in recorded.removeAll { ids.contains($0.id) } },
                           notFromVan: { dismissed.append($0); return job != nil },
                           unrecorded: { [TaskPart(number: "14T65", partDescription: "Pressure switch", verified: true)] }))

        _ = service.load([.init(part: "22B22", description: "Igniter", quantity: 3)])
        XCTAssertTrue(recorded.isEmpty, "a load is not a use")
        clock.addTimeInterval(60)
        _ = service.use([.init(part: "22B22", quantity: 2)])
        XCTAssertEqual(recorded.map(\.summary), ["2 × Igniter (22B22)"])
        XCTAssertEqual(recorded.first?.verified, true)

        clock.addTimeInterval(60)
        _ = service.undo()
        XCTAssertTrue(recorded.isEmpty, "the undone use comes off the job too")

        // With no job open a use is still recorded on the van, and told to nobody.
        job = nil
        clock.addTimeInterval(60)
        _ = service.use([.init(part: "22B22", quantity: 1)])
        XCTAssertTrue(recorded.isEmpty)

        let asked = service.unrecorded()
        XCTAssertTrue(asked.contains("Pressure switch (14T65)"), asked)
        XCTAssertTrue(asked.contains("do not record a use they did not confirm"), asked)

        XCTAssertTrue(service.notFromVan(.init(part: "14T65")).contains("no job open"))
        job = .init(sessionID: "s1", reference: nil)
        XCTAssertTrue(service.notFromVan(.init(part: " 14t65 ")).hasPrefix("Noted: 14T65 did not come off the van"))
        XCTAssertEqual(dismissed.last, "14t65")
        XCTAssertTrue(service.notFromVan(.init(description: "the switch")).contains("by its part number"))
    }

    // MARK: Every place (Plan MK P1)

    func testTheQuestionIsInThePlacesWordsAndAVanHearsWhatItAlwaysDid() {
        var inputs = closing
        inputs.unrecordedVanParts = "Igniter (22B22)"
        guard case .ask(let vanQuestion) = JobCloseSequence.decide(inputs) else { return XCTFail("asked") }
        XCTAssertEqual(vanQuestion, "Not closed yet: there is no van stock entry on this job for Igniter (22B22). "
                       + "Ask the technician whether each came off the van. For one that did, call van_stock with "
                       + "action 'use', the part and how many. For one that was ordered in or was the customer's, "
                       + "call van_stock with action 'not_from_van' and the part. Then close the job again.")
        for kind in StockPlace.Kind.allCases {
            inputs.stockPlace = kind
            guard case .ask(let question) = JobCloseSequence.decide(inputs) else { return XCTFail("\(kind) is asked too") }
            XCTAssertEqual(StockPlaceWordCheck.violations(question, kind: kind), [], "\(kind): \(question)")
            XCTAssertTrue(question.contains(StockPlaceWording(kind).cameFrom), "\(kind): \(question)")
            XCTAssertTrue(question.contains("'not_from_van'"), "\(kind)")
        }
    }
}
