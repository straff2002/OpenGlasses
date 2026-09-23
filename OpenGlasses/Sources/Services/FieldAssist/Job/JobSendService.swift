import Foundation

/// Spoken sends, and the queue they accumulate in (Plan FO §6, P3b).
///
/// The technician says "send the job"; the app names what would go and to whom; only a spoken
/// **"send it"** counts as the Send tap EM requires. What happens then depends on the channel and
/// nothing else: the unattended route goes, everything that needs a screen is *staged* and waits.
///
/// Headless by construction — the composer, the offline queue, the notification and the speech are
/// all closures — so "Mail stages and the delivery seam records zero sends" is an assertion a spy
/// can make rather than a reading of the code.
@MainActor
final class JobSendService: ObservableObject {

    /// Everything device-facing.
    struct Seams {
        var speak: (String) async -> Void = { _ in }
        var settings: () -> DeliverySettings = { DeliverySettings.load() }
        /// The organisation's addresses. A Plan CT stand-in, read through `Config`.
        var organisationRecipients: () -> [String] = { Config.organizationReportRecipients }
        /// The channel this job's report went by last time, when it went at all.
        var previousChannel: (String) -> DeliveryChannel? = { _ in nil }
        /// Build the request the channel will carry. Nil when the record cannot be read back.
        var buildRequest: (String, DeliveryChannel, [String], QueuedSend.DocumentKind)
            -> DeliveryRequest? = { _, _, _, _ in nil }
        /// Hand an immediate send to the route that performs it — the endpoint sink and the
        /// offline queue behind it. Returns what actually happened.
        var deliverImmediately: (DeliveryRequest) async -> DeliveryOutcome = { _ in .handedOff }
        /// Put a staged send in front of the technician's thumb — the composer.
        var presentComposer: (DeliveryRequest) -> Void = { _ in }
        /// Tell the phone something is waiting. A no-op when notifications are refused.
        var notify: (_ stagedCount: Int) -> Void = { _ in }
        /// Write into the job's own audit log.
        var log: (SessionLogger.Event.Kind, String, [String: AnyCodable]) -> Void = { _, _, _ in }
    }

    /// What the app is about to do, held between the confirmation and the "send it".
    struct Proposal: Equatable {
        let sessionId: String
        let jobNumber: String
        let documentKind: QueuedSend.DocumentKind
        let channel: DeliveryChannel
        let recipients: [String]
        let recipientSource: QueuedSend.RecipientSource
        let spoken: String
    }

    let queue: DeliveryQueueStore
    private var seams: Seams

    /// The send named out loud and not yet confirmed. Published so the phone can show the same
    /// sentence the car heard.
    @Published private(set) var proposal: Proposal?
    /// Republished whenever the queue moves, so SwiftUI sees a change through this object.
    @Published private(set) var revision = 0
    /// The entry whose composer is on screen, so the outcome lands on the right one.
    private(set) var presenting: QueuedSend?
    /// Whether Send all is walking the queue.
    private(set) var sendingAll = false

    init(queue: DeliveryQueueStore? = nil, seams: Seams = Seams()) {
        self.queue = queue ?? DeliveryQueueStore()
        self.seams = seams
    }

    func connect(_ seams: Seams) { self.seams = seams }

    // MARK: - Reading

    var stagedCount: Int { queue.queue.stagedCount }
    var staged: [QueuedSend] { queue.queue.staged }
    var cardHeadline: String? { queue.queue.cardHeadline }

    /// "What's waiting?" — spoken, in the car.
    func spokenQueue() -> String { queue.queue.spokenReadBack }

    // MARK: - Proposing

    /// Name what would go, and hold it until the technician says "send it".
    ///
    /// - Returns: the sentence the app speaks — the proposal, or the refusal that replaces it. A
    ///   refusal never leaves a proposal behind, so a later "send it" cannot complete one that was
    ///   refused.
    @discardableResult
    func propose(sessionId: String, jobNumber: String,
                 documentKind: QueuedSend.DocumentKind = .report,
                 includesDebrief: Bool = false,
                 spokenChannel: DeliveryChannel? = nil,
                 utterance: String? = nil) -> String {
        let settings = seams.settings()
        let policy = DeliveryPolicy(settings: settings)
        // The organisation's route first, then this job's last one, then the device default. The
        // addendum follows the original so the second document reaches the people the first did.
        let channel = spokenChannel
            ?? Config.organizationJobReportChannel
            ?? seams.previousChannel(sessionId)
            ?? policy.defaultChannel
        guard let channel else {
            proposal = nil
            return "No channel is allowed for job reports on this device. Set one up on the phone, "
                + "under Settings, Field Assist, Job reports."
        }
        guard settings.allowedChannels.contains(channel) else {
            proposal = nil
            return policy.decide(channel: channel).reason ?? policy.allowedSentence()
        }

        switch SpokenSendPolicy.recipients(
            channel: channel,
            settings: settings,
            organisation: seams.organisationRecipients(),
            spokenAddress: utterance.flatMap { SpokenSendPolicy.spokenAddress(in: $0) }) {
        case .refused(let reason):
            proposal = nil
            return reason
        case .resolved(let recipients, let source):
            let sentence = SpokenSendPolicy.confirmation(
                jobNumber: jobNumber, documentKind: documentKind, channel: channel,
                recipients: recipients, includesDebrief: includesDebrief)
            proposal = Proposal(sessionId: sessionId, jobNumber: jobNumber,
                                documentKind: documentKind, channel: channel,
                                recipients: recipients, recipientSource: source, spoken: sentence)
            return sentence
        }
    }

