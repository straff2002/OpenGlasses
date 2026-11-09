import XCTest
import PDFKit
import UIKit
@testable import OpenGlasses

/// Plan KM P1 — the handover: the job as it stands, to a named expert, minimal by construction.
///
/// Every name, number, company and address here is invented.
@MainActor
final class ExpertHandoverTests: XCTestCase {

    // MARK: - Fixtures

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session() -> FieldSession {
        var session = FieldSession(id: "job-s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: start, outcome: .inProgress, escalations: [], billableSeconds: 0)
        session.jobReference = "4471"
        session.site = JobSite(customer: "Harbour Bakery Ltd", address: "14 Kauri Street, Riverton 9822",
                               contact: "021 555 0199")
        session.faultReport = FaultReport(text: "No heat, pressure switch fault on the display", source: .jobFile,
                                          receivedAt: start)
        session.equipment = EquipmentIdentity(modelToken: "KX-90", heading: "KX-90 series", file: "models.md",
                                              source: .spoken, recognisedAt: start, statedModel: "KX-90B")
        session.identityFields = [DeviceIdentityField(name: "Serial", value: "KX90B-55501", source: .nameplate,
                                                      recordedAt: start)]
        session.tasks = [
            FieldSession.Task(title: "Check the inducer hose", origin: .operatorAdded, status: .done,
                              completionNote: "Hose clear, no water", createdAt: start),
            FieldSession.Task(title: "Replace the pressure switch", origin: .recommended, status: .recommended,
                              citation: "Furnace Service Manual, page 12", createdAt: start),
        ]
        session.spokenReadings = [
            SpokenReading(id: "r1", quantity: "manifold pressure", value: "3.1", unit: "inWC", at: start),
            SpokenReading(id: "r2", quantity: "manifold pressure", value: "3.4", unit: "inWC",
                          at: start.addingTimeInterval(60), supersedes: "r1"),
            SpokenReading(id: "r3", quantity: "switch pressure", value: "0.62", unit: "inWC",
                          at: start.addingTimeInterval(120)),
        ]
        return session
    }

    private let rate = EscalationContact.Rate(perHour: Decimal(string: "87.65")!, minimumMinutes: 30,
                                              roundingMinutes: 15, currency: "XTS")

    private func staff(_ source: ExpertListEntry.Source = .organization) -> ExpertListEntry {
        ExpertListEntry(contact: EscalationContact(id: "sam", name: "Sam Ferreira", phone: "+64 21 000 1111",
                                                   handoverChannel: .messages, specialties: ["furnace"],
                                                   kind: .staff),
                        source: source)
    }

    private func contracted() -> ExpertListEntry {
        ExpertListEntry(contact: EscalationContact(id: "priya", name: "Priya Lindqvist", phone: "+64 21 000 2222",
                                                   faceTimeHandle: "priya@example.com", handoverChannel: .email,
                                                   specialties: ["furnace"], kind: .contracted, rate: rate),
                        source: .organization)
    }

    private func personal() -> ExpertListEntry {
        ExpertListEntry(contact: PersonalExpert(id: "dana", name: "Dana Whitcombe", phone: "+64 21 000 3333").contact,
                        source: .personal)
    }

    private let lines = [
        JobTranscriptExport.Line(timestamp: Date(timeIntervalSince1970: 1_800_000_030), speaker: .technician,
                                 text: "It's tripping the pressure switch and I can't see why", imageAttached: false),
        JobTranscriptExport.Line(timestamp: Date(timeIntervalSince1970: 1_800_000_040), speaker: .assistant,
                                 text: "Check the hose for water first. Source: Furnace Service Manual, page 12",
                                 imageAttached: false),
    ]

    private func input(expert: ExpertListEntry, organisation: ExpertHandoverBuilder.Organisation = .init(name: "Kestrel Heating"),
                       choice: ExpertHandoverBuilder.Choice = .init(question: "Why does the switch stay open?"),
                       photos: Int = 2, generation: Int = 1) -> ExpertHandoverBuilder.Input {
        ExpertHandoverBuilder.Input(
            session: session(), vaultTrades: ["refrigeration_hvac"], expert: expert,
            organisation: organisation, choice: choice, conversation: lines,
            citations: ["Furnace Service Manual, page 12, §Pressure switch", "Furnace Service Manual, page 12, §Pressure switch",
                        "Wiring Guide, page 4, Figure 3"],
            procedures: [SessionExport.ProcedureRun(procedureId: "inducer-check", stepsCompleted: 3, outcome: nil)],
            photos: (0..<photos).map { .init(itemId: "p\($0)", capturedAt: start.addingTimeInterval(Double($0) * 10),
                                             caption: "Photo \($0)") },
            handoverId: "H-1", generation: generation, now: start.addingTimeInterval(600))
    }

    private func build(_ input: ExpertHandoverBuilder.Input, mode: MedicalEgressGuard.Mode = .off) throws -> ExpertHandover {
        try ExpertHandoverBuilder.build(input, mode: mode).get()
    }

    private func json(_ handover: ExpertHandover) throws -> String {
        String(decoding: try ExpertHandoverFile.encoder().encode(handover), as: UTF8.self)
    }

    private func jpeg(_ colour: UIColor = .gray, size: CGSize = CGSize(width: 8, height: 8)) -> Data {
        UIGraphicsImageRenderer(size: size).image { context in
            colour.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8)!
    }

    private func photoData(_ handover: ExpertHandover) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: handover.photos.map { ($0.file, jpeg()) })
    }

    private func pdfText(_ handover: ExpertHandover) throws -> (text: String, creator: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try ExpertHandoverRendering.writePDF(handover, photos: photoData(handover), to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let creator = document.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String ?? ""
        return (document.string ?? "", creator)
    }

    // MARK: - No customer identity by default (decision 2)

    func testTheSiteIsTheTownOnlyAndTheCustomerNeverGoes() throws {
        for expert in [staff(), contracted(), personal()] {
            let handover = try build(input(expert: expert))
            let rendered = [try json(handover), ExpertHandoverRendering.text(handover), try pdfText(handover).text]
            for text in rendered {
                XCTAssertFalse(text.contains("Harbour Bakery"), "the customer's name went to \(expert.contact.name)")
                XCTAssertFalse(text.contains("Kauri Street"), "the address went to \(expert.contact.name)")
                XCTAssertFalse(text.contains("555 0199"), "the contact went to \(expert.contact.name)")
            }
            XCTAssertEqual(handover.job.site?.town, "Riverton")
            XCTAssertNil(handover.job.site?.address)
        }
    }

    func testTheAddressGoesOnlyToTheOrganisationsOwnStaffWithItsKeyOn() throws {
        let on = ExpertHandoverBuilder.Organisation(name: "Kestrel Heating", includesAddressForStaff: true)
        let toStaff = try build(input(expert: staff(), organisation: on))
        XCTAssertEqual(toStaff.job.site?.address, "14 Kauri Street, Riverton 9822")
        XCTAssertFalse(try json(toStaff).contains("Harbour Bakery"), "the name never goes, even with the address")
        XCTAssertFalse(try json(toStaff).contains("555 0199"))

        XCTAssertNil(try build(input(expert: contracted(), organisation: on)).job.site?.address,
                     "a contracted expert never gets the address")
        XCTAssertNil(try build(input(expert: personal(), organisation: on)).job.site?.address,
                     "a personal addition is not the organisation's staff")
        XCTAssertNil(try build(input(expert: staff())).job.site?.address, "off unless the profile says so")
    }

    func testTheTownIsReadConservatively() {
        XCTAssertEqual(SiteTown.town(fromAddress: "14 Kauri Street, Riverton 9822"), "Riverton")
        XCTAssertEqual(SiteTown.town(fromAddress: "12 Elm St, Springfield, IL 62704"), "Springfield")
        XCTAssertEqual(SiteTown.town(fromAddress: "Unit 3, 14 Kauri St, Riverton"), "Riverton")
        XCTAssertNil(SiteTown.town(fromAddress: "14 Kauri Street"), "never the street part")
        XCTAssertNil(SiteTown.town(fromAddress: "14 Kauri Street, 9822"))
        XCTAssertNil(SiteTown.town(fromAddress: nil))
    }

    // MARK: - No page image under any setting (§3)

    func testNoPageImageUnderAnySetting() throws {
        let rules: [ReportTranscriptPolicy.ExpertRule?] = [nil, .include, .ask, .never]
        for expert in [staff(), contracted(), personal()] {
            for rule in rules {
                for address in [false, true] {
                    for transcript in [nil, true, false] as [Bool?] {
                        let organisation = ExpertHandoverBuilder.Organisation(name: "Kestrel Heating", transcriptRule: rule,
                                                                              includesAddressForStaff: address)
                        let handover = try build(input(expert: expert, organisation: organisation,
                                                       choice: .init(transcript: transcript), photos: 3))
                        // The only pictures are the three job photos handed in.
                        let file = try ExpertHandoverFile.write(handover, photos: photoData(handover))
                        let archive = try XCTUnwrap(ZipArchiveReader(data: file))
                        XCTAssertEqual(Set(archive.entryNames),
                                       ["handover.json", "photos/01.jpg", "photos/02.jpg", "photos/03.jpg"])
                        // Manuals by reference: title, page, section, and nothing else.
                        XCTAssertEqual(handover.manualReferences, [
                            .init(title: "Furnace Service Manual", page: 12, section: "Pressure switch"),
                            .init(title: "Wiring Guide", page: 4, section: "Figure 3"),
                        ])
                        let object = try JSONSerialization.jsonObject(with: ExpertHandoverFile.encoder().encode(handover))
                        let references = try XCTUnwrap((object as? [String: Any])?["manualReferences"] as? [[String: Any]])
                        for reference in references {
                            XCTAssertTrue(Set(reference.keys).isSubset(of: ["title", "page", "section"]))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Every image passed the filter

    private final class FakeBlur: StillImageFiltering {
        var scopes: [PrivacyFilterScope] = []
        /// Calls (0-based) the blur cannot process.
        var refuse: Set<Int> = []
        static let output = CGSize(width: 64, height: 48)

        func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage? {
            defer { scopes.append(scope) }
            if refuse.contains(scopes.count) { return nil }
            // A picture only this fake makes: what comes out is provably the filter's.
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: Self.output, format: format).image { context in
                UIColor.green.setFill(); context.fill(CGRect(origin: .zero, size: Self.output))
            }
        }
    }

    private func media(_ count: Int, clips: Int = 0) -> [JobMediaItem] {
        (0..<count).map { JobMediaItem(id: "p\($0)", capturedAt: start.addingTimeInterval(Double($0) * 10),
                                       origin: .photoLog, caption: "Photo \($0)", filterWasOn: false) }
            + (0..<clips).map { JobMediaItem(id: "c\($0)", kind: .clip, capturedAt: start.addingTimeInterval(1_000),
                                             origin: .clipRecord, filterWasOn: true, byteCount: 1_000) }
    }

    private let raw = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
        UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testEveryImagePassesTheMandatoryBlurAndAnUnfilterableOneIsDroppedAndCounted() throws {
        let blur = FakeBlur()
        blur.refuse = [1]
        let budget = AttachmentBudget(channel: .shareSheet, perFileBytes: nil, totalBytes: nil, carriesFiles: true)
        let prepared = ExpertHandoverPhotos.prepare(chosen: media(4, clips: 1), load: { _ in self.raw },
                                                    filter: blur, budget: budget)
        XCTAssertEqual(blur.scopes, Array(repeating: .expertHandover, count: 4), "clips are never read")
        XCTAssertTrue(PrivacyFilterScope.expertHandover.isMandatory, "the app-wide switch is no passthrough")
        XCTAssertEqual(prepared.photos.map(\.itemId), ["p0", "p2", "p3"])
        XCTAssertEqual(prepared.leftOut, .init(couldNotBeBlurred: 1, overSizeLimit: 0))
        XCTAssertNil(prepared.jpegs["p1"], "an unfilterable photo is never sent raw")
        for (_, data) in prepared.jpegs {
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.pixelSize, FakeBlur.output, "every JPEG is the filter's output, never the source")
        }
    }

    func testAMissingFileIsCountedAndNothingIsSentInItsPlace() {
        let prepared = ExpertHandoverPhotos.prepare(chosen: media(2), load: { $0.id == "p0" ? nil : self.raw },
                                                    filter: FakeBlur(),
                                                    budget: .init(channel: .shareSheet, perFileBytes: nil, totalBytes: nil, carriesFiles: true))
        XCTAssertEqual(prepared.photos.map(\.itemId), ["p1"])
        XCTAssertEqual(prepared.leftOut.couldNotBeBlurred, 1)
    }

    func testTheExpertHandoverIsOnTheRosterAtTheChokepoint() {
        let row = OutboundFrameConsumer.expertHandoverPhotos
        XCTAssertEqual(row.owningType, "ExpertHandoverPhotos")
        XCTAssertEqual(row.scope, .expertHandover)
        XCTAssertEqual(row.tap, .heldImage)
        XCTAssertEqual(row.mechanism, .chokepoint)
        XCTAssertFalse(OutboundFrameConsumer.typesAllowedOnARawStill.contains("ExpertHandoverPhotos"))
    }

    // MARK: - The budget drops the oldest photos and says so

    func testTheBudgetDropsTheOldestFirst() {
        let budget = AttachmentBudget(channel: .messages, perFileBytes: 1_000, totalBytes: 1_000, carriesFiles: true)
        let photos = (0..<5).map { AttachmentBudget.SizedPhoto(id: "p\($0)", capturedAt: start.addingTimeInterval(Double($0)), bytes: 300) }
        let fit = budget.photosFittingNewestFirst(photos.shuffled(), reservedBytes: 100)
        XCTAssertEqual(Set(fit.kept), ["p2", "p3", "p4"])
        XCTAssertEqual(fit.dropped, ["p0", "p1"])
        XCTAssertEqual(ExpertHandoverSendCopy.droppedSentence(.init(couldNotBeBlurred: 0, overSizeLimit: 2)),
                       "The 2 oldest photos didn't fit and stay on this phone.")
        XCTAssertEqual(ExpertHandoverSendCopy.droppedSentence(.init(couldNotBeBlurred: 0, overSizeLimit: 1)),
                       "The oldest photo didn't fit and stays on this phone.")
        XCTAssertNil(ExpertHandoverSendCopy.droppedSentence(.none))

        let unlimited = AttachmentBudget(channel: .shareSheet, perFileBytes: nil, totalBytes: nil, carriesFiles: true)
        XCTAssertTrue(unlimited.photosFittingNewestFirst(photos, reservedBytes: 100).dropped.isEmpty)
    }

    func testPreparedPhotosOverTheBudgetAreCountedAndTheExpertIsTold() throws {
        let tiny = AttachmentBudget(channel: .messages, perFileBytes: ExpertHandoverPhotos.reservedBytes,
                                    totalBytes: ExpertHandoverPhotos.reservedBytes, carriesFiles: true)
        let prepared = ExpertHandoverPhotos.prepare(chosen: media(3), load: { _ in self.raw }, filter: FakeBlur(), budget: tiny)
        XCTAssertTrue(prepared.photos.isEmpty)
        XCTAssertEqual(prepared.leftOut, .init(couldNotBeBlurred: 0, overSizeLimit: 3))
        var withLeftOut = input(expert: staff(), photos: 0)
        withLeftOut.photosLeftOut = prepared.leftOut
        let handover = try build(withLeftOut)
        XCTAssertTrue(ExpertHandoverRendering.text(handover).contains("3 older ones didn't fit"))
    }

    func testTheMostRecentFourArePreselected() {
        XCTAssertEqual(ExpertHandoverPhotos.preselection(media(6, clips: 2)), ["p5", "p4", "p3", "p2"])
        XCTAssertEqual(ExpertHandoverPhotos.preselection(media(2)), ["p1", "p0"])
    }

    // MARK: - The conversation (decision 3)

    func testTheTranscriptIsDeniedByDefaultForPersonalAdditions() throws {
        let decision = ReportTranscriptPolicy.forExpert(onOrganisationList: false, rule: nil)
        XCTAssertFalse(decision.includesTranscript)
        XCTAssertEqual(decision.audience, .expert)
        XCTAssertTrue(decision.toggle.isEditable)
        let handover = try build(input(expert: personal()))
        XCTAssertFalse(handover.conversation.included)
        XCTAssertTrue(handover.conversation.lines.isEmpty)
        XCTAssertFalse(ExpertHandoverRendering.text(handover).contains("pressure switch and I can't see why"))

        let turnedOn = try build(input(expert: personal(), choice: .init(transcript: true)))
        XCTAssertTrue(turnedOn.conversation.included, "the technician may turn it on for that send")
        XCTAssertEqual(turnedOn.conversation.lines.map(\.speaker), ["Technician", "Assistant"])
    }

    func testIncludeAskAndNeverBehave() {
        typealias P = ReportTranscriptPolicy
        // No rule: on for the organisation's list, editable.
        XCTAssertEqual(P.forExpert(onOrganisationList: true, rule: nil).toggle, .available(on: true))
        XCTAssertEqual(P.forExpert(onOrganisationList: true, rule: nil, technicianChoice: false).toggle, .available(on: false))
        // include: locked on for the list; a personal addition still only on the technician's say.
        XCTAssertEqual(P.forExpert(onOrganisationList: true, rule: .include, technicianChoice: false).toggle,
                       .lockedOn(reason: P.expertIncludeReason))
        XCTAssertEqual(P.forExpert(onOrganisationList: false, rule: .include).toggle, .available(on: false))
        XCTAssertEqual(P.forExpert(onOrganisationList: false, rule: .include, technicianChoice: true).toggle, .available(on: true))
        // ask: off until turned on, for everybody.
        XCTAssertEqual(P.forExpert(onOrganisationList: true, rule: .ask).toggle, .available(on: false))
        XCTAssertEqual(P.forExpert(onOrganisationList: true, rule: .ask, technicianChoice: true).toggle, .available(on: true))
        XCTAssertEqual(P.forExpert(onOrganisationList: false, rule: .ask).toggle, .available(on: false))
        // never: locked off, whatever the technician does.
        for onList in [true, false] {
            for choice in [nil, true, false] as [Bool?] {
                let decision = P.forExpert(onOrganisationList: onList, rule: .never, technicianChoice: choice)
                XCTAssertEqual(decision.toggle, .lockedOff(reason: P.expertNeverReason))
                XCTAssertFalse(decision.includesTranscript)
            }
        }
    }

    func testTheOrganisationsExpertsGetTheConversationByDefault() throws {
        XCTAssertTrue(try build(input(expert: staff())).conversation.included)
        XCTAssertFalse(try build(input(expert: staff(), organisation: .init(name: "Kestrel Heating", transcriptRule: .never),
                                       choice: .init(transcript: true))).conversation.included)
    }

    func testTheKeysAreProfileOwnedAndDenyByDefault() {
        XCTAssertEqual(SettingKey.expertHandoverTranscript.kind, .profileOwned(.string))
        XCTAssertEqual(SettingKey.expertHandoverIncludesAddress.kind, .profileOwned(.bool))
        XCTAssertEqual(SettingKey.expertHandoverRetentionDays.kind, .profileOwned(.string))
        for raw in ["include", "ask", "never"] {
            XCTAssertNil(SettingKey.expertHandoverTranscript.contentProblem(.string(raw), resolvableVaultIds: []))
        }
        XCTAssertNotNil(SettingKey.expertHandoverTranscript.contentProblem(.string("always"), resolvableVaultIds: []))
        XCTAssertNil(SettingKey.expertHandoverRetentionDays.contentProblem(.string("14"), resolvableVaultIds: []))
        for bad in ["0", "31", "two weeks", "", "-3"] {
            XCTAssertNotNil(SettingKey.expertHandoverRetentionDays.contentProblem(.string(bad), resolvableVaultIds: []), bad)
        }
        XCTAssertEqual(ExpertHandoverRetention.defaultDays, 30)
    }

    // MARK: - No troubleshooting, no rate

    /// Every key, at every depth, of a value.
    private func allKeys(_ object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] {
            return Set(dictionary.keys).union(dictionary.values.flatMap { allKeys($0) })
        }
        if let array = object as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) } }
        return []
    }

    func testTroubleshootingDetailsAreAbsent() throws {
        let handover = try build(input(expert: staff()))
        let object = try JSONSerialization.jsonObject(with: ExpertHandoverFile.encoder().encode(handover))
        XCTAssertEqual(Set((object as? [String: Any])?.keys.map { $0 } ?? []), [
            "type", "version", "kind", "handoverId", "generation", "createdAt", "organisation", "retentionDays",
            "expert", "job", "work", "conversation", "photos", "photosLeftOut", "manualReferences", "question",
        ])
        let keys = allKeys(object)
        // `model` is there once, as the unit's model; nothing names the assistant's.
        let unit = (((object as? [String: Any])?["job"] as? [String: Any])?["unit"] as? [String: Any]) ?? [:]
        XCTAssertEqual(unit["model"] as? String, "KX-90B")
        for forbidden in ["provenance", "usage", "tokens", "prompt", "promptParts", "traces", "turns", "latency",
                          "aiModel", "modelName", "rate", "perHour"] {
            XCTAssertFalse(keys.contains(forbidden), "\(forbidden) is a troubleshooting detail or a rate")
        }
        let text = ExpertHandoverRendering.text(handover)
        XCTAssertFalse(text.contains("Troubleshooting details"))
        XCTAssertFalse(text.contains("prompt"))
        let pdf = try pdfText(handover)
        XCTAssertEqual(pdf.creator, "Avenkin — contains AI-generated content", "the PDF names no model")
    }

    func testNoRateInAnyRendering() throws {
        let handover = try build(input(expert: contracted()))
        for text in [try json(handover), ExpertHandoverRendering.text(handover), try pdfText(handover).text,
                     ExpertHandoverSendCopy.subject(handover), ExpertHandoverSendCopy.shortBody(handover)] {
            XCTAssertFalse(text.contains("87.65"), "the rate's figure")
            XCTAssertFalse(text.contains("XTS"), "the rate's currency")
            XCTAssertFalse(text.lowercased().contains("per hour"))
        }
        XCTAssertFalse(try json(handover).contains("contracted"), "nor the expert's kind")
    }

    // MARK: - The job and the work, as the record says

    func testTheJobAndTheWorkComeFromTheRecord() throws {
        let handover = try build(input(expert: staff(), choice: .init(question: "  Why does the switch stay open?  ",
                                                                       ruledOut: ["The hose", "", " The inducer motor "])))
        XCTAssertEqual(handover.job.reference, "4471")
        XCTAssertEqual(handover.job.trades, ["Refrigeration & HVAC"])
        XCTAssertEqual(handover.job.faultReport?.text, "No heat, pressure switch fault on the display")
        XCTAssertEqual(handover.job.unit?.model, "KX-90B")
        XCTAssertEqual(handover.job.unit?.identity, [.init(name: "Serial", value: "KX90B-55501", source: "from the nameplate")])
        XCTAssertEqual(handover.work.tasks.map(\.status), ["done", "recommended"])
        XCTAssertEqual(handover.work.readings.map(\.value), ["3.4", "0.62"], "a corrected reading goes once, as corrected")
        XCTAssertEqual(handover.work.readings.first?.unit, "inWC")
        XCTAssertEqual(handover.work.readings.first?.source, "said by the technician")
        XCTAssertEqual(handover.work.procedures, [.init(procedure: "inducer-check", stepsDone: 3, outcome: nil)])
        XCTAssertEqual(handover.work.ruledOut, ["The hose", "The inducer motor"], "only the technician's words")
        XCTAssertTrue(handover.work.deviations.isEmpty)
        XCTAssertEqual(handover.question, "Why does the switch stay open?")
        XCTAssertEqual(handover.organisation.confidentiality, "Confidential to Kestrel Heating")
        XCTAssertEqual(handover.retentionDays, 30)
        XCTAssertTrue(ExpertHandoverRendering.text(handover).contains("Confidential to Kestrel Heating"))
    }

    func testNothingIsRuledOutUnlessTheTechnicianSaidSo() throws {
        // The record has a finished task and a recommendation, but nobody said anything is ruled out.
        XCTAssertTrue(try build(input(expert: staff())).work.ruledOut.isEmpty)
    }

    // MARK: - Generations

    private func sent(_ expert: ExpertListEntry, id: String, generation: Int) -> ExpertHandoverSent {
        ExpertHandoverSent(handoverId: id, generation: generation, expert: expert.contact.snapshot, channel: "messages",
                           sentAt: start.addingTimeInterval(Double(generation)), photoIds: [], photosLeftOut: .none,
                           transcriptIncluded: false, addressIncluded: false, tasks: 0, readings: 0,
                           manualReferences: 0, question: "Why?", ruledOut: ["The hose"])
    }

    func testGenerationNPlusOneReplacesN() throws {
        let sam = staff()
        let first = ExpertHandoverLedger.next(expertId: "sam", sent: [], newId: { "H-1" })
        XCTAssertEqual(first.handoverId, "H-1")
        XCTAssertEqual(first.generation, 1)

        let afterOne = [sent(sam, id: "H-1", generation: 1)]
        let second = ExpertHandoverLedger.next(expertId: "sam", sent: afterOne, newId: { "unused" })
        XCTAssertEqual(second.handoverId, "H-1", "the same handover, so the expert's app replaces it")
        XCTAssertEqual(second.generation, 2)

        let both = afterOne + [sent(sam, id: "H-1", generation: 2)]
        XCTAssertEqual(ExpertHandoverLedger.current(both).map(\.generation), [2], "generation 2 replaces 1")
        XCTAssertEqual(ExpertHandoverLedger.next(expertId: "priya", sent: both, newId: { "H-2" }).generation, 1,
                       "another expert's handover is its own")

        let file = try ExpertHandoverFile.write(try build(input(expert: sam, photos: 0, generation: 2)), photos: [:])
        let opened = try ExpertHandoverFile.read(file).get()
        XCTAssertEqual(opened.handover.generation, 2)
        XCTAssertEqual(opened.handover.handoverId, "H-1")
        XCTAssertTrue(ExpertHandoverRendering.text(opened.handover).contains("A later update replaces this one."))
    }

    func testTheSessionRecordDecodesWithAndWithoutHandovers() throws {
        var record = session()
        record.expertHandovers = [sent(staff(), id: "H-1", generation: 1)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(FieldSession.self, from: encoder.encode(record))
        XCTAssertEqual(back.expertHandovers?.first?.generation, 1)
        XCTAssertEqual(back.expertHandovers?.first?.photoIds, [], "ids, never pixels")

        let none = try encoder.encode(session())
        XCTAssertFalse(String(decoding: none, as: UTF8.self).contains("expertHandovers"), "absent when none were sent")
    }

    // MARK: - The .ogcase file

    func testAnOgcaseRoundTrips() throws {
        let handover = try build(input(expert: staff(), photos: 2))
        let photos = photoData(handover)
        let opened = try ExpertHandoverFile.read(try ExpertHandoverFile.write(handover, photos: photos)).get()
        XCTAssertEqual(opened.handover, handover)
        XCTAssertEqual(opened.photos, photos)
    }

    private func manifest(version: Int = 1, type: String = "openglasses.handover", photos: [String] = []) throws -> Data {
        let handover = try build(input(expert: staff(), photos: 0))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: ExpertHandoverFile.encoder().encode(handover)) as? [String: Any])
        object["version"] = version
        object["type"] = type
        object["photos"] = photos.map { ["file": $0, "capturedAt": "2027-01-15T08:00:00Z"] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testTheReaderRejectsAWrongVersionOrType() throws {
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", try manifest(version: 2))])).failureValue,
                       .unsupportedVersion(2))
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", try manifest(type: "openglasses.job"))])).failureValue,
                       .notAHandover)
        XCTAssertEqual(ExpertHandoverFile.read(Data("not a zip".utf8)).failureValue, .notAZip)
    }

    func testTheReaderRejectsAMissingManifest() {
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("photos/01.jpg", jpeg())])).failureValue, .missingManifest)
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", Data("{}".utf8))])).failureValue,
                       .unreadableManifest)
    }

    func testTheReaderRejectsPathTraversalAndAnythingUnlisted() throws {
        let json = try manifest()
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", json), ("../evil.jpg", jpeg())])).failureValue,
                       .unsafeEntryPath("../evil.jpg"))
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", json), ("photos/../../evil.jpg", jpeg())])).failureValue,
                       .unsafeEntryPath("photos/../../evil.jpg"))
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", json), ("/etc/evil.jpg", jpeg())])).failureValue,
                       .unsafeEntryPath("/etc/evil.jpg"))
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", json), ("photos/99.jpg", jpeg())])).failureValue,
                       .unexpectedEntry("photos/99.jpg"))
        // A JSON that names a path outside the package is refused even when the zip holds no such entry.
        let traversing = try manifest(photos: ["../../Library/x.jpg"])
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", traversing)])).failureValue,
                       .unsafeEntryPath("../../Library/x.jpg"))
        let missing = try manifest(photos: ["photos/01.jpg"])
        XCTAssertEqual(ExpertHandoverFile.read(StoredZipWriter.zip([("handover.json", missing)])).failureValue,
                       .missingPhoto("photos/01.jpg"))
    }

    func testTheWriterRefusesAPhotoItWasNotGiven() throws {
        let handover = try build(input(expert: staff(), photos: 1))
        XCTAssertThrowsError(try ExpertHandoverFile.write(handover, photos: [:]))
    }

    func testTheDocumentTypeIsDeclaredAndOpensAsACopy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let type = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == ExpertHandoverFile.utiIdentifier })
        let tags = try XCTUnwrap(type["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], [ExpertHandoverFile.fileExtension])
        XCTAssertEqual(tags["public.mime-type"] as? [String], [ExpertHandoverFile.mimeType])
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertTrue(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains(ExpertHandoverFile.utiIdentifier) == true })
        XCTAssertEqual(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool, false)
        XCTAssertTrue(ExpertHandoverFile.isHandoverFile(URL(fileURLWithPath: "/tmp/job-4471-handover-2.ogcase")))
        XCTAssertFalse(ExpertHandoverFile.isHandoverFile(URL(fileURLWithPath: "/tmp/job.ogjob")))
    }

    // MARK: - Medical mode never offers the handover (§8)

    func testMedicalModeNeverOffersTheHandover() throws {
        for mode in [MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false), .localOnly] {
            XCTAssertEqual(ExpertHandoverAvailability.decide(mode: mode, entitled: true, hasExperts: true, hasOpenJob: true),
                           .refused(ExpertHandoverAvailability.medicalReason))
            XCTAssertEqual(ExpertHandoverBuilder.build(input(expert: staff()), mode: mode).failureValue, .medicalMode)
        }
        XCTAssertEqual(ExpertHandoverAvailability.decide(mode: .off, entitled: true, hasExperts: true, hasOpenJob: true), .offered)
        XCTAssertFalse(ExpertHandoverAvailability.decide(mode: .off, entitled: false, hasExperts: true, hasOpenJob: true).isOffered)
        XCTAssertFalse(ExpertHandoverAvailability.decide(mode: .off, entitled: true, hasExperts: false, hasOpenJob: true).isOffered)

        // Every way in asks first: the tool's 'send', the job's row, the draft and the build.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
        let tool = try String(contentsOf: root.appendingPathComponent("Services/NativeTools/EscalateToExpertTool.swift"), encoding: .utf8)
        XCTAssertTrue(tool.contains("if case .refused(let reason) = handovers.availability() { return reason }"))
        let sheet = try String(contentsOf: root.appendingPathComponent("App/Views/Job/ExpertHandoverSheet.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("if service.availability().isOffered"))
        let service = try String(contentsOf: root.appendingPathComponent("Services/FieldAssist/Experts/ExpertHandoverService.swift"), encoding: .utf8)
        XCTAssertEqual(service.components(separatedBy: "if case .refused(let reason) = availability()").count - 1, 2,
                       "both the draft and the build refuse")
    }

    // MARK: - The staged send

    private func draft(generation: Int = 1, photos: Set<String> = ["p0"]) -> ExpertHandoverDraft {
        ExpertHandoverDraft(id: UUID(), sessionId: "job-s1", jobNumber: "Job 4471", expert: staff(), channel: .messages,
                            recipients: ["+64210001111"], handoverId: "H-1", generation: generation,
                            photoCandidates: media(2), chosenPhotoIds: photos, transcriptChoice: nil,
                            question: "", ruledOut: "", transcriptRule: nil)
    }

    func testOnlySendItOrTheTapSends() throws {
        var built = 0
        var presented: [DeliveryRequest] = []
        let request = DeliveryRequest.make(expertHandover: sent(staff(), id: "H-1", generation: 1), sessionId: "job-s1",
                                           jobReference: "4471", channel: .messages, recipients: ["+64210001111"],
                                           subject: "Handover", body: "Body", shortBody: "Short", attachments: [])
        var seams = JobSendService.Seams()
        seams.buildHandover = { _ in built += 1; return .success(request) }
        seams.presentHandover = { presented.append($0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handover-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = JobSendService(queue: DeliveryQueueStore(directory: directory), seams: seams)

        XCTAssertEqual(service.confirmHandover(), "There's no handover waiting to send.")
        let proposal = service.proposeHandover(draft())
        XCTAssertTrue(proposal.contains("Sam Ferreira"))
        XCTAssertTrue(proposal.contains("Say send it, or tap Send"))
        XCTAssertEqual(built, 0, "proposing builds nothing")
        XCTAssertTrue(presented.isEmpty, "and sends nothing")
        XCTAssertTrue(service.isHandoverConfirmation("send it"))
        XCTAssertFalse(service.isHandoverConfirmation("I'll send it later"))

        let said = service.confirmHandover()
        XCTAssertEqual(built, 1)
        XCTAssertEqual(presented.map(\.id), [request.id], "the composer opens for the technician's own tap")
        XCTAssertNil(service.handoverDraft)
        XCTAssertTrue(said.contains("Check it and tap Send"))
        XCTAssertEqual(service.stagedCount, 0, "a handover is not a job report in the send queue")
    }

    func testTheSpokenGateForSendAndSendIt() {
        let tool = EscalateToExpertTool.self
        XCTAssertNil(tool.refusal(said: "send Sam the latest", previousReply: nil, expertName: "Sam", action: "send"))
        XCTAssertNil(tool.refusal(said: "yes", previousReply: "Two furnace experts. Sam is on call. Call Sam?",
                                  expertName: "Sam", action: "send"))
        XCTAssertEqual(tool.refusal(said: "what's the switch pressure", previousReply: nil, expertName: "Sam", action: "send"),
                       tool.notRequested)
        XCTAssertNil(tool.refusal(said: "send it", previousReply: nil, action: "send_it"))
        XCTAssertEqual(tool.refusal(said: "send it later", previousReply: nil, action: "send_it"), tool.notConfirmedSend)
        XCTAssertEqual(tool.refusal(said: "call Sam", previousReply: nil, expertName: "Sam", action: "send_it"),
                       tool.notConfirmedSend, "only \"send it\" is the spoken Send")
        XCTAssertTrue(tool.pagesAnExpert(tool: "escalate_to_expert", args: ["action": "send"]))
        XCTAssertTrue(tool.pagesAnExpert(tool: "escalate_to_expert", args: ["action": "send_it"]))
    }

    func testAHandoverIsNotTheJobReport() {
        let request = DeliveryRequest.make(expertHandover: sent(staff(), id: "H-1", generation: 1), sessionId: "job-s1",
                                           jobReference: "4471", channel: .email, recipients: [], subject: "s",
                                           body: "b", shortBody: "sb", attachments: [])
        XCTAssertNil(request.record)
        XCTAssertNil(request.payload.queuedOp(), "never to an endpoint")
        XCTAssertTrue(request.partsRequestIds.isEmpty)
        XCTAssertEqual(request.sessionId, "job-s1")
        XCTAssertEqual(request.payload.expertHandover?.generation, 1)
    }

    func testTheChannelFollowsTheExpertsEntry() {
        XCTAssertEqual(ExpertHandoverSendCopy.channel(for: staff().contact, messagesCanAttach: true).0, .messages)
        XCTAssertEqual(ExpertHandoverSendCopy.channel(for: staff().contact, messagesCanAttach: false).0, .shareSheet,
                       "Messages that can't attach a file can't carry a handover")
        let priya = ExpertHandoverSendCopy.channel(for: contracted().contact, messagesCanAttach: true)
        XCTAssertEqual(priya.0, .email)
        XCTAssertEqual(priya.1, ["priya@example.com"])
        for channel in [EscalationContact.HandoverChannel.whatsApp, .airDrop] {
            let contact = EscalationContact(id: "x", name: "Lee Moana", phone: "+64 21 000 4444", handoverChannel: channel)
            XCTAssertEqual(ExpertHandoverSendCopy.channel(for: contact, messagesCanAttach: true).0, .shareSheet,
                           "WhatsApp and AirDrop take a file only from the share sheet")
        }
    }

    func testTheHandoverStaysInsideTheReportsAllowedChannels() {
        let all = Set(DeliveryChannel.localChannels)
        XCTAssertEqual(ExpertHandoverSendCopy.channel(for: staff().contact, messagesCanAttach: true,
                                                      allowed: all)?.0, .messages)
        XCTAssertEqual(ExpertHandoverSendCopy.channel(for: staff().contact, messagesCanAttach: true,
                                                      allowed: [.email, .shareSheet])?.0, .shareSheet,
                       "Messages forbidden for reports is forbidden for the handover")
        XCTAssertNil(ExpertHandoverSendCopy.channel(for: staff().contact, messagesCanAttach: true,
                                                    allowed: [.email]),
                     "no allowed channel can reach a Messages expert, so nothing goes")
        let lee = EscalationContact(id: "x", name: "Lee Moana", phone: "+64 21 000 4444", handoverChannel: .whatsApp)
        XCTAssertNil(ExpertHandoverSendCopy.channel(for: lee, messagesCanAttach: true, allowed: [.whatsapp, .email]),
                     "WhatsApp goes by the share sheet, so a forbidden share sheet stops it")
        XCTAssertTrue(ExpertHandoverSendCopy.noAllowedChannelReason("Lee").contains("Lee"))
    }

    // MARK: - Disclosure (§8)

    func testThePrivacyCopyAndTheManifestDiscloseTheHandover() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/App/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertEqual(settings.components(separatedBy: "Sending a job to an expert sends its details, and the photos you pick with faces blurred, only to the expert you choose, by your own Messages, Mail or share sheet.").count - 1, 2,
                       "both builds' Privacy footers say it")
        // Plan KW: and what an invitation for an expert's card carries.
        XCTAssertEqual(settings.components(separatedBy: "An invitation asking an expert for their card carries only your organisation's name, yours and where to reply.").count - 1, 2,
                       "both builds' Privacy footers say what an invite carries")
        let manifest = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("A job handover to an expert"))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
