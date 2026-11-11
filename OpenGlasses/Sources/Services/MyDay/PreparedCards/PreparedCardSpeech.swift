import Foundation

/// Plan KT §6.5 — the day's cards by voice: "what's ready?" read aloud a card at a time, the
/// answers while it reads, **Read it**, and a pushed card said when the Display cannot show it.
///
/// A spoken "yes" only ever **stages** (`stage`, the same `PreparedCardStager.stage` the lens's
/// **Send on phone** uses): it puts the draft on the phone, where the wearer taps Send. Nothing here
/// sends anything.
@MainActor
final class PreparedCardSpeech {

    /// The feed's cards now, ranked.
    var cards: () -> [PreparedCard] = { [] }
    /// §6.4: stage the card's draft on the phone (the lens's **Send on phone**).
    var stage: (PreparedCard) async -> PreparedCardStager.Outcome = { _ in .nothingToStage }
    var later: (PreparedCard) -> Void = { _ in }
    var notUseful: (PreparedCard) -> Void = { _ in }
    var dismiss: (PreparedCard) -> Void = { _ in }
    /// Says a line, under its source: `.alert` for a card the app raised on its own, `.phoneAnswer`
    /// for one the wearer asked for (`SpeechSource`).
    var voice: (_ text: String, _ source: SpeechSource) async -> Void = { _, _ in }
    /// Medical Compliance withholding (`PreparedCardMedicalWithholding.isOn`).
    var withholding: () -> Bool = { PreparedCardMedicalWithholding.isOn }
    var now: () -> Date = Date.init
    var time: (Date) -> String = PreparedCardPhraser.shortTime

    /// The reading in progress, if any.
    private(set) var reading: PreparedCardSpokenStack?

    init() {}

    /// A reading is waiting for the wearer's answer, so the follow-up capture should stay open.
    var isAwaitingAnswer: Bool { reading?.isLive(at: now()) ?? false }

    /// "What's ready?": read the stack from the top. False with no cards (the words then go on
    /// to the digest, or the model).
    @discardableResult
    func readStack() async -> Bool {
        let cards = cards()
        guard let reading = PreparedCardSpokenStack(cards: cards, withholding: withholding(), now: now(),
                                                    time: time) else { return false }
        self.reading = reading
        await say(reading.opening(), pushed: false)
        return true
    }

    /// A card pushed unasked (§6.2) that the Display cannot show: said once, with its offer open
    /// for the answer window like a one-card reading. The microphone is not opened for it; a
    /// "yes" after the wake word, inside the window, stages.
    func speakPushed(_ card: PreparedCard) async {
        guard let reading = PreparedCardSpokenStack(cards: [card], withholding: withholding(), now: now(),
                                                    time: time) else { return }
        self.reading = reading
        await say(reading.opening(), pushed: true)
    }

    /// **Read it** on the lens: the draft, with who it is to.
    func readDraft(_ card: PreparedCard) async {
        guard let text = PreparedCardPhraser.draftReading(card, withholding: withholding()) else { return }
        await voice(text, .readAloud)
    }

    /// An utterance while a reading is live. True when it was an answer (consumed); false leaves
    /// it for the rest of the turn — and ends the reading, so a later "yes" is not taken for one.
    func handle(_ text: String) async -> Bool {
        guard var reading, reading.isLive(at: now()) else {
            self.reading = nil
            return false
        }
        guard let answer = PreparedCardSpokenStack.Answer.parse(text) else {
            self.reading = nil
            return false
        }
        let step = reading.answer(answer)
        self.reading = step.awaiting ? reading : nil
        var lines: [String] = []
        if let effect = step.effect, let line = await perform(effect) { lines.append(line) }
        if let say = step.say { lines.append(say) }
        if !lines.isEmpty { await say(lines.joined(separator: " "), pushed: false) }
        return true
    }

    /// The reading ends (the conversation closed, or something else took over).
    func end() { reading = nil }

    // MARK: - Pieces

    /// Runs an effect on the live card. A card that has gone since it was read is skipped.
    private func perform(_ effect: PreparedCardSpokenStack.Effect) async -> String? {
        let live = cards()
        func card(_ id: PreparedCardID) -> PreparedCard? { live.first { $0.id == id } }
        switch effect {
        case .stage(let id):
            guard let card = card(id) else { return nil }
            return PreparedCardPhraser.staged(await stage(card))
        case .later(let id):
            if let card = card(id) { later(card) }
        case .notUseful(let id):
            if let card = card(id) { notUseful(card) }
        case .dismiss(let id):
            if let card = card(id) { dismiss(card) }
        }
        return nil
    }

    private func say(_ text: String, pushed: Bool) async {
        guard !text.isEmpty else { return }
        await voice(text, pushed ? .alert : .phoneAnswer)
        // The answer window starts when the line has been said, not when it was handed over.
        reading?.noteSpoke(at: now())
    }
}
