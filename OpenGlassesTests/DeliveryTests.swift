import XCTest
@testable import OpenGlasses

/// Plan EM P2 — the finished record leaving the device, and never leaving it silently.
///
/// Everything here is headless. No composer is presented, no network is touched (the endpoint sink
/// runs against a `URLProtocol` stub), and no Contacts database is read — the tool's contact
/// resolution is injected. What is proven is the half that decides: which channel, to whom, with
/// what attached, what a refusal says, and what happens to the record when nobody taps Send.
@MainActor
final class DeliveryTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryTests-\(UUID().uuidString)", isDirectory: true)
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

    private func part(_ number: String, verified: Bool = true) -> TaskPart {
        TaskPart(number: number, partDescription: "High-altitude pressure switch",
                 verified: verified, page: verified ? "parts.md § Conversion and high altitude" : nil)
    }

    /// A record with one task done, one declined and one stock check outstanding.
    private func record(jobReference: String? = "4471",
                        partsStatus: PartsRequest.Status = .requested) -> WorkRecord {
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let done = FieldSession.Task(
            id: "task-done", title: "Check the pressure switch tubing", why: "Lockout on rise",
            origin: .recommended, status: .done, citation: "Service Manual, page 3",
            parts: [part("14T65")],
            evidence: FieldSession.Evidence(readings: ["flow@1"], photos: ["a.jpg"],
                                            citationsOpened: [], pagesVerified: ["Service Manual, page 3"]),
            completionNote: "Reseated the tubing",
            createdAt: started, acceptedAt: started, completedAt: started.addingTimeInterval(600))
        let declined = FieldSession.Task(
            id: "task-declined", title: "Replace the ignitor", origin: .recommended,
            status: .declined, citation: "Service Manual, page 8", createdAt: started)
        let request = PartsRequest(id: "req-1", part: part("14T65"), quantity: 2,
                                   taskId: "task-done", modelToken: "SLP99UH090XV60CK",
                                   urgency: .today, status: partsStatus, createdAt: started)
        let session = FieldSession(
            id: "session-1", vaultId: "lennox_slp99", assetId: nil, mode: .aiOnly,
            startedAt: started, endedAt: started.addingTimeInterval(1200), outcome: .resolved,
            escalations: [], billableSeconds: 1200,
            jobReference: jobReference, tasks: [done, declined], partsRequests: [request])
        return WorkRecord(session: session, vaultName: "Lennox SLP99 Furnace Service")
    }

    /// Two files on disk, so an attachment's bytes are real without exporting a PDF.
    private func attachments() -> [DeliveryRequest.Attachment] {
        let pdf = tempRoot.appendingPathComponent("job-4471.pdf")
        let json = tempRoot.appendingPathComponent("job-4471.json")
        try? Data("%PDF-1.4".utf8).write(to: pdf)
        try? Data(#"{"job":"4471"}"#.utf8).write(to: json)
        return [.init(url: pdf, kind: .pdf, filename: "job-4471.pdf"),
                .init(url: json, kind: .json, filename: "job-4471.json")]
    }

    private func settings(email: [String] = ["office@example.com"],
                          messages: [String] = ["+64210000000"],
                          endpoint: String = "",
                          token: String = "",
                          channels: Set<DeliveryChannel> = DeliveryChannel.localChannels) -> DeliverySettings {
        DeliverySettings(emailRecipients: email, messageRecipients: messages,
                         endpoint: endpoint, endpointToken: token, allowedChannels: channels)
    }

    // MARK: - Policy

    func testDefaultSettingsAllowEveryLocalChannelAndNoEndpoint() {
        let policy = DeliveryPolicy(settings: DeliverySettings())
        XCTAssertEqual(Set(policy.availableChannels), DeliveryChannel.localChannels)
        XCTAssertFalse(policy.availableChannels.contains(.endpoint))
        // Nothing is addressed yet, so the share sheet is the honest default — it needs nobody.
        XCTAssertEqual(policy.defaultChannel, .shareSheet)
    }

    func testTheEndpointBecomesAvailableOnlyOnceOneIsConfigured() {
        var configured = settings(channels: DeliveryChannel.localChannels.union([.endpoint]))
        XCTAssertFalse(DeliveryPolicy(settings: configured).availableChannels.contains(.endpoint),
                       "allowed but unset is not available")
        XCTAssertEqual(DeliveryPolicy(settings: configured).decide(channel: .endpoint).reason,
                       "No endpoint is configured for job reports. Set one in Settings → Field Assist → Job reports, or send it by email.")

        configured.endpoint = "https://ops.example.com/job-reports"
        XCTAssertTrue(DeliveryPolicy(settings: configured).availableChannels.contains(.endpoint))
        XCTAssertTrue(DeliveryPolicy(settings: configured).decide(channel: .endpoint).isAllowed)

        // Something that is not a URL is not an endpoint, however it was typed.
        configured.endpoint = "ops.example.com"
        XCTAssertFalse(DeliveryPolicy(settings: configured).availableChannels.contains(.endpoint))
    }

    func testEmailIsTheDefaultWhenItIsAddressedAndTheShareSheetWhenItIsNot() {
        XCTAssertEqual(DeliveryPolicy(settings: settings()).defaultChannel, .email)
        XCTAssertEqual(DeliveryPolicy(settings: settings(email: [])).defaultChannel, .messages)
        XCTAssertEqual(DeliveryPolicy(settings: settings(email: [], messages: [])).defaultChannel, .shareSheet)
    }

    func testARefusedChannelSaysSoAndNamesWhatIsAllowed() {
        let policy = DeliveryPolicy(settings: settings(channels: [.email, .shareSheet]))
        let refusal = policy.decide(channel: .whatsapp)
        XCTAssertFalse(refusal.isAllowed)
        let reason = try? XCTUnwrap(refusal.reason)
        XCTAssertTrue(reason?.contains("WhatsApp isn't one of the channels") == true, reason ?? "")
        XCTAssertTrue(reason?.contains("Allowed channels are email and the share sheet.") == true, reason ?? "")
    }

    func testAChannelWithNobodyToSendToIsRefusedRatherThanAddressedToNobody() {
        let policy = DeliveryPolicy(settings: settings(email: []))
        guard case .refused(let reason) = policy.decide(channel: .email) else {
            return XCTFail("an unaddressed email must be refused")
        }
        XCTAssertTrue(reason.contains("nobody to send it to by email"), reason)
        // The share sheet picks its own destination, so it is never refused for want of one.
        XCTAssertTrue(policy.decide(channel: .shareSheet).isAllowed)
    }

    func testASpokenRecipientBeatsTheConfiguredDefault() {
        let policy = DeliveryPolicy(settings: settings())
        XCTAssertEqual(policy.decide(channel: .email), .allowed(recipients: ["office@example.com"]))
        XCTAssertEqual(policy.decide(channel: .email, spoken: ["dave@example.com"]),
                       .allowed(recipients: ["dave@example.com"]))
        // Whitespace-only is not a recipient; it falls back rather than addressing an empty string.
        XCTAssertEqual(policy.decide(channel: .email, spoken: ["  "]),
                       .allowed(recipients: ["office@example.com"]))
    }

    // MARK: - Settings storage

    func testSettingsRoundTripAndTheTokenIsNeverInPreferences() throws {
        let suiteName = "DeliveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secret = "tok_\(UUID().uuidString)"
        let stored = settings(endpoint: "https://ops.example.com/job-reports", token: secret,
                              channels: [.email, .endpoint])
        stored.save(defaults: defaults)

        let blob = try XCTUnwrap(defaults.data(forKey: DeliverySettings.storageKey))
        let text = try XCTUnwrap(String(data: blob, encoding: .utf8))
        XCTAssertFalse(text.contains(secret), "the bearer token must never reach UserDefaults: \(text)")
        XCTAssertFalse(text.contains("endpointToken"), text)

        let loaded = DeliverySettings.load(defaults: defaults)
        XCTAssertEqual(loaded.emailRecipients, stored.emailRecipients)
        XCTAssertEqual(loaded.messageRecipients, stored.messageRecipients)
        XCTAssertEqual(loaded.endpoint, stored.endpoint)
        XCTAssertEqual(loaded.allowedChannels, stored.allowedChannels)
        // The Keychain is the token's only home. A simulator without a signed keychain cannot
        // store it at all, and that is an environment fact rather than a regression.
        if KeychainService.string(for: DeliverySettings.tokenKeychainKey) != nil {
            XCTAssertEqual(loaded.endpointToken, secret)
        }
        _ = KeychainService.delete(DeliverySettings.tokenKeychainKey)
    }

    func testStoredSettingsFromBeforeThisFeatureDecodeWithEveryLocalChannelAllowed() throws {
        let json = Data(#"{"email_recipients":["a@b.c"]}"#.utf8)
        let decoded = try JSONDecoder().decode(DeliverySettings.self, from: json)
        XCTAssertEqual(decoded.emailRecipients, ["a@b.c"])
        XCTAssertEqual(decoded.allowedChannels, DeliveryChannel.localChannels)
        XCTAssertEqual(decoded.endpointToken, "")
    }

    func testAnOrganisationSubtractsChannelsAndSuppliesDestinations() {
        let device = settings(channels: [.email, .messages, .shareSheet])
        let organisation = DeliverySettings(emailRecipients: ["dispatch@acme.test"],
                                            endpoint: "https://acme.test/jobs",
                                            allowedChannels: [.email, .whatsapp, .endpoint])
        let merged = device.applying(organisation: organisation)
        XCTAssertEqual(merged.emailRecipients, ["dispatch@acme.test"])
        XCTAssertEqual(merged.endpoint, "https://acme.test/jobs")
        // WhatsApp was permitted by the organisation and switched off on the device: it stays off.
        XCTAssertEqual(merged.allowedChannels, [.email])
        // What the organisation says nothing about is left alone.
        XCTAssertEqual(merged.messageRecipients, device.messageRecipients)
    }

    // MARK: - The request

    func testTheRequestCarriesTheThreeShapesOfOneRecord() {
        let record = record()
        let request = DeliveryRequest.make(record: record, channel: .email,
                                           recipients: ["office@example.com"],
                                           attachments: attachments())
        XCTAssertEqual(request.subject, "Job 4471 — Lennox SLP99 Furnace Service")
        XCTAssertEqual(request.body, record.summary)
        XCTAssertTrue(request.shortBody.contains("Job 4471"), request.shortBody)
        XCTAssertTrue(request.shortBody.contains("1 task done"), request.shortBody)
        XCTAssertTrue(request.shortBody.contains("2 × 14T65"), request.shortBody)
        XCTAssertEqual(request.attachments.count, 2)
        XCTAssertEqual(request.partsRequestIds, ["req-1"])
        XCTAssertEqual(request.jobReference, "4471")
    }

    func testAChannelThatCannotCarryAFileIsNotHandedOne() {
        let request = DeliveryRequest.make(record: record(), channel: .whatsapp,
                                           recipients: ["+64210000000"], attachments: attachments())
        XCTAssertTrue(request.attachments.isEmpty)
        XCTAssertTrue(request.confirmation.contains("can't carry a file"), request.confirmation)
    }

    func testAStockCheckAlreadySentIsNotSentTwice() {
        let request = DeliveryRequest.make(record: record(partsStatus: .sent), channel: .email,
                                           recipients: ["office@example.com"], attachments: [])
        XCTAssertTrue(request.partsRequestIds.isEmpty)
    }

    func testTheFileNameIsTheJobNotTheSessionUUID() {
        XCTAssertEqual(record().reportFileStem, "job-4471")
        XCTAssertEqual(record(jobReference: nil).reportFileStem, "job-session-")
        XCTAssertEqual(record(jobReference: "44/71 A").reportFileStem, "job-44-71-A")
    }

    // MARK: - The composer model

    func testTheComposerFillsInTheRecordForMailAndTheShortFormForMessages() {
        let record = record()
        let mail = ReportComposerModel(request: DeliveryRequest.make(
            record: record, channel: .email, recipients: ["office@example.com"],
            attachments: attachments()))
        XCTAssertEqual(mail.body, record.summary)
        XCTAssertEqual(mail.attachments.count, 2)
        XCTAssertNil(mail.attachmentNote)
        XCTAssertEqual(mail.filledBody, record.summary)

        let messages = ReportComposerModel(request: DeliveryRequest.make(
            record: record, channel: .messages, recipients: ["+64210000000"],
            attachments: attachments()))
        XCTAssertEqual(messages.body, record.shortSummary)
    }

    func testADeviceThatCannotAttachSaysSoInTheBodyRatherThanDroppingTheRecordSilently() {
        let request = DeliveryRequest.make(record: record(), channel: .messages,
                                           recipients: ["+64210000000"], attachments: attachments())
        let model = ReportComposerModel(request: request, canSendAttachments: false)
        XCTAssertTrue(model.attachments.isEmpty)
        let note = try? XCTUnwrap(model.attachmentNote)
        XCTAssertTrue(model.filledBody.hasSuffix(note ?? "!"), model.filledBody)
    }

    func testWithoutAMailAccountTheReportGoesToTheShareSheetAndSaysWhy() {
        let fallback = ReportComposerAvailability.resolve(.email, canSendMail: false, canSendText: true)
        XCTAssertEqual(fallback.channel, .shareSheet)
        XCTAssertTrue(fallback.note?.contains("no Mail account") == true, fallback.note ?? "")

        let texting = ReportComposerAvailability.resolve(.messages, canSendMail: true, canSendText: false)
        XCTAssertEqual(texting.channel, .shareSheet)

        let unchanged = ReportComposerAvailability.resolve(.email, canSendMail: true, canSendText: true)
        XCTAssertEqual(unchanged, .init(channel: .email, note: nil))
    }

    func testComposerResultsMapOntoWhatTheRecordShouldDo() {
        // Mail: cancelled 0, saved 1, sent 2, failed 3. Messages: cancelled 0, sent 1, failed 2 —
        // the two enumerations do not line up, which is exactly why this mapping is its own type.
        XCTAssertEqual(ReportComposerOutcome.mail(result: 2, error: nil), .sent)
        XCTAssertEqual(ReportComposerOutcome.mail(result: 1, error: nil), .saved)
        XCTAssertEqual(ReportComposerOutcome.mail(result: 0, error: nil), .cancelled)
        guard case .failed = ReportComposerOutcome.mail(result: 3, error: nil) else {
            return XCTFail("Mail reporting a failure is a failure")
        }
        XCTAssertEqual(ReportComposerOutcome.message(result: 0), .cancelled) // .cancelled
        XCTAssertEqual(ReportComposerOutcome.message(result: 1), .sent)      // .sent
        guard case .failed = ReportComposerOutcome.message(result: 2) else {
            return XCTFail("a failed send is not a cancellation")
        }
        guard case .failed = ReportComposerOutcome.mail(result: 2, error: URLError(.timedOut)) else {
            return XCTFail("an error is a failure whatever the result code says")
        }
        // Only a confirmed send moves anything.
        XCTAssertFalse(DeliveryOutcome.saved.isSent)
        XCTAssertFalse(DeliveryOutcome.handedOff.isSent)
        XCTAssertFalse(DeliveryOutcome.cancelled.isSent)
        XCTAssertTrue(DeliveryOutcome.sent.isSent)
    }

    // MARK: - The tool

    /// A live service on the bundled refrigeration vault, with the exporter stubbed out so no PDF
    /// is rendered for a test about which channel was chosen.
    private func liveSession(jobReference: String? = "4471") throws -> FieldSessionService {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions"))
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: jobReference)
        let files = attachments()
        service.reportAttachmentsProvider = { files }
        return service
    }

    func testTheToolStagesAReportRatherThanSendingOne() async throws {
        let service = try liveSession()
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() })

        let reply = try await tool.execute(args: [:])
        let staged = try XCTUnwrap(service.stagedDelivery, "the tool stages; the app presents")
        XCTAssertEqual(staged.channel, .email)
        XCTAssertEqual(staged.recipients, ["office@example.com"])
        XCTAssertEqual(staged.attachments.count, 2)
        XCTAssertTrue(reply.contains("office@example.com"), reply)
        XCTAssertTrue(reply.contains("tap Send"), reply)
    }

    func testTheToolTakesTheChannelAndTheContactTheTechnicianNamed() async throws {
        let service = try liveSession()
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() },
                                     resolveContact: { name in
                                         name.lowercased() == "dave" ? ["+64211111111"] : []
                                     })

        _ = try await tool.execute(args: ["channel": "text", "to": "Dave"])
        XCTAssertEqual(service.stagedDelivery?.channel, .messages)
        XCTAssertEqual(service.stagedDelivery?.recipients, ["+64211111111"])

        let unknown = try await tool.execute(args: ["channel": "messages", "to": "Nobody"])
        XCTAssertTrue(unknown.contains("No contact matching 'Nobody'"), unknown)
    }

    func testTheToolRefusesAChannelTheOrganisationDoesNotAllow() async throws {
        let service = try liveSession()
        let tool = DeliverReportTool(sessionService: service,
                                     settings: { self.settings(channels: [.email, .shareSheet]) })
        let reply = try await tool.execute(args: ["channel": "whatsapp"])
        XCTAssertTrue(reply.contains("isn't one of the channels"), reply)
        XCTAssertTrue(reply.contains("Allowed channels are"), reply)
        XCTAssertNil(service.stagedDelivery, "a refused channel stages nothing")
    }

    func testTheToolWillNotGuessAnEmailAddressFromAName() async throws {
        let service = try liveSession()
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() })
        let reply = try await tool.execute(args: ["channel": "email", "to": "Dave"])
        XCTAssertTrue(reply.contains("isn't one"), reply)
        XCTAssertNil(service.stagedDelivery)
    }

    func testTheToolNeedsASessionAndSaysSo() async throws {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("empty"))
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() })
        let reply = try await tool.execute(args: [:])
        XCTAssertTrue(reply.contains("No active Field Assist session"), reply)
        XCTAssertNil(service.stagedDelivery)
    }

    func testAnUnknownChannelNameIsNamedRatherThanQuietlyDefaulted() async throws {
        let service = try liveSession()
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() })
        let reply = try await tool.execute(args: ["channel": "carrier pigeon"])
        XCTAssertTrue(reply.contains("carrier pigeon"), reply)
        XCTAssertNil(service.stagedDelivery)
    }

    // MARK: - What happens when the composer closes

    func testSendingMarksTheStockChecksSentAndWritesTheAuditLine() async throws {
        let service = try liveSession()
        let request = service.requestPart(part("14T65"), quantity: 2)
        XCTAssertEqual(request?.status, .requested)
        let staged = DeliveryRequest.make(record: try XCTUnwrap(service.workRecord()),
                                          channel: .email, recipients: ["office@example.com"],
                                          attachments: [])
        service.stageDelivery(staged)

        service.completeDelivery(staged, outcome: .sent)
        XCTAssertNil(service.stagedDelivery)
        XCTAssertEqual(service.activeSession?.partsRequests.first?.status, .sent)
        XCTAssertFalse(service.lastDeliveryCancelled)

        let events = try loggedEvents(service)
        let sent = try XCTUnwrap(events.last { $0.kind == .reportSent })
        XCTAssertEqual(sent.payload?["channel"]?.value as? String, "email")
        XCTAssertEqual(sent.payload?["recipients"]?.value as? Int, 1)
        XCTAssertEqual(sent.payload?["parts_requests"]?.value as? Int, 1)
        // The addresses themselves are not written down — the count is what an audit needs.
        let encoded = try JSONEncoder().encode(sent.payload ?? [:])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("office@example.com"))
    }

    func testADismissedComposerLeavesTheRecordExactlyWhereItWas() async throws {
        let service = try liveSession()
        let queue = OfflineQueue(path: tempRoot.appendingPathComponent("queue.sqlite"))
        queue.deleteAll()
        service.offlineQueue = queue
        _ = service.requestPart(part("14T65"), quantity: 2)

        let staged = DeliveryRequest.make(record: try XCTUnwrap(service.workRecord()),
                                          channel: .email, recipients: ["office@example.com"],
                                          attachments: [])
        service.stageDelivery(staged)
        service.completeDelivery(staged, outcome: .cancelled)

        XCTAssertNil(service.stagedDelivery)
        XCTAssertTrue(service.lastDeliveryCancelled)
        XCTAssertEqual(service.activeSession?.partsRequests.first?.status, .requested,
                       "a report nobody sent has not sent the parts request either")
        XCTAssertEqual(queue.pending().filter { $0.kind == .partsRequest }.count, 1,
                       "the queued operation is still pending — nothing is silently lost")

        let events = try loggedEvents(service)
        let cancelled = try XCTUnwrap(events.last { $0.kind == .reportCancelled })
        XCTAssertEqual(cancelled.payload?["outcome"]?.value as? String, "cancelled")
        XCTAssertNil(events.last { $0.kind == .reportSent })
    }

    func testAHandOffToAnAppThatCannotConfirmIsNotASend() async throws {
        let service = try liveSession()
        _ = service.requestPart(part("14T65"))
        let staged = DeliveryRequest.make(record: try XCTUnwrap(service.workRecord()),
                                          channel: .whatsapp, recipients: ["+64210000000"],
                                          attachments: [])
        service.completeDelivery(staged, outcome: .handedOff)
        XCTAssertEqual(service.activeSession?.partsRequests.first?.status, .requested)
        XCTAssertTrue(service.lastDeliveryCancelled)
        let events = try loggedEvents(service)
        XCTAssertEqual(events.last { $0.kind == .reportCancelled }?.payload?["outcome"]?.value as? String,
                       "handed_off")
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

    // MARK: - The unattended route

    func testTheEndpointSinkPostsTheRecordWithItsEnvelopeAndCredentials() async throws {
        DeliveryStubProtocol.reset()
        DeliveryStubProtocol.statusCode = 202
        let spy = SpySink()
        let sink = EndpointSyncSink(fallback: spy, session: DeliveryStubProtocol.session(),
                                    endpoint: { URL(string: "https://ops.example.com/job-reports") },
                                    token: { "tok-123" })

        let op = QueuedOp.make(workRecord: record())
        let outcome = await sink.deliver(op)
        XCTAssertEqual(outcome, .done)
        XCTAssertTrue(spy.delivered.isEmpty, "a handled kind never reaches the fallback")

        let request = try XCTUnwrap(DeliveryStubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), op.id)

        let body = try XCTUnwrap(DeliveryStubProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["op"] as? String, OpKind.workRecord.rawValue)
        XCTAssertEqual(json["op_id"] as? String, op.id)
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["job_reference"] as? String, "4471")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["job_reference"] as? String, "4471")
        XCTAssertEqual((payload["tasks"] as? [Any])?.count, 2)
    }

    func testAStockCheckLeavesOnItsOwn() async throws {
        DeliveryStubProtocol.reset()
        let sink = EndpointSyncSink(fallback: SpySink(), session: DeliveryStubProtocol.session(),
                                    endpoint: { URL(string: "https://ops.example.com/jobs") },
                                    token: { "" })
        let request = PartsRequest(id: "req-9", part: part("14T65"), quantity: 2)
        let outcome = await sink.deliver(QueuedOp.make(partsRequest: request, sessionId: "session-1"))
        XCTAssertEqual(outcome, .done)
        let captured = try XCTUnwrap(DeliveryStubProtocol.lastRequest)
        XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"),
                     "no token configured means no Authorization header, not an empty one")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try XCTUnwrap(DeliveryStubProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(json["op"] as? String, OpKind.partsRequest.rawValue)
        XCTAssertNil(json["job_reference"], "a stock check carries no job reference of its own")
    }

    func testTheSinkReadsTheStatusTheWayTheQueueMeans() {
        XCTAssertEqual(EndpointSyncSink.outcome(status: 200, data: Data()), .done)
        XCTAssertEqual(EndpointSyncSink.outcome(status: 204, data: Data()), .done)

        guard case .conflict(let conflict) = EndpointSyncSink.outcome(
            status: 409, data: Data(#"{"error":"job closed"}"#.utf8)) else {
            return XCTFail("409 is the one 4xx that means the office moved on")
        }
        XCTAssertEqual(conflict, "job closed")

        guard case .permanent(let auth) = EndpointSyncSink.outcome(status: 401, data: Data()) else {
            return XCTFail("bad credentials will not come right by retrying")
        }
        XCTAssertTrue(auth.contains("credentials"), auth)

        guard case .permanent = EndpointSyncSink.outcome(status: 422, data: Data()) else {
            return XCTFail("a malformed body is permanent")
        }
        guard case .transient = EndpointSyncSink.outcome(status: 503, data: Data()) else {
            return XCTFail("the office being down is temporary")
        }
    }

    func testBeingOfflineKeepsTheRecordRatherThanFailingIt() async {
        DeliveryStubProtocol.reset()
        DeliveryStubProtocol.error = URLError(.notConnectedToInternet)
        let sink = EndpointSyncSink(fallback: SpySink(), session: DeliveryStubProtocol.session(),
                                    endpoint: { URL(string: "https://ops.example.com/jobs") },
                                    token: { "" })
        guard case .transient = await sink.deliver(QueuedOp.make(workRecord: record())) else {
            return XCTFail("offline is a retry, never a loss")
        }
    }

    func testWithoutAnEndpointEverythingBehavesExactlyAsBefore() async {
        DeliveryStubProtocol.reset()
        let spy = SpySink()
        let sink = EndpointSyncSink(fallback: spy, session: DeliveryStubProtocol.session(),
                                    endpoint: { nil }, token: { "" })
        _ = await sink.deliver(QueuedOp.make(workRecord: record()))
        XCTAssertEqual(spy.delivered.count, 1)
        XCTAssertNil(DeliveryStubProtocol.lastRequest, "no endpoint means no request")
    }

    func testEveryOtherKindOfOperationIsStillTheOldSinksJob() async {
        DeliveryStubProtocol.reset()
        let spy = SpySink()
        let sink = EndpointSyncSink(fallback: spy, session: DeliveryStubProtocol.session(),
                                    endpoint: { URL(string: "https://ops.example.com/jobs") },
                                    token: { "" })
        for kind in [OpKind.logEntry, .photoUpload, .llmGrounding, .auditExport, .captureRecord] {
            _ = await sink.deliver(QueuedOp.make(kind: kind, sessionId: "s", json: ["a": 1]))
        }
        XCTAssertEqual(spy.delivered.count, 5)
        XCTAssertNil(DeliveryStubProtocol.lastRequest)
    }

    // MARK: - What the technician can see

    func testTheQueueScreenNamesRecordsByJobRatherThanByUUID() {
        let workRecord = QueuedOp.make(workRecord: record())
        let parts = QueuedOp.make(partsRequest: PartsRequest(id: "req-2", part: part("14T65"), quantity: 2),
                                  sessionId: "session-1")
        var delivered = QueuedOp.make(workRecord: record(jobReference: "9999"))
        delivered.state = .done

        let rows = QueuedRecordRows.rows(from: [workRecord, parts, delivered])
        XCTAssertEqual(rows.count, 2, "a delivered tombstone is not outstanding")
        XCTAssertEqual(rows[0].title, "Job 4471 — work record")
        XCTAssertTrue(rows[0].detail.contains("1 task done"), rows[0].detail)
        XCTAssertTrue(rows[0].canDeliver)
        XCTAssertEqual(rows[1].title, "Parts request — 2 × 14T65")
        XCTAssertFalse(rows[1].canDeliver, "a stock check is retried, not emailed as a work order")

        XCTAssertEqual(QueuedRecordRows.outstandingCount(in: [workRecord, parts, delivered],
                                                         sessionId: "session-1"), 2)
        XCTAssertEqual(QueuedRecordRows.outstandingCount(in: [delivered], sessionId: "session-1"), 0)
    }

    func testARecordNobodyCanDecodeIsStillShown() {
        let broken = QueuedOp(kind: .workRecord, sessionId: "session-1", payload: Data("not json".utf8))
        let row = try? XCTUnwrap(QueuedRecordRows.rows(from: [broken]).first)
        XCTAssertEqual(row?.title, "Work record")
        XCTAssertTrue(row?.detail.contains("could not be read") == true, row?.detail ?? "")
        XCTAssertFalse(row?.canDeliver ?? true)
    }

    func testTheSessionCardListsTasksInTheRecordsOwnOrder() throws {
        let service = try liveSession()
        let recommended = try service.proposeTask(title: "Check the pressure switch tubing",
                                                  why: "Lockout on rise",
                                                  citation: "Service Manual, page 3")
        _ = try service.decideTask(id: recommended.id, decision: .accept)
        _ = try service.completeTask(id: recommended.id, note: "Reseated the tubing")
        _ = try service.addOperatorTask(title: "Cleaned the condensate trap")
        let declined = try service.proposeTask(title: "Replace the ignitor",
                                               citation: "Service Manual, page 8")
        _ = try service.decideTask(id: declined.id, decision: .decline)

        let model = TaskSectionModel(host: service, unsentCount: 0)
        XCTAssertEqual(model.rows.map(\.title),
                       ["Check the pressure switch tubing", "Cleaned the condensate trap",
                        "Replace the ignitor"])
        XCTAssertEqual(model.rows.map(\.statusLabel), ["Done", "In progress", "Declined"])
        XCTAssertTrue(model.rows[1].isOperatorAdded)
        XCTAssertEqual(model.rows[0].completionNote, "Reseated the tubing")
        XCTAssertEqual(model.rows[0].why, "Lockout on rise")
        XCTAssertEqual(model.headline, "3 tasks · 1 still open")
        XCTAssertNil(model.unsentLine, "nothing outstanding, nothing said")

        // The read-back is the record, not a second rendering of it.
        XCTAssertEqual(model.readBackSpeech, service.workRecord()?.summary)
        XCTAssertEqual(model.readBack?.first, try XCTUnwrap(service.workRecord()).summaryLines.first)
    }

    func testTheCardSaysWhenSomethingIsUnsent() throws {
        let service = try liveSession()
        XCTAssertEqual(TaskSectionModel(host: service, unsentCount: 2).unsentLine,
                       "Unsent: 2 — waiting to reach the office.")

        let staged = DeliveryRequest.make(record: try XCTUnwrap(service.workRecord()), channel: .email,
                                          recipients: ["office@example.com"], attachments: [])
        service.completeDelivery(staged, outcome: .cancelled)
        let line = try XCTUnwrap(TaskSectionModel(host: service, unsentCount: 0).unsentLine)
        XCTAssertTrue(line.contains("wasn't confirmed sent"), line)
    }

    func testTheLensSaysWhatIsInHandAndNothingPersistent() throws {
        let service = try liveSession()
        let task = try service.addOperatorTask(title: "Cleaned the condensate trap")
        let started = try XCTUnwrap(service.taskCue)
        XCTAssertEqual(started.phase, .started)
        XCTAssertEqual(TaskHUDCue.line(for: started), "On: Cleaned the condensate trap")

        _ = try service.completeTask(id: task.id)
        let done = try XCTUnwrap(service.taskCue)
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(TaskHUDCue.line(for: done), "Done: Cleaned the condensate trap")
    }
}

// MARK: - Stubs

/// Records the outbound request and answers with a canned response, so the endpoint sink is
/// exercised with no network at all. Its own class rather than a shared one, because these tests
/// and the MCP transport's tests would otherwise fight over the same statics.
final class DeliveryStubProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var error: Error?

    static func reset() {
        lastRequest = nil
        lastBody = nil
        responseBody = Data("{}".utf8)
        statusCode = 200
        error = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeliveryStubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        DeliveryStubProtocol.lastRequest = request
        DeliveryStubProtocol.lastBody = Self.readBody(from: request)
        if let error = DeliveryStubProtocol.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: DeliveryStubProtocol.statusCode,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: DeliveryStubProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 1024)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The sink the endpoint one delegates to, so "it delegated" is provable rather than inferred.
@MainActor
final class SpySink: SyncSink {
    private(set) var delivered: [QueuedOp] = []

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        delivered.append(op)
        return .done
    }
}
