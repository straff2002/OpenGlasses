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
    /// Each card's draft as it was shown on the last join, before any edit — the rule's
    /// template, or the model's rewrite of it — what an edit is measured against.
    private(set) var baseDrafts: [PreparedCardID: String] = [:]

    // MARK: Drafts by a model (§4.2)

    /// Rewrites a card's template in the wearer's voice. Nil: templates only.
    var draftWriter: (any DraftWriting)?
    /// The style note the writer follows and the edit learner feeds.
    var styleStore: WritingStyleStore?
    /// A model's draft arrived: the feed should be re-joined.
    var onDraftsChanged: (() -> Void)?

    /// One model draft, kept in memory for the life of the process and never written down: the
    /// card store keeps only state and edits (§3.5).
    struct ModelDraft: Equatable {
        /// The template it was written from. A rebuild whose template changed (a later arrival)
        /// shows the new template rather than a rewrite of the old one.
        let template: String
        let result: DraftWriteResult
    }

    /// By card id. A card is asked for once: never again once a model was called for it.
    private(set) var modelDrafts: [PreparedCardID: ModelDraft] = [:]
    private var draftsAsked: Set<PreparedCardID> = []
    /// Templates as the rules last wrote them, for the writer.
    private var ruleDrafts: [PreparedCardID: String] = [:]
    /// Edits already counted by the style learner.
    private var learnedFrom: Set<PreparedCardID> = []
    /// Plan KT §6.4: the draft each staged card was staged with, so the phone opens what the lens
    /// showed. In memory only, like a model's draft: after a relaunch the card's draft as it is
    /// then (the template, or the wearer's kept edit) is what opens.
    private(set) var stagedTexts: [PreparedCardID: String] = [:]

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
        ruleDrafts = Dictionary(ruled.compactMap { entry in entry.card.draft.map { (entry.card.id, $0.text) } },
                                uniquingKeysWith: { first, _ in first })
        ruled = ruled.map(applyingModelDraft).map(applyingStagedDraft)
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

    // MARK: - Model drafts

    /// The rule's card with the model's draft in place of its template, when the model wrote one
    /// from this very template and the wearer has not started an edit from the template.
    private func applyingModelDraft(_ entry: RuledCard) -> RuledCard {
        guard let template = entry.card.draft?.text, let model = modelDrafts[entry.card.id],
              model.result.fallback == nil, model.template == template else { return entry }
        if let kept = store.entry(for: entry.card.id), kept.memory.editedText != nil,
           kept.editedFrom == template { return entry }
        var copy = entry
        copy.card.draft = copy.card.draft.map {
            PreparedDraft(channel: $0.channel, recipient: $0.recipient, subject: $0.subject,
                          text: model.result.text, origin: model.result.origin, language: $0.language)
        }
        return copy
    }

    /// A staged card keeps the draft it was staged with while it is staged; an edit on the phone
    /// still wins (the joiner applies it after).
    private func applyingStagedDraft(_ entry: RuledCard) -> RuledCard {
        guard let text = stagedTexts[entry.card.id], entry.card.draft != nil else { return entry }
        if case .staged? = store.entry(for: entry.card.id)?.memory.state {
            var copy = entry
            copy.card.draft?.text = text
            return copy
        }
        return entry
    }

    /// Ask for a model draft of each shown card that has a draft, once per card (§4.2): not for
    /// a card the wearer has already edited, and not again once a model has been called for it.
    /// A card no model could take yet (none ready, no consent) may be asked again next time.
    private func requestDrafts(for cards: [PreparedCard]) {
        guard let draftWriter else { return }
        for card in cards where card.draft != nil && !draftsAsked.contains(card.id) && modelDrafts[card.id] == nil {
            guard store.entry(for: card.id)?.memory.editedText == nil,
                  let template = ruleDrafts[card.id],
                  let request = DraftWriteRequest.make(card: card, template: template,
                                                       wearerName: lastContext.wearer.name,
                                                       meeting: lastContext.meeting) else { continue }
            draftsAsked.insert(card.id)
            let style = styleStore?.style ?? .standard
            Task { @MainActor [weak self] in
                let result = await draftWriter.write(request, style: style)
                self?.finishDraft(request, result: result)
            }
        }
    }

    private func finishDraft(_ request: DraftWriteRequest, result: DraftWriteResult) {
        if case .noRoute? = result.fallback {
            // Nothing was called: the card stays a simple draft, and may be asked again.
            draftsAsked.remove(request.cardId)
            metrics.record(.draftOrigin(.template))
            return
        }
        modelDrafts[request.cardId] = ModelDraft(template: request.template, result: result)
        metrics.record(.draftOrigin(PreparedCardDraftOriginMetric(result.origin)))
        if case .invalid(let failure)? = result.fallback { metrics.record(.validatorFallback(failure)) }
        if result.fallback == nil { onDraftsChanged?() }
    }

    // MARK: - What the wearer did

    /// The page drew these cards. Each one's draft is offered to a model the first time.
    func noteShown(_ cards: [PreparedCard], now: Date) {
        for card in cards where shown.insert(card.id.rawValue).inserted {
            metrics.record(.card(card.kind, .shown))
            if draftWriter == nil, let draft = card.draft {
                metrics.record(.draftOrigin(PreparedCardDraftOriginMetric(draft.origin)))
            }
        }
        store.markSeen(cards, now: now)
        requestDrafts(for: cards)
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
        stagedTexts[card.id] = nil
        if result != .cancelled { learnStyle(from: card) }
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

    /// §4.3: an edit the wearer handed off teaches the style learner, once per card. Counts only.
    private func learnStyle(from card: PreparedCard) {
        guard let styleStore, !learnedFrom.contains(card.id), let entry = store.entry(for: card.id),
              let after = entry.memory.editedText, let before = entry.editedFrom else { return }
        learnedFrom.insert(card.id)
        styleStore.learn(before: before, after: after)
    }

    /// Plan KT §6.4: "Send on phone" from the Display, the watch or the voice. The card is marked
    /// staged with the draft it showed, which the composer opens with.
    func stage(_ card: PreparedCard, now: Date) {
        guard let draft = card.draft else { return }
        metrics.record(.card(card.kind, .staged))
        stagedTexts[card.id] = draft.text
        store.record(.staged(at: now), for: card, now: now)
    }

    /// Plan KT §6.2: the card was shown on the Display unasked.
    func notePushed(_ card: PreparedCard) { metrics.record(.card(card.kind, .pushed)) }

    /// Plan KT §10: a press on the Display, by button.
    func noteLensPress(_ action: PreparedCardLensAction) {
        metrics.record(.lensPress(PreparedCardLensPressMetric(action)))
    }

    /// "Not sent" on a hand-off with no result: back to fresh.
    func notSent(_ card: PreparedCard, now: Date) {
        store.record(.fresh, for: card, now: now)
    }
}
