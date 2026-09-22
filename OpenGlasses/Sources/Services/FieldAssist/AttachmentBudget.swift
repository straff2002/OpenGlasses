import Foundation

/// How much a delivery channel will carry, and what happens to a clip that does not fit
/// (Plan FO P2b).
///
/// A work order PDF carries its photographs inside it. A clip cannot go inside anything: it is a
/// file of its own, and the channels a technician sends a report through disagree sharply about how
/// large a file they will take. Mail and Messages both silently refuse — or, worse, accept and then
/// fail somewhere the technician never sees — so the decision is made here, before the composer
/// opens, and the answer is said out loud rather than discovered later.
///
/// **Over budget is never a drop.** A clip that will not fit is named in the report and in the
/// body of the message, and the flow offers the share sheet for it, which has no budget at all.
/// The one thing that must not happen is a technician tapping Send believing a clip went with it.
///
/// Pure arithmetic over sizes the recorder measured at capture, so the same job and the same
/// channel always partition the same way — which is what makes a re-send from a past job reproduce
/// the delivery that went out rather than a fresh guess at it.
struct AttachmentBudget: Equatable {

    /// The channel this budget describes.
    let channel: DeliveryChannel
    /// The largest single file the channel will carry. Nil means "no stated limit" — the share
    /// sheet, which hands the file to whatever the technician picks.
    let perFileBytes: Int?
    /// The largest total across everything attached, the PDF and the JSON included. Nil means no
    /// stated limit.
    let totalBytes: Int?
    /// Whether the channel can carry a file at all.
    let carriesFiles: Bool

    // MARK: - The numbers
    //
    // These are **conservative defaults, not device measurements.** Neither MessageUI composer
    // publishes a limit: `MFMailComposeViewController` accepts whatever it is handed and the
    // provider refuses it later, and `MFMessageComposeViewController.canSendAttachments()` answers
    // yes or no without saying how large. So the ceilings below are set where a report reliably
    // arrives — comfortably under the ~25 MB most mail providers refuse above, and under the
    // smallest carrier MMS ceiling for the message route, which is the one that degrades to SMS
    // without telling anybody. Plan FO's open question asks a pilot device to confirm them; they
    // are `Config` values so that confirmation is a settings change and not a build.

    /// Mail: the whole report, comfortably inside what a mail provider will relay.
    static var emailTotalBytes: Int { Config.jobReportEmailBudgetBytes }
    /// Messages: small, because the fallback when it is too big is not a refusal but a message
    /// that quietly becomes something else.
    static var messagesTotalBytes: Int { Config.jobReportMessagesBudgetBytes }

    /// The budget for a channel, given what this device says the composer can do.
    ///
    /// - Parameter canSendAttachments: what `MFMessageComposeViewController.canSendAttachments()`
    ///   answered. Only the device can say, so it is an input here rather than something this type
    ///   goes and asks — the same rule `ReportComposerModel` already follows.
    static func standard(for channel: DeliveryChannel,
                         canSendAttachments: Bool = true) -> AttachmentBudget {
        guard channel.carriesAttachments, canSendAttachments else {
            return AttachmentBudget(channel: channel, perFileBytes: 0, totalBytes: 0,
                                    carriesFiles: false)
        }
        switch channel {
        case .email:
            return AttachmentBudget(channel: channel, perFileBytes: emailTotalBytes,
                                    totalBytes: emailTotalBytes, carriesFiles: true)
        case .messages:
            return AttachmentBudget(channel: channel, perFileBytes: messagesTotalBytes,
                                    totalBytes: messagesTotalBytes, carriesFiles: true)
        case .shareSheet:
            // The technician picks the destination, and the destination states its own limits. A
            // ceiling invented here would refuse an AirDrop that would have worked perfectly.
            return AttachmentBudget(channel: channel, perFileBytes: nil, totalBytes: nil,
                                    carriesFiles: true)
        case .endpoint:
            // The office endpoint takes the record as JSON. It has never been handed a file and
            // inventing an upload shape for one would commit to an endpoint nobody has spoken to —
            // the same reasoning `EndpointSyncSink` already gives for photo uploads.
            return AttachmentBudget(channel: channel, perFileBytes: 0, totalBytes: 0,
                                    carriesFiles: false)
        case .whatsapp, .telegram:
            return AttachmentBudget(channel: channel, perFileBytes: 0, totalBytes: 0,
                                    carriesFiles: false)
        }
    }

    // MARK: - The partition

    /// Which clips ride along, and which have to travel another way.
    struct Partition: Equatable {
        /// Clip item ids that fit, in the order they were offered.
        let attached: [String]
        /// The ones that do not, each with the sentence explaining why.
        let overBudget: [OverBudget]

        struct OverBudget: Equatable {
            let itemId: String
            /// Plain words, for the composer body and for the report.
            let reason: String
        }

        var isEmpty: Bool { attached.isEmpty && overBudget.isEmpty }
        var overBudgetIds: [String] { overBudget.map(\.itemId) }
    }

