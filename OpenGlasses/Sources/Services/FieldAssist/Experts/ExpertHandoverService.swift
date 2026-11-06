import Foundation
import UIKit

/// What the handover sheet shows and the technician can change before it goes (Plan KM P1): who it
/// is for, by what, which photos, whether the conversation goes, and their own words.
struct ExpertHandoverDraft: Identifiable, Equatable {
    let id: UUID
    let sessionId: String
    let jobNumber: String
    let expert: ExpertListEntry
    let channel: DeliveryChannel
    let recipients: [String]
    let handoverId: String
    let generation: Int
    /// The job's photos, newest first. Clips are not handover material and are not listed.
    let photoCandidates: [JobMediaItem]
    var chosenPhotoIds: Set<String>
    /// "Include the conversation", once the technician touches it.
    var transcriptChoice: Bool?
    var question: String
    /// What they have ruled out, one item per line, in their words.
    var ruledOut: String
    /// The organisation's say on the conversation, for the sheet's toggle.
    let transcriptRule: ReportTranscriptPolicy.ExpertRule?

    var transcript: ReportTranscriptPolicy.ExpertDecision {
        ReportTranscriptPolicy.forExpert(onOrganisationList: expert.source == .organization,
                                         rule: transcriptRule, technicianChoice: transcriptChoice)
    }

    var ruledOutLines: [String] { ExpertHandoverBuilder.cleanedLines([ruledOut]) }
}

/// Why a handover was not drafted or built, in the words said and shown.
struct ExpertHandoverRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The words the sheet, the voice and the composer use about a handover. Pure.
enum ExpertHandoverSendCopy {

    /// How the handover leaves for this channel, in a phrase.
    static func route(_ channel: DeliveryChannel) -> String {
        switch channel {
        case .messages: return "by Messages"
        case .email: return "by email"
        case .shareSheet: return "from the share sheet, where you pick WhatsApp, AirDrop or another app"
        case .whatsapp, .telegram, .endpoint: return "from the share sheet"
        }
    }

    /// The sentence said and shown before anything is tapped.
    static func proposal(_ draft: ExpertHandoverDraft) -> String {
        let name = draft.expert.contact.name
        var parts: [String] = []
        parts.append(draft.generation == 1
            ? "The job is ready to send to \(name) \(route(draft.channel))."
            : "Update \(draft.generation) for \(name) is ready to send \(route(draft.channel)); it replaces the last one.")
        let photos = draft.chosenPhotoIds.count
        parts.append(photos == 0 ? "No photos." : photos == 1 ? "One photo, faces blurred." : "\(photos) photos, faces blurred.")
        parts.append(draft.transcript.includesTranscript ? "The conversation goes with it." : "The conversation stays on this phone.")
        parts.append("Say send it, or tap Send on the phone.")
        return parts.joined(separator: " ")
    }

    /// What the composer is about to carry, once the files exist.
    static func confirmation(sent: ExpertHandoverSent, channel: DeliveryChannel) -> String {
        var line = "Job handover for \(sent.expert.name), update \(sent.generation), ready \(route(channel))."
        if !sent.photoIds.isEmpty {
            line += sent.photoIds.count == 1 ? " One photo goes with it." : " \(sent.photoIds.count) photos go with it."
        }
        line += droppedSentence(sent.photosLeftOut).map { " " + $0 } ?? ""
        line += " Check it and tap Send."
        return line
    }

