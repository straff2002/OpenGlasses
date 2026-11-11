import Foundation

// Plan KT P1 — the cards on the phone. `MyDayService` gathers My Day as it always has; this turns
// that gathering, plus the facts only the cards read (where the wearer is, who is at an event, last
// night's sleep, the latest meeting summary, the job day), into the `TodayFeed` every surface reads,
// and applies what the wearer did with each card through `PreparedCardStore`.

/// What the cards read beyond My Day's own inputs. Gathered once per refresh by a
/// `PreparedCardContextSource`; every field may be absent.
struct PreparedCardContext: Equatable {
    var travelDistanceMeters: Double?
    var destinationWeather: [CardWeatherHour] = []
    var here: CardPlace?
    var contacts: [String: CardContact] = [:]
    var sleep: SleepNight?
    var meeting: MeetingSummaryFacts?
    var jobs: CardJobFacts?
    var wearer = CardWearer()

    static let empty = PreparedCardContext()

    func cardInputs(myDay: MyDayInputs) -> CardInputs {
        CardInputs(myDay: myDay, travelDistanceMeters: travelDistanceMeters,
                   destinationWeather: destinationWeather, here: here, contacts: contacts, sleep: sleep,
                   meeting: meeting, jobs: jobs, wearer: wearer)
    }
}

@MainActor
protocol PreparedCardContextSource: AnyObject {
    /// Everything but the job day, which changes on its own clock (`jobFacts()`).
    func context(for inputs: MyDayInputs, settings: PreparedCardSettings, now: Date) async -> PreparedCardContext
    /// The job day's facts now, or nil when Field Assist is off.
    func jobFacts(now: Date) -> CardJobFacts?
    /// Whether Field Assist is on, so job kinds rank first.
    var isFieldAssistDay: Bool { get }
    /// Whether Health is on for this app, which short night needs.
    var healthAvailable: Bool { get }
}

/// The feed, and what the page needs beside it.
struct PreparedCardFeed: Equatable {
    var feed: TodayFeed
    /// Cards whose kept edit started from a draft the rebuild has changed: "Times changed —
    /// update draft?" (§5.4), with the new draft to update to.
    var changedDrafts: [PreparedCardID: String] = [:]
    /// The kind the last "not useful" turned off, said once on the page with Undo.
    var turnedOffKind: PreparedCardKind?

    static let empty = PreparedCardFeed(feed: .empty)

    /// Rows only: what the page is with the cards off.
    static func rowsOnly(_ snapshot: MyDaySnapshot) -> PreparedCardFeed {
        PreparedCardFeed(feed: TodayFeed(cards: [], rows: snapshot.items, overflow: snapshot.overflowItems,
                                         absorbed: []))
    }
}

@MainActor
final class PreparedCardFeedBuilder {

    let store: PreparedCardStore
    private let metrics: any PreparedCardMetricsRecording
    private let calendar: () -> Calendar
    private let locale: Locale
    private weak var contextSource: (any PreparedCardContextSource)?
    /// Whether the cards are on at all: My Day on, and its cards switch on (decision 7).
    var isEnabled: () -> Bool
    var settings: (_ isFieldAssistDay: Bool, _ healthAvailable: Bool) -> PreparedCardSettings

    /// The last gathering, so a change of state or of the job day re-joins without reloading
    /// Calendar, Reminders, weather and travel.
    private var lastInputs: MyDayInputs?
    private var lastItems: [MyDayItem] = []
    private var lastContext = PreparedCardContext.empty
    private var built: Set<String> = []
    private var shown: Set<String> = []
    private var turnedOffKind: PreparedCardKind?
    /// Each card's draft as its rule wrote it on the last join, before any edit — what an edit
    /// is measured against.
    private(set) var baseDrafts: [PreparedCardID: String] = [:]

    init(store: PreparedCardStore,
         metrics: any PreparedCardMetricsRecording = PreparedCardMetricsStore.shared,
         contextSource: (any PreparedCardContextSource)?,
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
         locale: Locale = .autoupdatingCurrent,
         isEnabled: @escaping () -> Bool = { Config.myDayEnabled && Config.preparedCardsEnabled },
         settings: @escaping (Bool, Bool) -> PreparedCardSettings = { PreparedCardSettings.current(isFieldAssistDay: $0, healthAvailable: $1) }) {
        self.store = store
        self.metrics = metrics
        self.contextSource = contextSource
        self.calendar = calendar
        self.locale = locale
        self.isEnabled = isEnabled
        self.settings = settings
    }

    private var currentSettings: PreparedCardSettings {
        settings(contextSource?.isFieldAssistDay ?? false, contextSource?.healthAvailable ?? false)
    }

    /// A refresh: gather the cards' own facts, then join.
    func build(inputs: MyDayInputs, snapshot: MyDaySnapshot, now: Date) async -> PreparedCardFeed {
        lastInputs = inputs
        lastItems = snapshot.allItems
        guard isEnabled() else { return .rowsOnly(snapshot) }
        let settings = currentSettings
        if let contextSource {
            lastContext = await contextSource.context(for: inputs, settings: settings, now: now)
        }
        return join(now: now, settings: settings)
    }

    /// Re-join the last gathering against the store and the job day as they are now.
    func rejoin(now: Date) -> PreparedCardFeed? {
        guard lastInputs != nil else { return nil }
        guard isEnabled() else {
            return PreparedCardFeed(feed: TodayFeed(cards: [], rows: Array(lastItems.prefix(6)),
                                                    overflow: Array(lastItems.dropFirst(6)), absorbed: []))
        }
        return join(now: now, settings: currentSettings)
    }