    /// Partition `clips` into what this channel will take and what it will not.
    ///
    /// - Parameter reservedBytes: what the report's own files already occupy. The PDF and the JSON
    ///   are the point of the delivery, so they get the room first and the clips take what is left.
    ///
    /// Order is the caller's — the render order, so the first clip a customer would have seen is
    /// the first one that gets a place. A clip too large on its own is refused without spending any
    /// of the remaining room, so one oversized clip cannot push a small one out behind it.
    func partition(clips: [JobMediaItem], reservedBytes: Int = 0) -> Partition {
        guard carriesFiles else {
            return Partition(attached: [],
                             overBudget: clips.map {
                                 .init(itemId: $0.id, reason: noFilesReason)
                             })
        }
        var attached: [String] = []
        var over: [Partition.OverBudget] = []
        var used = reservedBytes
        for clip in clips {
            // A clip nobody measured is a clip whose size is unknown, and an unknown size is not a
            // licence to attach it: the honest answer is the share sheet, which has no limit.
            guard let size = clip.byteCount, size > 0 else {
                over.append(.init(itemId: clip.id, reason: unmeasuredReason))
                continue
            }
            if let perFileBytes, size > perFileBytes {
                over.append(.init(itemId: clip.id, reason: tooLargeReason(size: size)))
                continue
            }
            if let totalBytes, used + size > totalBytes {
                over.append(.init(itemId: clip.id, reason: noRoomLeftReason))
                continue
            }
            attached.append(clip.id)
            used += size
        }
        return Partition(attached: attached, overBudget: over)
    }

    // MARK: - Words

    private var noFilesReason: String {
        channel == .endpoint
            ? "the office endpoint takes the record, not video"
            : "\(channel.label) can't carry a file"
    }

    private var unmeasuredReason: String {
        "its size couldn't be read on this device"
    }

    private var noRoomLeftReason: String {
        "there was no room left in one \(channel.label.lowercased())"
    }

    private func tooLargeReason(size: Int) -> String {
        let measured = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        guard let perFileBytes else { return "it is too large for \(channel.label)" }
        let ceiling = ByteCountFormatter.string(fromByteCount: Int64(perFileBytes), countStyle: .file)
        return "at \(measured) it is over the \(ceiling) limit for \(channel.label)"
    }
}

/// What actually happens to a job's clips on the way out, decided once and then used by the PDF,
/// the JSON, the composer body and the share offer alike (Plan FO P2b).
///
/// One value rather than four decisions: the line the customer reads under a task, the `attached`
/// flag in the machine-readable record, the sentence in the message body and the list of "Share
/// clip" buttons all have to agree, and the only way they can is by being the same partition
/// rendered four ways.
struct ClipDeliveryPlan: Equatable {

    /// How the report will travel. Nil when no channel has been chosen yet — an export taken for
    /// the archive rather than for a send, which says a clip is "sent separately" without claiming
    /// to know what refused it.
    let channelLabel: String?
    let attached: [String]
    let overBudget: [AttachmentBudget.Partition.OverBudget]

    static let undecided = ClipDeliveryPlan(channelLabel: nil, attached: [], overBudget: [])

    init(channelLabel: String?, attached: [String],
         overBudget: [AttachmentBudget.Partition.OverBudget]) {
        self.channelLabel = channelLabel
        self.attached = attached
        self.overBudget = overBudget
    }

    init(channel: DeliveryChannel, partition: AttachmentBudget.Partition) {
        self.init(channelLabel: channel.label, attached: partition.attached,
                  overBudget: partition.overBudget)
    }

    var isEmpty: Bool { attached.isEmpty && overBudget.isEmpty }
    var overBudgetIds: [String] { overBudget.map(\.itemId) }

    func isAttached(_ itemId: String) -> Bool { attached.contains(itemId) }
    func reason(for itemId: String) -> String? {
        overBudget.first { $0.itemId == itemId }?.reason
    }

    /// The phrase printed after a clip's line in the work order, so the record says how the clip
    /// travelled even though the PDF itself cannot carry it.
    func travelNote(for itemId: String) -> String {
        if let reason = reason(for: itemId) {
            guard let channelLabel else { return "shared separately — \(reason)" }
            return "over the size limit for \(channelLabel) — shared separately (\(reason))"
        }
        return "sent separately"
    }

    /// The paragraph appended to a message or mail body, naming every clip that could not ride
    /// along. Nil when everything fitted — a note about nothing is noise.
    func bodyNote(items: [JobMediaItem]) -> String? {
        guard !overBudget.isEmpty else { return nil }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lines = overBudget.map { entry -> String in
            let name = byId[entry.itemId]?.caption ?? "Clip"
            let length = byId[entry.itemId]?.durationLabel.map { " (\($0))" } ?? ""
            return "• \(name)\(length) — \(entry.reason)"
        }
        let count = overBudget.count
        let lead = count == 1
            ? "One clip couldn't be attached to this and is being shared separately:"
            : "\(count) clips couldn't be attached to this and are being shared separately:"
        return ([lead] + lines).joined(separator: "\n")
    }
}
