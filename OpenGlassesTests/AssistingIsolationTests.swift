import XCTest
@testable import OpenGlasses

/// Plan KM §7, P2 — Assisting mode is not a switch and unlocks nothing.
///
/// - It works with no Field Assist licence, entitlement or profile, and never asks
///   `FieldAssistEntitlement` (a source scrape, and a provider that counts every read).
/// - **Every row of the plan's "never opens" table is a test here.** Each scrapes the Assisting
///   sources — `Services/Assisting/` and `App/Views/Assisting/` — for every top-level type the
///   Field Assist surface that row names declares, so a new link into one fails by name.
/// - Nothing from a handover reaches the assistant's memory, threads, team learnings, retrieval or
///   a search across organisations: only the Assisting files, the app's wiring and the erasure and
///   retention walks may name the store, and none of those feeds a prompt.
///
/// Scrapes read code with comments and string literals removed, in the style of
/// `OutboundFrameConsumerTests`.
@MainActor
final class AssistingIsolationTests: XCTestCase {

    // MARK: - Sources

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var sourcesRoot: URL { repoRoot.appendingPathComponent("OpenGlasses/Sources") }

    private static let assistingFolders = ["Services/Assisting", "App/Views/Assisting"]

    private static func swiftFiles(under relative: String) -> [URL] {
        let root = sourcesRoot.appendingPathComponent(relative)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private static func relative(_ url: URL) -> String {
        String(url.path.dropFirst(sourcesRoot.path.count + 1))
    }

    /// The code, with comments and string literals removed: what the file can actually reach.
    private static func code(_ url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
        return text
    }

    private static var assistingFiles: [URL] { assistingFolders.flatMap(swiftFiles(under:)) }

    /// Top-level types a file or folder declares.
    private static func declaredTypes(in relatives: [String]) throws -> Set<String> {
        var names = Set<String>()
        let pattern = try NSRegularExpression(
            pattern: #"^(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:struct|enum|class|actor|protocol)\s+([A-Z][A-Za-z0-9_]*)"#,
            options: [.anchorsMatchLines])
        for relative in relatives {
            let url = sourcesRoot.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                XCTFail("\(relative) is gone; this row's test must follow the surface it guards")
                continue
            }
            let files = isDirectory.boolValue ? swiftFiles(under: relative) : [url]
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
                }
            }
        }
        return names
    }

    /// Fails for every Assisting file that names any of `symbols` as a whole word.
    private func assertAssistingNeverNames(_ symbols: Set<String>, row: String,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(symbols.isEmpty, "\(row): the scrape found nothing to guard", file: file, line: line)
        let files = Self.assistingFiles
        XCTAssertGreaterThanOrEqual(files.count, 7, "sanity: the Assisting sources were found", file: file, line: line)
        for url in files {
            let code = try Self.code(url)
            for symbol in symbols.sorted() where code.range(of: #"\b\#(symbol)\b"#, options: .regularExpression) != nil {
                XCTFail("\(Self.relative(url)) names \(symbol). Assisting never opens \(row).", file: file, line: line)
            }
        }
    }

    // MARK: - "It never opens": one test per row of §7's table

    /// Row 1: Field Assist mode, the job flow, or starting a job.
    func testNeverOpensFieldAssistModeTheJobFlowOrStartingAJob() throws {
        var symbols = try Self.declaredTypes(in: [
            "Services/FieldAssist/Mode", "Services/FieldAssist/Job", "Services/FieldAssist/FieldSessionService.swift",
            "Services/FieldAssist/FieldSession.swift", "Services/FieldAssist/EscalationCoordinator.swift",
            "Services/FieldAssist/TechnicianRequest.swift", "App/Views/Job", "App/Views/FieldAssistModeTab.swift",
            "App/Views/FieldAssistSettingsView.swift",
        ])
        symbols.formUnion(["AppState", "startSession", "openJobs", "fieldAssistEnabled", "ExpertHandoverService",
                           "ExpertReplyIntake", "ExpertListStore"])
        try assertAssistingNeverNames(symbols, row: "Field Assist mode, the job flow, or starting a job")
    }

    /// Row 2: vaults, bundled or custom; procedures; the procedure library.
    func testNeverOpensVaultsProceduresOrTheProcedureLibrary() throws {
        let symbols = try Self.declaredTypes(in: [
            "Services/Vault", "Services/FieldAssist/Procedure.swift", "Services/FieldAssist/ProcedureLibrary.swift",
            "Services/FieldAssist/ProcedureRunner.swift",
        ])
        try assertAssistingNeverNames(symbols, row: "vaults, procedures or the procedure library")
    }

    /// Row 3: manual or code-book pages. A handover names them; nothing in Assisting opens one.
    func testNeverOpensManualOrCodeBookPages() throws {
        var symbols = try Self.declaredTypes(in: [
            "Services/FieldAssist/CapturedManual", "Services/FieldAssist/ManualFigure.swift",
            "Services/FieldAssist/ManualPageSheet.swift", "Services/FieldAssist/ShowSource.swift",
            "Services/FieldAssist/StandardDocumentOpenPolicy.swift", "Services/FieldAssist/FigureAutoOpenPolicy.swift",
            "App/Views/ManualFigureSheet.swift", "App/Views/MyManualsView.swift", "App/Views/FieldAssistManualsView.swift",
            "App/Views/ManualPickerView.swift",
        ])
        symbols.formUnion(["DocumentStore", "PDFView", "PDFDocument"])
        try assertAssistingNeverNames(symbols, row: "manual or code-book pages")

        // The view lists a reference as words, and nothing else.
        let view = try Self.code(Self.sourcesRoot.appendingPathComponent("App/Views/Assisting/AssistingHandoverView.swift"))
        XCTAssertFalse(view.contains("openURL"), "a manual reference opens nothing from a handover")
    }

    /// Row 4: the domain calculators, refrigerant toolkit, parts, van stock or connectors.
    func testNeverOpensCalculatorsTheRefrigerantToolkitPartsVanStockOrConnectors() throws {
        var symbols = try Self.declaredTypes(in: [
            "Services/FieldAssist/Refrigerant", "Services/FieldAssist/Electrical", "Services/FieldAssist/VanStock",
            "Services/FieldAssist/Workiz", "Services/OfficeSync", "Services/FieldAssist/PartsOrder.swift",
            "Services/FieldAssist/PartsVerifier.swift", "Services/NativeTools/DomainCalcTool.swift",
            "Services/NativeTools/PartsRequestTool.swift",
        ])
        symbols.formUnion(["ServiceTitan"])
        try assertAssistingNeverNames(symbols, row: "calculators, the refrigerant toolkit, parts, van stock or connectors")
    }

    /// Row 5: work-record, debrief, PDF or audit export, beyond the expert's own reply.
    func testNeverOpensAWorkRecordDebriefPDFOrAuditExport() throws {
        var symbols = try Self.declaredTypes(in: [
            "Services/FieldAssist/WorkRecord.swift", "Services/FieldAssist/WorkRecordSurface.swift",
            "Services/FieldAssist/SessionExport.swift", "Services/FieldAssist/SessionExporter.swift",
            "Services/FieldAssist/DeliveryRequest.swift", "Services/FieldAssist/ReportIdentity.swift",
            "Services/FieldAssist/Experts/ExpertHandoverRendering.swift",
        ])
        symbols.formUnion(["PDFLayout", "JobTranscriptExport", "fieldSession", "safetyReport", "agentArchive",
                           "UIGraphicsPDFRenderer"])
        try assertAssistingNeverNames(symbols, row: "a work record, debrief, PDF or audit export")
        // The one export it has is its own reply, through its own staging family.
        let service = try Self.code(Self.sourcesRoot.appendingPathComponent("Services/Assisting/AssistingService.swift"))
        XCTAssertTrue(service.contains(".assistingReply"))
    }

    /// Row 5's exception (Plan KM P4): "beyond the expert's own ledger". The ledger is exported
    /// through `MinutesTableDocument` — a neutral table of text that knows nothing of a job — and
    /// through the reply's own staging family; one organisation per document, and never a rate.
    func testTheOnlyExportBeyondTheReplyIsTheExpertsOwnLedger() throws {
        let table = try Self.code(Self.sourcesRoot.appendingPathComponent("Services/Export/MinutesTableDocument.swift"))
        let report = try Self.declaredTypes(in: [
            "Services/FieldAssist/WorkRecord.swift", "Services/FieldAssist/SessionExport.swift",
            "Services/FieldAssist/FieldSession.swift", "Services/FieldAssist/Experts/ExpertHandover.swift",
            "Services/FieldAssist/Experts/ExpertStatement.swift",
        ])
        for symbol in report.union(["AssistingHandoverStore", "HeldHandover", "ExpertLedgerEntry"]).sorted()
        where table.range(of: #"\b\#(symbol)\b"#, options: .regularExpression) != nil {
            XCTFail("MinutesTableDocument names \(symbol); it must stay a neutral table of text")
        }
        let ledgerCode = try Self.code(Self.sourcesRoot.appendingPathComponent("Services/Assisting/ExpertLedger.swift"))
        for money in ["Rate", "perHour", "currency", "amount", "ExpertStatement"] {
            XCTAssertNil(ledgerCode.range(of: #"\b\#(money)\b"#, options: .regularExpression), "the ledger names \(money)")
        }
        let view = try Self.code(Self.sourcesRoot.appendingPathComponent("App/Views/Assisting/ExpertLedgerView.swift"))
        XCTAssertFalse(view.contains(".searchable("))

        // One organisation per document, whatever the ledger holds.
        let entries = [("A", "Kestrel Heating"), ("B", "Rival Air"), ("C", "Kestrel Heating")].map { id, organisation in
            ExpertLedgerEntry(reply: AssistingFixture.timeReply(handoverId: id, organisation: organisation, minutes: 20),
                              sentAt: AssistingFixture.start)
        }
        let ledger = ExpertLedger(entries: entries)
        let calendar = AssistingFixture.calendar
        let month = CalendarMonth(AssistingFixture.start, calendar: calendar)
        for organisation in ledger.organisations {
            let document = ledger.document(organisation: organisation.id, month: month, calendar: calendar,
                                           preparedAt: AssistingFixture.start)
            let other = ledger.organisations.filter { $0.id != organisation.id }.map { $0.name }
            for name in other { XCTAssertFalse(document.csv.contains(name), "\(organisation.name)'s ledger names \(name)") }
        }
        XCTAssertEqual(ledger.rows(organisation: HeldHandover.organisationKey("Kestrel Heating"), month: month,
                                   calendar: calendar).count, 2)
    }

    /// Row 6: any Field Assist tool in the expert's assistant. Handovers are not fed to it.
    func testNeverGivesTheAssistantAFieldAssistToolOrAHandover() throws {
        var symbols = try Self.declaredTypes(in: ["Services/NativeTools"])
        symbols.formUnion(["LLMService", "SystemPromptBuilder", "NativeToolRegistry", "NativeToolRouter"])
        // The shared kit the Assisting views use is not a tool.
        symbols.subtract(["ShareItem"])
        try assertAssistingNeverNames(symbols, row: "a Field Assist tool in the assistant")
        try testOnlyTheAssistingFilesTheWiringAndTheWalksNameTheStore()
    }

    // MARK: - Nothing from a handover reaches memory, threads, learnings or search

    func testNothingFromAHandoverReachesMemoryThreadsLearningsOrRetrieval() throws {
        try assertAssistingNeverNames([
            "BrainStore", "SemanticMemoryStore", "ConversationStore", "ConversationIndex", "AgentDocumentStore",
            "LearningCandidateStore", "LearningEntryStore", "LearningCorpus", "LearningReview", "DocumentStore",
            "SpotlightIndexService", "ActivityStore", "GoalStore", "ObjectMemoryStore", "ContextualNoteStore",
            "VaultRetriever",
        ], row: "the assistant's memory, threads, team learnings or retrieval")
    }

    /// The reverse direction: who may name the store at all. A prompt builder, a tool, the memory or
    /// a search that wanted a handover would have to name it, and is not on this list.
    func testOnlyTheAssistingFilesTheWiringAndTheWalksNameTheStore() throws {
        let allowed: Set<String> = [
            "App/OpenGlassesApp.swift",
            "Services/Privacy/DataStoreRegistry.swift",
            "Services/Privacy/RetentionScheduler.swift",
            "Services/Privacy/SubjectErasureCoordinator.swift",
        ]
        let held = ["AssistingHandoverStore", "HeldHandover", "AssistingService",
                    // Plan KM P4: the expert's own ledger is held apart the same way.
                    "ExpertLedgerStore", "ExpertLedger", "ExpertLedgerEntry",
                    // Plan KW: the invites asking for the card, held beside the handovers. The hub,
                    // Home and Things to Try read `AssistingPresenceFeed` instead, which says only
                    // whether to draw a row or a card.
                    "OpenInvite"]
        for url in Self.swiftFiles(under: "") {
            let relative = Self.relative(url)
            if Self.assistingFolders.contains(where: { relative.hasPrefix($0 + "/") }) || allowed.contains(relative) { continue }
            let code = try Self.code(url)
            for name in held where code.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil {
                XCTFail("\(relative) names \(name). A handover is held apart: only Assisting, the app's wiring "
                        + "and the erasure and retention walks reach it.")
            }
        }
    }

    func testThereIsNoSearchAcrossOrganisations() throws {
        for url in Self.assistingFiles {
            let code = try Self.code(url)
            XCTAssertFalse(code.contains(".searchable("), "\(Self.relative(url)) adds a search across handovers")
            XCTAssertFalse(code.range(of: #"func\s+search"#, options: .regularExpression) != nil,
                           "\(Self.relative(url)) adds a search across handovers")
        }
        // One organisation's handovers are never shown in another's group.
        let directory = AssistingFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistingHandoverStore(directory: directory)
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "A", organisation: "Kestrel Heating")))
        store.open(AssistingFixture.opened(AssistingFixture.handover(id: "B", organisation: "Rival Air")))
        for group in store.groups {
            XCTAssertEqual(Set(group.handovers.map(\.organisationKey)).count, 1)
        }
    }

    // MARK: - Unlocks nothing, needs nothing

    func testAssistingNeverConsultsTheFieldAssistEntitlementOrAProfile() throws {
        try assertAssistingNeverNames([
            "FieldAssistEntitlement", "FieldAssistCapability", "FieldAssistEntitlementProvider", "LicenseService",
            "StoreKitService", "OrgProfileManager", "PolicyEnvelope", "AdminGate", "ManagedLockdown",
        ], row: "the Field Assist entitlement, a licence or a profile")
    }

    /// The same flow with nothing installed and with everything installed gives the same result, and
    /// the entitlement is never read along the way.
    func testAssistingWorksTheSameWithAndWithoutFieldAssist() throws {
        let previous = FieldAssistEntitlement.shared.provider
        defer { EntitlementTestScope.restore(previous) }

        func run(_ provider: FieldAssistEntitlementProvider) throws -> ExpertTimeReply {
            FieldAssistEntitlement.shared.provider = provider
            let directory = AssistingFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let clock = AssistingTestClock()
            let replies = StagedExportCoordinator(channel: .assistingReply, rootDirectoryName: "unused",
                                                  store: ProtectedExportFileStore(rootDirectoryName: "unused",
                                                                                  root: directory.appendingPathComponent("r")))
            let service = AssistingService(store: AssistingHandoverStore(directory: directory, now: { clock.now }),
                                           cards: ExpertCardStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                           replies: replies, now: { clock.now })
            XCTAssertTrue(service.open(AssistingFixture.opened(AssistingFixture.handover())).shown)
            service.take("H-1")
            clock.advance(600)
            service.pause("H-1")
            service.resume("H-1")
            clock.advance(60)
            service.done("H-1")
            let staged = try service.stageReply(for: "H-1", note: "ok").get()
            service.finishShare(staged, for: "H-1", completed: true)
            return staged.reply
        }

        let none = CountingEntitlementProvider(.empty)
        let without = try run(none)
        let all = CountingEntitlementProvider(AlwaysGrantedEntitlementProvider(tier: .enterprise).evidence())
        let with = try run(all)
        XCTAssertEqual(without, with, "a Field Assist licence changes nothing in Assisting")
        XCTAssertEqual(without.minutes, 11)
        XCTAssertEqual(none.reads + all.reads, 0, "Assisting never asked whether Field Assist is unlocked")
    }

    // MARK: - The view cannot reach the technician's job

    /// Nothing in the view acts on the technician's job: no Field Assist service (row 1 above), no
    /// way to reach their phone, and the only thing that leaves is the reply the expert shares.
    func testNothingInTheViewCanReachTheTechniciansJob() throws {
        try assertAssistingNeverNames([
            "URLSession", "NetworkRoute", "BoundedHTTPClient", "MFMessageComposeViewController",
            "MFMailComposeViewController", "OfflineQueue", "SyncEngine", "WebRTCPeerTransport", "ExpertBridge",
            "CallPlacement", "CallRoute",
        ], row: "a way to reach the technician's job or phone")
        // The handover's value has no field that names the technician's phone or their job's store.
        let labels = Set(Mirror(reflecting: AssistingFixture.handover()).children.compactMap(\.label))
        XCTAssertTrue(labels.isDisjoint(with: ["sessionId", "callBack", "phone", "endpoint", "vaultId"]))
        // A held handover is a copy: changing it changes nothing it came from.
        let held = HeldHandover(handover: AssistingFixture.handover(), receivedAt: AssistingFixture.start)
        XCTAssertEqual(Set(Mirror(reflecting: held).children.compactMap(\.label)),
                       ["handover", "generationsSeen", "firstReceivedAt", "lastReceivedAt", "changes", "clock", "replySentAt",
                        // Plan KM P3: the expert's own drafts, which go back only by their own share.
                        "coachingDraft", "noteDraft", "coachingSentAt",
                        // Plan KM P4: the coaching replies sent, by id, and the calls seen while the
                        // clock ran — times only.
                        "coachingRepliesSent", "observedCalls",
                        // Plan KW: swiped off the Home screen — a flag, nothing that leaves.
                        "homeDismissed"])
    }

    /// Medical Compliance (§8 never offers the *sending*): Assisting reads no mode at all — it is a
    /// read-only view whose only egress is the expert's own share.
    func testAssistingReadsNoMedicalModeAndSendsNothingByItself() throws {
        try assertAssistingNeverNames(["MedicalEgressGuard", "hipaaMode", "NoticeCenter"],
                                      row: "a mode or a send of its own")
    }
}

/// Counts every read of the entitlement's evidence.
private final class CountingEntitlementProvider: FieldAssistEntitlementProvider, @unchecked Sendable {
    private let set: FieldAssistEntitlementEvidenceSet
    private let lock = NSLock()
    private var count = 0

    init(_ set: FieldAssistEntitlementEvidenceSet) { self.set = set }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }

    func evidence() -> FieldAssistEntitlementEvidenceSet {
        lock.lock(); count += 1; lock.unlock()
        return set
    }
}
