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

    private(set) var readers: [OpenLoopSourceReading]
    let store: OpenLoopDismissalStore
    var fieldAssistOn: @MainActor () -> Bool = { Config.fieldAssistActive }
    var settings: @MainActor () -> MyDayDeliverySettings = { .current }
    var calendar: @MainActor () -> Calendar = { .autoupdatingCurrent }

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
    func scheduledText(now: Date = Date()) async -> String? {
        let readings = await read(now: now)
        let dismissed = store.dismissed(on: now)
        latest = OpenLoopCollector.collect(readings: readings, dismissed: dismissed, now: now,
                                           calendar: calendar())
        let unsaid = OpenLoopCollector.collect(readings: readings, dismissed: dismissed,
                                               said: store.said(on: now), now: now, calendar: calendar())
        guard let phrase = OpenLoopPhraser.phrase(unsaid, channel: .scheduled,
                                                  fieldAssist: fieldAssistOn(), offerFirst: false) else {
            return nil
        }
        store.markSaid(unsaid.loops, on: now)
        return phrase.text
    }

    /// The answer to "what's waiting on me?". Asked after the check-in time, it is the check-in, so
    /// what it names is marked said today and the scheduled one does not say it again.
    func askedText(now: Date = Date()) async -> String {
        let collection = await collect(now: now)
        let phrase = OpenLoopPhraser.phrase(collection, channel: .asked, fieldAssist: fieldAssistOn(),
                                            offerFirst: false)
        if isAfterCheckInTime(now) { store.markSaid(collection.loops, on: now) }
        return phrase?.text ?? String(localized: "Nothing is waiting on you.",
                                      comment: "Spoken: the evening check-in, asked for, found nothing waiting on the wearer.")
    }

    // MARK: Acting

    /// Clear one loop from tonight's check-in. It comes back tomorrow, or tonight if it changes.
    func dismiss(_ loop: OpenLoop, now: Date = Date()) {
        store.dismiss(loop, on: now)
        latest = OpenLoopCollection(loops: latest.loops.filter { $0.id != loop.id },
                                    unavailable: latest.unavailable)
    }
}
