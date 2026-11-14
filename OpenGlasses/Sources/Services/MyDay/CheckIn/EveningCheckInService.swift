import Foundation

/// The Evening Check-in, wired (Plan LE P1): its readers, tonight's dismissals and what it has
/// said today, and the three ways it is reached — at its time (`MyDayScheduledDeliveryService`),
/// asked for (`activity` action `waiting`) and on My Day's **Waiting on you** section.
///
/// Nothing here calls a model or leaves the phone (decisions 7 and 8). Every reader is read fresh
/// each time (Risks: "never from a cache filled earlier in the day"); `latest` is only what the
/// phone shows until the next read.
@MainActor
final class EveningCheckInService: ObservableObject {

    /// The list as it was last read, for the My Day section.
    @Published private(set) var latest: OpenLoopCollection = .empty
    /// When `latest` was read: the watch's line belongs to that day only (P2).
    private(set) var latestAt: Date?
    /// What the scheduled check-in last delivered, for the card on the lens (P2).
    private(set) var lastDelivered: OpenLoopCollection?
    /// "Want to deal with the first one now?", asked and not yet answered (P2, `CheckInOffer`).
    private(set) var pendingOffer: CheckInOffer?

    private(set) var readers: [OpenLoopSourceReading]
    let store: OpenLoopDismissalStore
    var fieldAssistOn: @MainActor () -> Bool = { Config.fieldAssistActive }
    var settings: @MainActor () -> MyDayDeliverySettings = { .current }
    var calendar: @MainActor () -> Calendar = { .autoupdatingCurrent }

    // MARK: The offer's seams (P2) — the router's held calls in the app, fakes in the tests.

    /// The hold key of a held trail entry.
    var holdKey: @MainActor (UUID) -> String? = { _ in nil }
    /// Whether the router still keeps the held call for a key.
    var canReplay: @MainActor (String) -> Bool = { _ in false }
    /// Put the held call back through its own confirmation; its outcome's words, or nil when it is
    /// no longer kept.
    var replay: @MainActor (String) async -> String? = { _ in nil }
    /// Whether the scheduled check-in may end with the offer: only where a yes can reach the model
    /// that calls `deal_with_first` (Direct mode).
    var offersAfterScheduled: @MainActor () -> Bool = { false }

    init(readers: [OpenLoopSourceReading] = [], store: OpenLoopDismissalStore = OpenLoopDismissalStore()) {
        self.readers = readers
        self.store = store
    }

    /// Add a reader, replacing any that answers for the same sources — AppState installs the
    /// readers over its own services after the registry made the personal ones.
    func install(_ reader: OpenLoopSourceReading) {
        let answered = Set(reader.sources)
        readers.removeAll { !answered.isDisjoint(with: $0.sources) }
        readers.append(reader)
    }

    // MARK: Reading

    private typealias Readings = [(sources: [OpenLoopSource], reading: OpenLoopReading)]

    /// Every reader, read now.
    private func read(now: Date) async -> Readings {
        var readings: Readings = []
        let cal = calendar()
        for reader in readers {
            readings.append((reader.sources, await reader.readOpenLoops(now: now, calendar: cal)))
        }
        return readings
    }

    /// Everything still waiting on the wearer, less what they cleared tonight: what "what's
    /// waiting on me?" says and what My Day shows.
    @discardableResult
    func collect(now: Date = Date()) async -> OpenLoopCollection {
        let collection = OpenLoopCollector.collect(readings: await read(now: now),
                                                   dismissed: store.dismissed(on: now),
                                                   now: now, calendar: calendar())
        latest = collection
        latestAt = now
        return collection
    }

    /// Whether `now` is at or after today's check-in time (the wearer's, else the default).
    func isAfterCheckInTime(_ now: Date) -> Bool {
        let parts = calendar().dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= settings().resolvedCheckInMinutes
    }

    // MARK: Saying it