    private func join(now: Date, settings: PreparedCardSettings) -> PreparedCardFeed {
        guard let inputs = lastInputs else { return .empty }
        store.prune(now: now)
        var context = lastContext
        context.jobs = contextSource?.jobFacts(now: now) ?? context.jobs
        let rules = PreparedCardRules(calendar: calendar(), locale: locale)
        var ruled = rules.cards(from: context.cardInputs(myDay: inputs), now: now, settings: settings)
        #if DEBUG
        if let seededRuled { ruled = seededRuled }
        #endif
        for entry in ruled where built.insert(entry.card.id.rawValue).inserted {
            metrics.record(.card(entry.card.kind, .built))
        }
        let memory = store.memory
        let feed = PreparedCardJoiner(calendar: calendar(), locale: locale)
            .join(ruled, items: lastItems, memory: memory, now: now, isFieldAssistDay: settings.isFieldAssistDay)

        var changed: [PreparedCardID: String] = [:]
        let fresh = Dictionary(ruled.map { ($0.card.id, $0.card.draft?.text) }, uniquingKeysWith: { first, _ in first })
        baseDrafts = fresh.compactMapValues { $0 }
        for card in feed.cards {
            guard let entry = store.entry(for: card.id), entry.memory.editedText != nil,
                  let base = entry.editedFrom, let newText = fresh[card.id] ?? nil, newText != base else { continue }
            changed[card.id] = newText
        }
        return PreparedCardFeed(feed: feed, changedDrafts: changed, turnedOffKind: turnedOffKind)
    }

    #if DEBUG
    /// UI-test seeding only (`UITestSupport`): cards as rules would have built them, so the page
    /// can be driven without a calendar. Every change still goes through the real store and joiner.
    private var seededRuled: [RuledCard]?

    func seedForUITest(_ ruled: [RuledCard], items: [MyDayItem]) {
        seededRuled = ruled
        lastInputs = MyDayInputs(events: [], reminders: [], weather: nil, sourceStates: [])
        lastItems = items
    }
    #endif

    // MARK: - What the wearer did

    /// The page drew these cards.
    func noteShown(_ cards: [PreparedCard], now: Date) {
        for card in cards where shown.insert(card.id.rawValue).inserted {
            metrics.record(.card(card.kind, .shown))
            if let draft = card.draft { metrics.record(.draftOrigin(PreparedCardDraftOriginMetric(draft.origin))) }
        }
        store.markSeen(cards, now: now)
    }

    func noteOpened(_ card: PreparedCard) { metrics.record(.card(card.kind, .opened)) }

    func later(_ card: PreparedCard, until: Date, now: Date) {
        metrics.record(.card(card.kind, .later))
        store.record(.later(until: until), for: card, now: now)
    }

    func dismiss(_ card: PreparedCard, now: Date) {
        metrics.record(.card(card.kind, .dismissed))
        store.record(.dismissed, for: card, now: now)
    }

    func done(_ card: PreparedCard, now: Date) {
        store.record(.done, for: card, now: now)
    }

    func undo(_ id: PreparedCardID, now: Date) {
        store.restore(id, now: now)
    }

    /// "Not useful": the third on one kind in 14 days turns the kind off and says so once.
    func notUseful(_ card: PreparedCard, now: Date) {
        metrics.record(.card(card.kind, .notUseful))
        if store.notUseful(card, now: now) {
            Config.setPreparedCardKind(card.kind, enabled: false)
            turnedOffKind = card.kind
        }
    }

    /// Undo on "turned off".
    func undoTurnOff(_ kind: PreparedCardKind) {
        Config.setPreparedCardKind(kind, enabled: true)
        store.clearNotUseful(kind)
        if turnedOffKind == kind { turnedOffKind = nil }
    }

    func dismissTurnOffNotice() { turnedOffKind = nil }

    /// The draft as the wearer edited it, kept until the card ends (§5.4).
    func edit(_ card: PreparedCard, text: String, now: Date) {
        guard let base = baseDrafts[card.id] ?? card.draft?.text else { return }
        let wasEdited = store.entry(for: card.id)?.memory.editedText != nil
        store.setEdit(text, base: base, for: card, now: now)
        if !wasEdited, store.entry(for: card.id)?.memory.editedText != nil {
            metrics.record(.card(card.kind, .draftEdited))
        }
    }

    func updateDraft(_ id: PreparedCardID, now: Date) { store.dropEdit(for: id, now: now) }

    func keepEdit(_ id: PreparedCardID, newBase: String, now: Date) {
        store.keepEdit(for: id, newBase: newBase, now: now)
    }

    /// What a composer said. Sent closes the card; cancelled leaves it fresh with its edit; a
    /// route with no result leaves it "Opened in…" with Done and Not sent.
    func handedOff(_ card: PreparedCard, result: PreparedCardState.HandOffResult, now: Date) {
        metrics.record(.card(card.kind, .handedOff))
        switch result {
        case .sent:
            metrics.record(.card(card.kind, .sent))
            store.record(.handedOff(at: now, result: .sent), for: card, now: now)
        case .cancelled:
            store.record(.fresh, for: card, now: now)
        case .unknown:
            store.record(.handedOff(at: now, result: .unknown), for: card, now: now)
        }
    }

    /// "Not sent" on a hand-off with no result: back to fresh.
    func notSent(_ card: PreparedCard, now: Date) {
        store.record(.fresh, for: card, now: now)
    }
}