    /// Whether this utterance is the Send tap, said out loud, for a proposal that is outstanding.
    func isSendConfirmation(_ text: String) -> Bool {
        proposal != nil && SpokenSendPolicy.isSendConfirmation(text)
    }

    func cancelProposal() { proposal = nil }

    // MARK: - Confirming

    /// "Send it." Queue the send and, on an immediate channel, perform it.
    ///
    /// - Returns: what the app says about what happened.
    @discardableResult
    func confirm() async -> String {
        guard let proposal else { return "There's nothing waiting to send." }
        self.proposal = nil
        let handling = SpokenSendPolicy.handling(for: proposal.channel)
        let entry = QueuedSend(sessionId: proposal.sessionId, jobNumber: proposal.jobNumber,
                               documentKind: proposal.documentKind, channel: proposal.channel,
                               recipients: proposal.recipients,
                               recipientSource: proposal.recipientSource,
                               state: handling.queueState)
        queue.append(entry)
        revision += 1
        seams.log(.sendQueued, proposal.sessionId, [
            "entry": AnyCodable(entry.id),
            "document": AnyCodable(proposal.documentKind.rawValue),
            "channel": AnyCodable(proposal.channel.rawValue),
            "handling": AnyCodable(handling == .immediate ? "immediate" : "staged"),
            "recipients": AnyCodable(proposal.recipients.count),
            "recipient_source": AnyCodable(proposal.recipientSource.rawValue)
        ])

        switch handling {
        case .staged:
            // Nothing leaves. The card, the notification and the sentence all say the same thing.
            seams.notify(stagedCount)
            let line = SpokenSendPolicy.outcome(jobNumber: proposal.jobNumber,
                                                documentKind: proposal.documentKind,
                                                channel: proposal.channel, handled: .staged)
            await seams.speak(line)
            return line

        case .immediate:
            guard let request = seams.buildRequest(proposal.sessionId, proposal.channel,
                                                   proposal.recipients, proposal.documentKind) else {
                queue.update(id: entry.id, to: .failed,
                             failureReason: "the job's record could not be read back")
                revision += 1
                let line = "I couldn't put that report together. It's still on the job — try it on "
                    + "the phone."
                await seams.speak(line)
                return line
            }
            queue.update(id: entry.id, to: .sending)
            let outcome = await seams.deliverImmediately(request)
            let queuedOffline = !outcome.isSent
            queue.update(id: entry.id, to: outcome.isSent ? .sent : .immediate,
                         failureReason: outcome.isSent ? nil : "waiting for a connection")
            revision += 1
            let line = SpokenSendPolicy.outcome(jobNumber: proposal.jobNumber,
                                                documentKind: proposal.documentKind,
                                                channel: proposal.channel, handled: .immediate,
                                                queuedOffline: queuedOffline)
            await seams.speak(line)
            return line
        }
    }

    // MARK: - The card on the phone

    /// Open one staged send's composer. The entry stays staged until the composer reports back —
    /// a technician who dismisses it has cancelled nothing and lost nothing.
    func present(_ entry: QueuedSend) {
        guard let request = seams.buildRequest(entry.sessionId, entry.channel, entry.recipients,
                                               entry.documentKind) else {
            queue.update(id: entry.id, to: .failed,
                         failureReason: "the job's record could not be read back")
            presenting = nil
            revision += 1
            return
        }
        presenting = entry
        seams.presentComposer(request)
    }

    /// Open every staged send in turn. The caller feeds each composer's outcome back through
    /// ``complete(id:outcome:)``, and a cancelled one **stays queued** — Send all is an offer to
    /// deal with them, not a decision that they all go.
    func sendAll() -> [QueuedSend] {
        let ready = staged
        sendingAll = ready.count > 1
        if let first = ready.first { present(first) }
        return ready
    }

    /// The entry after the one just settled, for Send all's next step.
    func next(after id: String) -> QueuedSend? {
        let ready = staged
        guard let index = ready.firstIndex(where: { $0.id == id }) else { return ready.first }
        return index + 1 < ready.count ? ready[index + 1] : nil
    }

    /// A composer closed. Only a confirmed send moves the entry; everything else leaves it where
    /// it was — **a cancelled one stays queued**, which is what makes Send all an offer to deal
    /// with them rather than a decision that they all go.
    func complete(id: String, outcome: DeliveryOutcome) {
        queue.update(id: id, to: outcome.isSent ? .sent : .staged)
        revision += 1
        if stagedCount > 0 { seams.notify(stagedCount) }
    }

    /// The composer this service opened has closed. Advances Send all to the next one.
    func completePresented(outcome: DeliveryOutcome) {
        guard let entry = presenting else { return }
        presenting = nil
        complete(id: entry.id, outcome: outcome)
        guard sendingAll else { return }
        // A cancelled entry stays queued and stays in the walk's wake: `next(after:)` reads the
        // staged list as it stands, so the one just dismissed is stepped over rather than
        // re-opened in a loop nobody can escape.
        let remaining = staged.filter { $0.id != entry.id }
        guard let following = remaining.first else {
            sendingAll = false
            return
        }
        present(following)
    }

    /// Whether this service opened the composer now on screen.
    func owns(_ request: DeliveryRequest) -> Bool {
        guard let entry = presenting else { return false }
        return entry.sessionId == request.sessionId
    }

    /// The technician cancelled one from the card. Every other entry is untouched.
    func cancel(id: String) {
        queue.cancel(id: id)
        revision += 1
    }
}
