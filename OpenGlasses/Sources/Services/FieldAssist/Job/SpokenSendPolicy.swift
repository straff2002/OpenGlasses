import Foundation

/// What "send it" can actually do from the car, and to whom (Plan FO §6, P3b).
///
/// Three decisions, all pure, because each of them is a decision about a customer's record leaving
/// the device:
///
///  1. **Which channels can go without a screen.** Only the unattended one. Mail and Messages need
///     a composer iOS will not present in CarPlay, and WhatsApp and Telegram need their own app in
///     the foreground; the share sheet needs somebody to pick a destination. Those are *staged*,
///     and staging is honest about it — nothing goes without the tap.
///  2. **Where recipients come from.** The job's previous delivery, then the device's delivery
///     settings, then the organisation's profile. **Never from speech.** A spoken address is
///     refused with "add it on the phone", because a misheard address is the one mistake in this
///     flow nobody would notice until the wrong person had the customer's job record.
///  3. **What the technician is told before anything happens**, and what counts as the Send tap.
enum SpokenSendPolicy {

    /// Whether a channel can complete a send with nobody looking at the phone.
    enum Handling: Equatable {
        case immediate
        case staged

        var queueState: QueuedSend.State { self == .immediate ? .immediate : .staged }
    }

    /// The partition. Stated as a total function over the channel enum so a channel added later
    /// cannot quietly default to "sends itself".
    static func handling(for channel: DeliveryChannel) -> Handling {
        switch channel {
        case .endpoint:
            // The unattended route: a POST to the organisation's own endpoint, through the
            // existing store-and-forward queue when there is no connection.
            return .immediate
        case .email, .messages:
            // A composer, which CarPlay cannot present.
            return .staged
        case .whatsapp, .telegram:
            // Opened by URL scheme, which needs that app in the foreground on the phone.
            return .staged
        case .shareSheet:
            // Somebody has to pick a destination.
            return .staged
        }
    }

    /// Why a staged channel is staged, in the technician's own terms. Used by the confirmation, so
    /// "ready on your phone" is never mysterious.
    static func stagingReason(for channel: DeliveryChannel) -> String {
        switch channel {
        case .email, .messages: return "the composer only opens on the phone"
        case .whatsapp, .telegram: return "\(channel.label) has to be open on the phone"
        case .shareSheet: return "you have to pick where it goes"
        case .endpoint: return ""
        }
    }

    // MARK: - Recipients

    enum RecipientOutcome: Equatable {
        case resolved([String], QueuedSend.RecipientSource)
        /// The sentence the app says. A refusal is always actionable.
        case refused(String)
    }

    /// The refusal for an address said out loud. One constant, because the Direct-mode path, the
    /// car and the test all have to say the same thing.
    static let spokenAddressRefusal =
        "I can't take a new address by voice — add it on the phone and I'll use it next time."

    /// Resolve who a send goes to.
    ///
    /// - Parameters:
    ///   - channel: the channel chosen.
    ///   - previousDelivery: the addresses this job's report went to last time, when it went.
    ///   - settings: this device's delivery settings.
    ///   - organisation: the organisation profile's addresses, when there is a profile. A
    ///     stand-in for Plan CT, which is where this belongs.
    ///   - spokenAddress: anything in the utterance that looked like an address or a number. Its
    ///     presence is what produces the refusal; its content is never used.
    static func recipients(channel: DeliveryChannel,
                           previousDelivery: [String] = [],
                           settings: DeliverySettings,
                           organisation: [String] = [],
                           spokenAddress: String? = nil) -> RecipientOutcome {
        if let spoken = spokenAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spoken.isEmpty {
            return .refused(spokenAddressRefusal)
        }
        guard channel.needsRecipient else { return .resolved([], .channelOwned) }

        let previous = previousDelivery.filter { !$0.isEmpty }
        if !previous.isEmpty { return .resolved(previous, .previousDelivery) }

        let configured = DeliveryPolicy(settings: settings).defaultRecipients(for: channel)
        if !configured.isEmpty { return .resolved(configured, .deliverySettings) }

        let fromOrganisation = organisation.filter { !$0.isEmpty }
        if !fromOrganisation.isEmpty { return .resolved(fromOrganisation, .organisationProfile) }

        return .refused("There's nobody set up to receive it by \(channel.spokenName). "
                        + "Add an address on the phone, under Settings, Field Assist, Job reports.")
    }

