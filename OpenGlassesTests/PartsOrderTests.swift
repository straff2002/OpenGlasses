import XCTest
@testable import OpenGlasses

/// A parts order on its own: a technician who used a part and asked for "an email to order a new
/// one" was offered only the whole job report, because nothing else could carry an order — and the
/// request then sat "waiting" in the Jobs tab with no way to act on it.
///
/// Headless: the order's words and route are pure, the tool stages through an injected session
/// service, and no composer is presented, no Contacts read and no network touched.
@MainActor
final class PartsOrderTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PartsOrderTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixtures

    private func igniter(verified: Bool = true) -> TaskPart {
        TaskPart(number: "70W16", partDescription: "Hot surface igniter", verified: verified,
                 page: verified ? "Service Manual, page 41" : nil)
    }

    private func request(_ id: String, _ part: TaskPart, quantity: Int = 1,
                         status: PartsRequest.Status = .requested, urgency: PartsRequest.Urgency = .routine,
                         onVan: Bool = false, model: String? = "SLP99UH090") -> PartsRequest {
        PartsRequest(id: id, part: part, quantity: quantity, modelToken: model, urgency: urgency,
                     onVan: onVan, status: status)
    }

    private func order(_ requests: [PartsRequest], job: String? = "1029", note: String? = nil,
                       requestId: String? = nil) -> PartsOrder? {
        PartsOrder(sessionId: "0123456789abcdef", jobReference: job, vaultName: "Lennox SLP99",
                   equipmentModel: "SLP99UH090", partsRequests: requests, requestId: requestId, note: note)
    }

    private func settings(email: [String] = ["office@example.com"], messages: [String] = [],
                          channels: Set<DeliveryChannel> = DeliveryChannel.localChannels) -> DeliverySettings {
        DeliverySettings(emailRecipients: email, messageRecipients: messages, allowedChannels: channels)
    }

    private func liveSession(jobReference: String? = "1029") throws -> FieldSessionService {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions"))
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: jobReference)
        return service
    }

    private func loggedEvents(_ service: FieldSessionService) throws -> [SessionLogger.Event] {
        let id = try XCTUnwrap(service.activeSession?.id)
        let url = tempRoot.appendingPathComponent("sessions/\(id)/log.jsonl")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return raw.split(separator: "\n").compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionLogger.Event.self, from: data)
        }
    }

    // MARK: - Which requests are in it

    func testOnlyRequestsStillWaitingAreOrdered() throws {
        let made = try XCTUnwrap(order([
            request("a", igniter()),
            request("b", igniter(), status: .sent),
            request("c", igniter(), status: .answered),
            request("d", igniter(), quantity: 2),
        ]))
        XCTAssertEqual(made.partsRequestIds, ["a", "d"], "sent and answered requests are never ordered twice")
        XCTAssertEqual(made.spokenList, "1 × 70W16, 2 × 70W16")
    }

    func testNothingWaitingIsNoOrder() {
        XCTAssertNil(order([]))
        XCTAssertNil(order([request("b", igniter(), status: .sent), request("c", igniter(), status: .answered)]))
    }

    func testOneRequestCanBeOrderedOnItsOwn() throws {
        let made = try XCTUnwrap(order([request("a", igniter()), request("d", igniter())], requestId: "d"))
        XCTAssertEqual(made.partsRequestIds, ["d"])
        XCTAssertNil(order([request("a", igniter()), request("b", igniter(), status: .sent)], requestId: "b"),
                     "a request already sent is not ordered again, even by id")
    }

    // MARK: - What it says

    func testTheSubjectNamesTheJobAndTheVault() throws {
        XCTAssertEqual(try XCTUnwrap(order([request("a", igniter())])).subject,
                       "Parts request — Job 1029 — Lennox SLP99")
        XCTAssertEqual(try XCTUnwrap(order([request("a", igniter())], job: nil)).subject,
                       "Parts request — Lennox SLP99 — job record 01234567")
    }

    func testEachLineSaysWhatItIsAndWhatItIsFor() throws {
        let made = try XCTUnwrap(order([
            request("a", igniter()),
            request("b", igniter(verified: false), quantity: 2, urgency: .today, onVan: true, model: nil),
        ], note: "Customer's unit is on its last igniter."))
        XCTAssertEqual(made.line(for: made.requests[0]),
                       "1 × 70W16 (Hot surface igniter) — verified, Service Manual, page 41 — routine — for this job — unit SLP99UH090")
        XCTAssertEqual(made.line(for: made.requests[1]),
                       "2 × 70W16 (Hot surface igniter) — unverified, not found in the manuals — today — to restock the van — unit SLP99UH090",
                       "a request with no model of its own takes the job's unit")

        let body = made.body
        XCTAssertTrue(body.hasPrefix("Parts request — Job 1029 — Lennox SLP99"), body)
        XCTAssertTrue(body.contains("Please order:\n• 1 × 70W16"), body)
        XCTAssertTrue(body.contains("Job: 1029\nUnit: SLP99UH090"), body)
        XCTAssertTrue(body.contains("Note from the technician: Customer's unit is on its last igniter."), body)
        XCTAssertTrue(body.contains("Check the number before ordering."), body)
        XCTAssertEqual(made.shortBody, "Parts request — Job 1029: 1 × 70W16 (routine), 2 × 70W16 (today, unverified).")
    }

    func testAVerifiedOrderCarriesNoWarningAndNoEmptyNote() throws {
        let body = try XCTUnwrap(order([request("a", igniter())], note: "   ")).body
        XCTAssertFalse(body.contains("unverified"), body)
        XCTAssertFalse(body.contains("Note from the technician"), body)
    }

    // MARK: - Where it goes

    func testItGoesByEmailToTheOfficeByDefault() {
        let route = PartsOrder.route(policy: DeliveryPolicy(settings: settings()))
        XCTAssertEqual(route, .ready(channel: .email, recipients: ["office@example.com"]))
    }

    func testANamedAddressWins() {
        let route = PartsOrder.route(policy: DeliveryPolicy(settings: settings(email: [])),
                                     spoken: ["parts@example.com"])
        XCTAssertEqual(route, .ready(channel: .email, recipients: ["parts@example.com"]))
    }

    func testWithNoEmailRecipientItFollowsTheReportsDefault() {
        let route = PartsOrder.route(policy: DeliveryPolicy(settings: settings(email: [])))
        XCTAssertEqual(route, .ready(channel: .shareSheet, recipients: []))
    }

    func testNoChannelIsARefusalNotAGuess() {
        guard case .refused(let reason) = PartsOrder.route(policy: DeliveryPolicy(settings: settings(channels: []))) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("Settings"), reason)
    }

    // MARK: - The request

    func testTheRequestIsTextOnlyAndNotAQueuedRecord() throws {
        let made = try XCTUnwrap(order([request("a", igniter())]))
        let staged = DeliveryRequest.make(partsOrder: made, channel: .email, recipients: ["office@example.com"])
        XCTAssertEqual(staged.payload, .partsOrder(made))
        XCTAssertEqual(staged.partsRequestIds, ["a"])
        XCTAssertEqual(staged.sessionId, made.sessionId)
        XCTAssertEqual(staged.jobReference, "1029")
        XCTAssertNil(staged.record, "a parts order is not the job report")
        XCTAssertTrue(staged.attachments.isEmpty)
        XCTAssertNil(staged.payload.queuedOp(), "each request was queued when it was asked for")
        XCTAssertEqual(ReportComposerModel(request: staged).filledBody, made.body)
        XCTAssertTrue(staged.confirmation.contains("tap Send"), staged.confirmation)
        XCTAssertTrue(staged.confirmation.contains("separate from the job report"), staged.confirmation)
    }

    // MARK: - When the composer closes

    func testASentOrderMarksExactlyItsRequestsSentAndIsNotTheReport() throws {
        let service = try liveSession()
        let first = try XCTUnwrap(service.requestPart(igniter()))
        let staged = DeliveryRequest.make(partsOrder: try XCTUnwrap(service.partsOrder()),
                                          channel: .email, recipients: ["office@example.com"])
        // Asked for while the composer was open: not in this order, so not sent by it.
        let later = try XCTUnwrap(service.requestPart(igniter(), quantity: 3))
        service.stageDelivery(staged)

        service.completeDelivery(staged, outcome: .sent)

        let parts = try XCTUnwrap(service.activeSession?.partsRequests)
        XCTAssertEqual(parts.first { $0.id == first.id }?.status, .sent)
        XCTAssertEqual(parts.first { $0.id == later.id }?.status, .requested)
        XCTAssertNil(service.stagedDelivery)
        XCTAssertFalse(service.lastDeliveryCancelled)

        let events = try loggedEvents(service)
        let sent = try XCTUnwrap(events.last { $0.kind == .partsOrderSent })
        XCTAssertEqual(sent.text, "Parts order sent — 1 × 70W16")
        XCTAssertEqual(sent.payload?["parts_requests"]?.value as? Int, 1)
        XCTAssertNil(events.last { $0.kind == .reportSent }, "an order going must not make the report look sent")
        XCTAssertEqual(service.partsOrder()?.partsRequestIds, [later.id], "only the later request is still waiting")
    }

    func testACancelledOrderLeavesTheRequestsWaiting() throws {
        let service = try liveSession()
        _ = service.requestPart(igniter())
        let staged = DeliveryRequest.make(partsOrder: try XCTUnwrap(service.partsOrder()),
                                          channel: .email, recipients: ["office@example.com"])
        service.stageDelivery(staged)
        service.completeDelivery(staged, outcome: .cancelled)

        XCTAssertEqual(service.activeSession?.partsRequests.first?.status, .requested)
        XCTAssertFalse(service.lastDeliveryCancelled, "a dismissed order says nothing about the report")
        let events = try loggedEvents(service)
        XCTAssertEqual(events.last { $0.kind == .partsOrderNotSent }?.text, "Parts order not sent — 1 × 70W16")
        XCTAssertNil(events.last { $0.kind == .reportCancelled })
    }

    func testAFailedOrderLeavesTheRequestsWaiting() throws {
        let service = try liveSession()
        _ = service.requestPart(igniter())
        let staged = DeliveryRequest.make(partsOrder: try XCTUnwrap(service.partsOrder()),
                                          channel: .email, recipients: ["office@example.com"])
        service.completeDelivery(staged, outcome: .failed("no mail account"))
        XCTAssertEqual(service.activeSession?.partsRequests.first?.status, .requested)
        let failed = try XCTUnwrap(try loggedEvents(service).last { $0.kind == .partsOrderFailed })
        XCTAssertEqual(failed.payload?["error"]?.value as? String, "no mail account")
    }

    func testAFinishedJobsWaitingRequestsCanStillBeOrdered() throws {
        let service = try liveSession()
        _ = service.requestPart(igniter())
        let ended = try service.endSession(outcome: .resolved)
        let made = try XCTUnwrap(service.partsOrder(sessionId: ended.id))
        let staged = DeliveryRequest.make(partsOrder: made, channel: .email, recipients: ["office@example.com"])
        service.completeDelivery(staged, outcome: .sent)
        let stored = try XCTUnwrap(service.history.first { $0.id == ended.id })
        XCTAssertEqual(stored.partsRequests.first?.status, .sent)
        XCTAssertNotNil(stored.endedAt)
        XCTAssertNil(service.partsOrder(sessionId: ended.id), "nothing left waiting on it")
    }

    // MARK: - By voice

    func testSendStagesTheOrderThroughTheSession() async throws {
        let service = try liveSession()
        _ = service.requestPart(igniter())
        let tool = PartsRequestTool(sessionService: service, settings: { self.settings() },
                                    resolveEmail: { _ in [] })

        let reply = try await tool.execute(args: ["action": "send", "note": "Van is out."])

        let staged = try XCTUnwrap(service.stagedDelivery, "the tool stages; the app presents")
        let made = try XCTUnwrap(staged.payload.partsOrder)
        XCTAssertEqual(staged.channel, .email)
        XCTAssertEqual(staged.recipients, ["office@example.com"])
        XCTAssertEqual(made.note, "Van is out.")
        XCTAssertEqual(service.activeSession?.partsRequests.first?.status, .requested,
                       "nothing is marked sent until the composer says it went")
        XCTAssertTrue(reply.contains("tap Send"), reply)
    }

    func testSendTakesTheAddressTheTechnicianNamed() async throws {
        let service = try liveSession()
        _ = service.requestPart(igniter())
        let tool = PartsRequestTool(sessionService: service, settings: { self.settings() },
                                    resolveEmail: { name in
                                        name == "parts desk"
                                            ? [ContactLookupHelper.ResolvedEmail(name: "Parts Desk", address: "parts@example.com", label: "work")]
                                            : []
                                    })
        _ = try await tool.execute(args: ["action": "send", "to": "parts desk"])
        XCTAssertEqual(service.stagedDelivery?.recipients, ["parts@example.com"])
    }

    func testSendWithNothingWaitingStagesNothing() async throws {
        let service = try liveSession()
        let tool = PartsRequestTool(sessionService: service, settings: { self.settings() },
                                    resolveEmail: { _ in [] })
        let reply = try await tool.execute(args: ["action": "send"])
        XCTAssertNil(service.stagedDelivery)
        XCTAssertTrue(reply.contains("Nothing on this job is waiting to be ordered"), reply)
    }

    func testAFractionOfAPartIsRefusedAndNothingIsRequested() async throws {
        let service = try liveSession()
        let tool = PartsRequestTool(sessionService: service, settings: { self.settings() },
                                    resolveEmail: { _ in [] })
        let reply = try await tool.execute(args: ["part": "70W16", "quantity": 2.5])
        XCTAssertEqual(reply, "Nothing was requested. A parts request is a whole number of parts, and 2.5 is not one. Ask how many.")
        XCTAssertEqual(service.activeSession?.partsRequests.count, 0)
    }

    func testAWholeNumberSentAsADecimalIsRequestedWhole() async throws {
        let service = try liveSession()
        let tool = PartsRequestTool(sessionService: service, settings: { self.settings() },
                                    resolveEmail: { _ in [] })
        let reply = try await tool.execute(args: ["part": "70W16", "quantity": 3.0])
        XCTAssertTrue(reply.hasPrefix("Requested 3 × 70W16"), reply)
        XCTAssertEqual(service.activeSession?.partsRequests.map(\.quantity), [3])
    }

    func testTheDescriptionsPointAnOrderAtPartsRequestNotTheReport() {
        let parts = PartsRequestTool().description
        XCTAssertTrue(parts.contains("action 'send'"), parts)
        XCTAssertTrue(parts.contains("separate from the job"), parts)
        let report = DeliverReportTool().description
        XCTAssertTrue(report.contains("parts_request with action 'send'"), report)
    }

    // MARK: - The Jobs tab

    private func daySession(open: Int, unsent: Int) -> JobDaySession {
        JobDaySession(id: "s1", jobReference: "1029", customer: nil, siteHeadline: nil,
                      startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, isPaused: false,
                      cancelled: false, openPartsRequests: open, unsentPartsRequests: unsent)
    }

    func testAnUnsentRequestSaysItIsWaitingToBeEmailedAndOpensTheOrder() throws {
        let todos = JobDayComposer.owed(sessions: [daySession(open: 1, unsent: 1)], finishedInScope: [],
                                        queue: [], debrief: nil, signOffRequired: false,
                                        now: Date(timeIntervalSince1970: 0))
        let todo = try XCTUnwrap(todos.first { $0.kind == .parts })
        XCTAssertEqual(todo.title, "Parts request waiting to be emailed")
        XCTAssertEqual(todo.destination, .partsOrder(sessionId: "s1"))
        XCTAssertNil(JobListRequest(todo.destination), "it opens the composer, not a page of the tab")

        let two = JobDayComposer.owed(sessions: [daySession(open: 3, unsent: 2)], finishedInScope: [],
                                      queue: [], debrief: nil, signOffRequired: false,
                                      now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(two.first { $0.kind == .parts }?.title, "2 parts requests waiting to be emailed")
    }

    func testARequestAlreadySentWaitsOnBaseAndOpensTheJob() throws {
        let todos = JobDayComposer.owed(sessions: [daySession(open: 1, unsent: 0)], finishedInScope: [],
                                        queue: [], debrief: nil, signOffRequired: false,
                                        now: Date(timeIntervalSince1970: 0))
        let todo = try XCTUnwrap(todos.first { $0.kind == .parts })
        XCTAssertEqual(todo.title, "Parts request waiting")
        XCTAssertEqual(todo.destination, .openJob)
    }
}