    /// "2 older photos didn't fit …", or nil when nothing was left out.
    static func droppedSentence(_ left: ExpertHandover.PhotosLeftOut) -> String? {
        var parts: [String] = []
        if left.overSizeLimit > 0 {
            parts.append(left.overSizeLimit == 1
                ? "The oldest photo didn't fit and stays on this phone."
                : "The \(left.overSizeLimit) oldest photos didn't fit and stay on this phone.")
        }
        if left.couldNotBeBlurred > 0 {
            parts.append(left.couldNotBeBlurred == 1
                ? "One photo couldn't be blurred, so it stays on this phone."
                : "\(left.couldNotBeBlurred) photos couldn't be blurred, so they stay on this phone.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func subject(_ handover: ExpertHandover) -> String {
        let job = handover.job.reference.map { "job \($0)" } ?? "a job"
        let from = handover.organisation.name.isEmpty ? "" : " from \(handover.organisation.name)"
        return "Handover\(from): \(job), update \(handover.generation)"
    }

    static func shortBody(_ handover: ExpertHandover) -> String {
        let job = handover.job.reference.map { "Job \($0)" } ?? "A job"
        return "\(job) as it stands, for your advice (update \(handover.generation)). Open the .ogcase file "
            + "in Avenkin, or read the PDF. \(handover.organisation.confidentiality)."
    }

    /// The channel and the address a handover goes to, from the expert's list entry (P0). The
    /// channels that carry a file through a composer get one; WhatsApp and AirDrop go by the share
    /// sheet, the only route by which a file reaches them.
    static func channel(for contact: EscalationContact, messagesCanAttach: Bool) -> (DeliveryChannel, [String]) {
        let phone = contact.phone.flatMap(CallRoute.cleanedNumber)
        let handle = contact.faceTimeHandle.flatMap(CallRoute.cleanedHandle)
        let email = handle.flatMap { $0.contains("@") ? $0 : nil }
        switch contact.handoverChannel {
        case .messages?:
            guard messagesCanAttach, let to = phone ?? handle else { return (.shareSheet, []) }
            return (.messages, [to])
        case .email?:
            return (.email, email.map { [$0] } ?? [])
        case .whatsApp?, .airDrop?:
            return (.shareSheet, [])
        case nil:
            if messagesCanAttach, let to = phone ?? handle { return (.messages, [to]) }
            return (.shareSheet, [])
        }
    }

    /// The same choice, kept inside the channels the job's reports may use: a handover carries the
    /// job, so an organisation that forbids a channel for the report forbids it for the handover.
    /// The expert's own channel when allowed, else the share sheet when that is allowed, else nil.
    static func channel(for contact: EscalationContact, messagesCanAttach: Bool,
                        allowed: Set<DeliveryChannel>) -> (DeliveryChannel, [String])? {
        let preferred = channel(for: contact, messagesCanAttach: messagesCanAttach)
        if allowed.contains(preferred.0) { return preferred }
        if allowed.contains(.shareSheet) { return (.shareSheet, []) }
        return nil
    }

    static func noAllowedChannelReason(_ name: String) -> String {
        "None of the channels this job's reports may use can carry the job to \(name). "
            + "Check Settings → Field Assist → Job reports."
    }
}

/// Gathers a handover from the open job, writes its files and builds the request the composer
/// opens (Plan KM P1). The rules are all in the pure types — `ExpertHandoverBuilder`,
/// `ExpertHandoverPhotos`, `ReportTranscriptPolicy.forExpert`, `ExpertHandoverLedger` — and this
/// only reads the phone's state into them.
@MainActor
final class ExpertHandoverService {
    static let shared = ExpertHandoverService()

    var sessions: FieldSessionService = .shared
    var experts: ExpertListStore = .shared
    /// The blur. Wired by the app at launch; without it no photo can be prepared, and none goes.
    weak var filter: (any StillImageFiltering)?
    /// The job's conversation, as `JobTranscriptExport` selects it. The app wires the thread from
    /// its conversation store; the default reads the job's own log.
    var conversation: (FieldSession) -> [JobTranscriptExport.Line] = { session in
        JobTranscriptExport.job(session: session, vaultName: session.vaultId, thread: nil,
                                events: SessionLogger.readEvents(
                                    at: FieldSessionService.shared.sessionDirectory(sessionId: session.id))).lines
    }
    var exports: StagedExportCoordinator = .fieldSession
    var mode: () -> MedicalEgressGuard.Mode = { MedicalEgressGuard.currentMode() }
    var messagesCanAttach: () -> Bool = { ReportComposerAvailability.messagesCanAttach }
    /// The job reports' settings, whose allowed channels a handover stays inside.
    var deliverySettings: () -> DeliverySettings = { Config.deliverySettings }
    var now: () -> Date = Date.init

    init() {}

    /// Whether the handover is offered on this phone now.
    func availability() -> ExpertHandoverAvailability {
        ExpertHandoverAvailability.decide(mode: mode(), entitled: FieldAssistEntitlement.shared.has(.fieldWork),
                                          hasExperts: !experts.entries.isEmpty,
                                          hasOpenJob: sessions.activeSession != nil)
    }

    /// The organisation's settings for handovers, read through the profile's clamp.
    static func organisation() -> ExpertHandoverBuilder.Organisation {
        .init(name: Config.organizationDisplayName, transcriptRule: Config.expertHandoverTranscript,
              includesAddressForStaff: Config.expertHandoverIncludesAddress,
              retentionDays: Config.expertHandoverRetentionDays)
    }

    /// A draft for the sheet, for one expert on the list.
    func draft(for contact: EscalationContact, question: String? = nil, ruledOut: [String] = [],
               transcript: Bool? = nil) -> Result<ExpertHandoverDraft, ExpertHandoverRefusal> {
        if case .refused(let reason) = availability() { return .failure(.init(reason)) }
        guard let session = sessions.activeSession else { return .failure(.init(ExpertHandoverAvailability.noJobReason)) }
        guard let entry = experts.entries.first(where: { $0.id == contact.id }) else {
            return .failure(.init("\(contact.name) isn't on the Experts list."))
        }
        let sent = session.expertHandovers ?? []
        let next = ExpertHandoverLedger.next(expertId: entry.id, sent: sent)
        let previous = sent.filter { $0.expert.id == entry.id }.max { $0.generation < $1.generation }
        let photos = session.media.filter { $0.kind == .photo }.sorted { $0.capturedAt > $1.capturedAt }
        guard let (channel, recipients) = ExpertHandoverSendCopy.channel(
            for: entry.contact, messagesCanAttach: messagesCanAttach(),
            allowed: deliverySettings().allowedChannels) else {
            return .failure(.init(ExpertHandoverSendCopy.noAllowedChannelReason(entry.contact.name)))
        }
        let reference = session.jobReference.flatMap { $0.isEmpty ? nil : $0 }
        // "Send the latest" starts from what went last time: the same words, until they change.
        let carriedRuledOut = ruledOut.isEmpty ? (previous?.ruledOut ?? []) : ruledOut
        return .success(ExpertHandoverDraft(
            id: UUID(), sessionId: session.id, jobNumber: reference.map { "Job \($0)" } ?? JobTabModel.noJobNumber,
            expert: entry, channel: channel, recipients: recipients,
            handoverId: next.handoverId, generation: next.generation,
            photoCandidates: photos,
            chosenPhotoIds: Set(ExpertHandoverPhotos.preselection(photos)),
            transcriptChoice: transcript,
            question: question ?? previous?.question ?? "",
            ruledOut: carriedRuledOut.joined(separator: "\n"),
            transcriptRule: Config.expertHandoverTranscript))
    }


    /// Build the handover, write its three files into protected staging, and the request the
    /// composer opens. Nothing has left the phone when this returns.
    func request(for draft: ExpertHandoverDraft) -> Result<DeliveryRequest, ExpertHandoverRefusal> {
        if case .refused(let reason) = availability() { return .failure(.init(reason)) }
        guard let session = sessions.activeSession, session.id == draft.sessionId else {
            return .failure(.init("That job is no longer open."))
        }
        let directory = sessions.sessionDirectory(sessionId: session.id)
        let photosDirectory = directory.appendingPathComponent("photos", isDirectory: true)
        let chosen = session.media.filter { $0.kind == .photo && draft.chosenPhotoIds.contains($0.id) }
        let budget = AttachmentBudget.standard(for: draft.channel,
                                               canSendAttachments: draft.channel == .messages ? messagesCanAttach() : true)
        let prepared: ExpertHandoverPhotos.Prepared
        if let filter {
            prepared = ExpertHandoverPhotos.prepare(
                chosen: chosen, load: { EvidenceImageRenderer.load($0.id, from: photosDirectory) },
                filter: filter, budget: budget)
        } else {
            // No blur wired: fail closed, every chosen photo stays.
            prepared = .init(photos: [], jpegs: [:], leftOut: .init(couldNotBeBlurred: chosen.count, overSizeLimit: 0))
        }

        let export = SessionExporter.buildExport(sessionDir: directory, sessionOverride: session)
        let input = ExpertHandoverBuilder.Input(
            session: session,
            vaultTrades: VaultRegistry.shared.manifest(id: session.vaultId)?.trades ?? [],
            expert: draft.expert, organisation: Self.organisation(),
            choice: .init(transcript: draft.transcriptChoice, question: draft.question, ruledOut: draft.ruledOutLines),
            conversation: conversation(session),
            citations: export?.citations.map(\.source) ?? [],
            procedures: export?.proceduresRun ?? [],
            photos: prepared.photos, photosLeftOut: prepared.leftOut,
            handoverId: draft.handoverId, generation: draft.generation, now: now())
        let handover: ExpertHandover
        switch ExpertHandoverBuilder.build(input, mode: mode()) {
        case .failure: return .failure(.init(ExpertHandoverAvailability.medicalReason))
        case .success(let built): handover = built
        }

        var byEntry: [String: Data] = [:]
        for (index, photo) in prepared.photos.enumerated() {
            byEntry[ExpertHandoverFile.photoEntryName(index: index)] = prepared.jpegs[photo.itemId]
        }
        let stem = Self.fileStem(handover)
        let attachments: [DeliveryRequest.Attachment]
        do {
            let package = try ExpertHandoverFile.write(handover, photos: byEntry)
            let packageLease = try exports.makeLease(data: package, fileExtension: ExpertHandoverFile.fileExtension,
                                                     displayName: stem + "." + ExpertHandoverFile.fileExtension,
                                                     fallbackName: "handover.ogcase")
            let pdfLease = try exports.makeLease(fileExtension: "pdf", displayName: stem + ".pdf",
                                                 fallbackName: "handover.pdf") { url in
                try ExpertHandoverRendering.writePDF(handover, photos: byEntry, to: url)
            }
            let text = ExpertHandoverRendering.text(handover)
            let textLease = try exports.makeLease(data: Data(text.utf8), fileExtension: "txt",
                                                  displayName: stem + ".txt", fallbackName: "handover.txt")
            attachments = [
                .init(url: packageLease.fileURL, kind: .handoverPackage, filename: stem + "." + ExpertHandoverFile.fileExtension),
                .init(url: pdfLease.fileURL, kind: .handoverPDF, filename: stem + ".pdf"),
                .init(url: textLease.fileURL, kind: .handoverText, filename: stem + ".txt"),
            ]
        } catch {
            PrivacyLog.transfer(.fieldSessionExport, .fileFailed, error: SafeErrorSummary(error))
            return .failure(.init("The handover's files couldn't be written on this phone. Try again."))
        }
        PrivacyLog.transfer(.fieldSessionExport, .exported, count: attachments.count)

        let sent = ExpertHandoverSent(
            handoverId: handover.handoverId, generation: handover.generation, expert: draft.expert.contact.snapshot,
            channel: draft.channel.rawValue, sentAt: now(), photoIds: prepared.photos.map(\.itemId),
            photosLeftOut: prepared.leftOut, transcriptIncluded: handover.conversation.included,
            addressIncluded: handover.job.site?.address != nil, tasks: handover.work.tasks.count,
            readings: handover.work.readings.count, manualReferences: handover.manualReferences.count,
            question: handover.question, ruledOut: handover.work.ruledOut)
        return .success(DeliveryRequest.make(
            expertHandover: sent, sessionId: session.id, jobReference: handover.job.reference,
            channel: draft.channel, recipients: draft.recipients,
            subject: ExpertHandoverSendCopy.subject(handover),
            body: ExpertHandoverRendering.text(handover),
            shortBody: ExpertHandoverSendCopy.shortBody(handover),
            attachments: attachments))
    }

    /// "job-4471-handover-2": the job and the generation, never the customer.
    static func fileStem(_ handover: ExpertHandover) -> String {
        let reference = handover.job.reference.map { raw in
            String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
        }
        return (reference.map { "job-\($0)-" } ?? "job-") + "handover-\(handover.generation)"
    }

    /// The composer closed. Only a confirmed send becomes a generation on the job.
    func completed(_ request: DeliveryRequest, outcome: DeliveryOutcome) {
        guard outcome.isSent, case .expertHandover(let sent, let sessionId, _) = request.payload else { return }
        sessions.recordHandoverSent(sent, sessionId: sessionId)
    }
}
