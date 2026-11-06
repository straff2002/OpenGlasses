import Foundation
@testable import OpenGlasses

/// Plan KM P2 — handovers as an expert's phone receives them. Every name, number, company and
/// address here is invented.
enum AssistingFixture {

    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])

    static func session(readings: Int = 1) -> FieldSession {
        var session = FieldSession(id: "job-s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: start, outcome: .inProgress, escalations: [], billableSeconds: 0)
        session.jobReference = "4471"
        session.site = JobSite(customer: "Harbour Bakery Ltd", address: "14 Kauri Street, Riverton 9822",
                               contact: "021 555 0199")
        session.faultReport = FaultReport(text: "No heat, pressure switch fault on the display", source: .jobFile,
                                          receivedAt: start)
        session.spokenReadings = (0..<readings).map {
            SpokenReading(id: "r\($0)", quantity: "switch pressure", value: "0.6\($0)", unit: "inWC",
                          at: start.addingTimeInterval(Double($0) * 60))
        }
        return session
    }

    static func entry(id: String = "sam", name: String = "Sam Ferreira") -> ExpertListEntry {
        ExpertListEntry(contact: EscalationContact(id: id, name: name, phone: "+64 21 000 1111",
                                                   handoverChannel: .messages, specialties: ["furnace"], kind: .staff),
                        source: .organization)
    }

    static func handover(id: String = "H-1", generation: Int = 1, organisation: String = "Kestrel Heating",
                         expertId: String = "sam", expertName: String = "Sam Ferreira", readings: Int = 1,
                         photos: Int = 1, question: String = "Why does the switch stay open?",
                         retentionDays: Int = 30, conversation: Bool = true) -> ExpertHandover {
        let lines = conversation ? [
            JobTranscriptExport.Line(timestamp: start.addingTimeInterval(30), speaker: .technician,
                                     text: "Talked to Mrs Ngaio Tamatea about the noise", imageAttached: false),
        ] : []
        let input = ExpertHandoverBuilder.Input(
            session: session(readings: readings), vaultTrades: ["refrigeration_hvac"],
            expert: entry(id: expertId, name: expertName),
            organisation: .init(name: organisation, transcriptRule: .include, retentionDays: retentionDays),
            choice: .init(question: question, ruledOut: ["Inducer hose"]),
            conversation: lines,
            citations: ["Furnace Service Manual, page 12, §Pressure switch"],
            photos: (0..<photos).map { .init(itemId: "p\($0)", capturedAt: start.addingTimeInterval(Double($0)), caption: nil) },
            handoverId: id, generation: generation, now: start.addingTimeInterval(Double(generation) * 600))
        return try! ExpertHandoverBuilder.build(input, mode: .off).get()
    }

    /// The handover as the expert's phone reads it out of the file the technician sent.
    static func opened(_ handover: ExpertHandover) -> ExpertHandoverFile.Opened {
        let photos = Dictionary(uniqueKeysWithValues: handover.photos.map { ($0.file, jpeg) })
        let file = try! ExpertHandoverFile.write(handover, photos: photos)
        return try! ExpertHandoverFile.read(file).get()
    }

    static func temporaryDirectory(_ name: String = "assisting") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The sent record the technician's phone kept for a handover.
    static func sent(_ handover: ExpertHandover, expert: ExpertSnapshot? = nil) -> ExpertHandoverSent {
        ExpertHandoverSent(handoverId: handover.handoverId, generation: handover.generation,
                           expert: expert ?? ExpertSnapshot(id: handover.expert.id, name: handover.expert.name, kind: .staff),
                           channel: DeliveryChannel.messages.rawValue, sentAt: handover.createdAt, photoIds: [],
                           photosLeftOut: .none, transcriptIncluded: true, addressIncluded: false,
                           tasks: 0, readings: handover.work.readings.count, manualReferences: 1,
                           question: handover.question, ruledOut: handover.work.ruledOut)
    }
}

/// A moveable clock for the store and the service.
final class AssistingTestClock {
    var now: Date
    init(_ now: Date = AssistingFixture.start) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