    /// Whether the utterance contains something shaped like an address or a phone number. Used to
    /// *refuse*, never to resolve — which is why it is allowed to be generous.
    static func spokenAddress(in text: String) -> String? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        if let address = words.first(where: { $0.contains("@") && $0.contains(".") }) { return address }
        // A run of seven or more digits said as a number.
        let digits = text.filter(\.isNumber)
        if digits.count >= 7, text.lowercased().contains("send") { return digits }
        // "send it to dave at example dot com" — spelled out, which is exactly the case a
        // recogniser gets wrong and exactly the one this refuses.
        let lowered = text.lowercased()
        if words.contains(where: { $0.lowercased() == "at" }), lowered.contains(" dot ") {
            return text
        }
        return nil
    }

    // MARK: - What is said

    /// What would go and to whom, said before anything happens.
    ///
    /// "The work order for job 1005, with the debrief addendum, to base by email. Say send it when
    /// you're ready." — the sentence §6 names, with the channel's own wording so the same words
    /// appear here and in the composer's confirmation.
    static func confirmation(jobNumber: String,
                             documentKind: QueuedSend.DocumentKind,
                             channel: DeliveryChannel,
                             recipients: [String],
                             includesDebrief: Bool = false) -> String {
        var line = "\(documentKind.spokenName.prefixCapitalised) for \(jobNumber.lowercasedJobPhrase)"
        if includesDebrief, documentKind == .report { line += ", with the debrief" }
        line += ", by \(channel.spokenName)"
        if !recipients.isEmpty { line += " to \(recipients.joined(separator: ", "))" }
        line += "."
        switch handling(for: channel) {
        case .immediate:
            line += " Say \"send it\" and it goes."
        case .staged:
            line += " Say \"send it\" and I'll get it ready — \(stagingReason(for: channel)), "
                + "so it'll be one tap when you stop."
        }
        return line
    }

    /// What the app says once the technician has said "send it".
    static func outcome(jobNumber: String, documentKind: QueuedSend.DocumentKind,
                        channel: DeliveryChannel, handled: Handling,
                        queuedOffline: Bool = false) -> String {
        switch handled {
        case .immediate:
            return queuedOffline
                ? "\(documentKind.spokenName.prefixCapitalised) for \(jobNumber.lowercasedJobPhrase) "
                    + "is queued — it goes as soon as there's a connection."
                : "\(documentKind.spokenName.prefixCapitalised) for \(jobNumber.lowercasedJobPhrase) "
                    + "has gone to \(channel.spokenName)."
        case .staged:
            return "Ready on your phone — one tap when you stop."
        }
    }

    /// Whether the utterance is the Send tap, said out loud. Narrow on purpose: "send it" is the
    /// only thing that sends, and "I'll send it later" is not it.
    static func isSendConfirmation(_ text: String) -> Bool {
        let normalised = DebriefReviewState.normalise(text)
        let refusals = ["later", "not yet", "don't", "dont", "no ", "hold off", "wait"]
        guard !refusals.contains(where: { normalised.contains($0) }) else { return false }
        let phrases = ["send it", "send that", "send the report", "send the job",
                       "send it now", "go ahead and send", "yes send it"]
        return DebriefReviewState.matches(normalised, phrases)
    }

    /// "What's waiting?" — the queue read-back.
    static func isQueueQuery(_ text: String) -> Bool {
        let normalised = DebriefReviewState.normalise(text)
        let phrases = ["whats waiting", "what is waiting", "whats still waiting",
                       "anything waiting", "whats in the queue", "what needs sending",
                       "whats left to send"]
        return DebriefReviewState.matches(normalised, phrases)
    }
}

private extension String {
    /// "the work order" → "The work order".
    var prefixCapitalised: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }

    /// "Job 1005" → "job 1005", so it reads inside a sentence. "No job number" keeps its shape as
    /// a phrase rather than becoming "no job number" mid-sentence by accident.
    var lowercasedJobPhrase: String {
        hasPrefix("Job ") ? "job " + dropFirst(4) : "the job with no number"
    }
}