    /// The scheduled check-in's words, or nil when there is nothing to say (decision 4): the list
    /// less tonight's dismissals and less what was already said today. Every loop delivered —
    /// spoken or left on the phone — is marked said today.
    ///
    /// `mayOffer` (P2) is whether this delivery may end with "Want to deal with the first one now?":
    /// only when it is spoken and is the last thing said (not merged ahead of the evening briefing).
    func scheduledText(now: Date = Date(), mayOffer: Bool = false) async -> String? {
        let readings = await read(now: now)
        let dismissed = store.dismissed(on: now)
        latest = OpenLoopCollector.collect(readings: readings, dismissed: dismissed, now: now,
                                           calendar: calendar())
        latestAt = now
        let unsaid = OpenLoopCollector.collect(readings: readings, dismissed: dismissed,
                                               said: store.said(on: now), now: now, calendar: calendar())
        let offer = mayOffer && offersAfterScheduled() ? self.offer(for: unsaid, now: now) : nil
        guard let phrase = OpenLoopPhraser.phrase(unsaid, channel: .scheduled,
                                                  fieldAssist: fieldAssistOn(), offerFirst: offer != nil) else {
            lastDelivered = nil
            return nil
        }
        store.markSaid(unsaid.loops, on: now)
        lastDelivered = unsaid
        pendingOffer = phrase.offersFirst ? offer : nil
        return phrase.text
    }

    /// The answer to "what's waiting on me?". Asked after the check-in time, it is the check-in, so
    /// what it names is marked said today and the scheduled one does not say it again.
    func askedText(now: Date = Date()) async -> String {
        let collection = await collect(now: now)
        // P2: asked for, the check-in is a model turn, so the offer is in the model's own reply and
        // a yes reaches `deal_with_first` in any mode.
        let offer = self.offer(for: collection, now: now)
        let phrase = OpenLoopPhraser.phrase(collection, channel: .asked, fieldAssist: fieldAssistOn(),
                                            offerFirst: offer != nil)
        pendingOffer = phrase?.offersFirst == true ? offer : nil
        if isAfterCheckInTime(now) { store.markSaid(collection.loops, on: now) }
        return phrase?.text ?? String(localized: "Nothing is waiting on you.",
                                      comment: "Spoken: the evening check-in, asked for, found nothing waiting on the wearer.")
    }

    // MARK: The offer (P2)

    private func offer(for collection: OpenLoopCollection, now: Date) -> CheckInOffer? {
        CheckInOfferPolicy.offer(for: collection, now: now, holdKey: holdKey, canReplay: canReplay)
    }

    /// The wearer said yes to "Want to deal with the first one now?" (`activity` `deal_with_first`).
    /// Takes the offer — once, whatever happens next — and puts its held call back through the
    /// call's own confirmation. Approves nothing itself.
    func dealWithFirst(now: Date = Date()) async -> String {
        let take = CheckInOfferPolicy.take(pendingOffer, now: now)
        pendingOffer = nil
        guard case .replay(let key) = take else { return CheckInOfferPolicy.nothingOffered }
        guard canReplay(key), let words = await replay(key) else { return CheckInOfferPolicy.cannotPutBack }
        return words
    }

    /// The note a Direct-mode turn carries while an offer is live; nil otherwise.
    func offerTurnNote(now: Date = Date()) -> String? {
        if let offer = pendingOffer, !offer.isLive(at: now) { pendingOffer = nil }
        return CheckInOfferPolicy.turnNote(pendingOffer, now: now)
    }

    // MARK: Acting

    /// Clear one loop from tonight's check-in. It comes back tomorrow, or tonight if it changes.
    func dismiss(_ loop: OpenLoop, now: Date = Date()) {
        store.dismiss(loop, on: now)
        latest = OpenLoopCollection(loops: latest.loops.filter { $0.id != loop.id },
                                    unavailable: latest.unavailable)
    }
}
