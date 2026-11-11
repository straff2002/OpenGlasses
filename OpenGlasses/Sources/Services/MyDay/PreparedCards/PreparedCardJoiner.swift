import Foundation

// Plan KT §3 — the rules' cards and My Day's rows become one feed: weather and location chips
// added, the wearer's state applied, expired cards dropped, cards ranked and capped, and the rows a
// card replaces taken off the page. `TodayFeed` is what every surface reads; nothing re-ranks
// downstream.

/// What happened to a card, kept per card id (§3.5). The store that holds it is P1's; the joiner
/// only reads it.
enum PreparedCardState: Codable, Equatable, Sendable {
    enum HandOffResult: String, Codable, Equatable, Sendable {
        /// The platform composer reported a send: the card closes.
        case sent
        /// The composer was cancelled: the card stays.
        case cancelled
        /// No result is given (WhatsApp, `mailto:`): the card stays, saying where it went.
        case unknown
    }

    case fresh
    case seen
    case later(until: Date)
    case handedOff(at: Date, result: HandOffResult)
    case done
    case dismissed
    case notUseful
    /// Plan KT §6.4: the Display, the watch or the voice put the card's draft on the phone to send
    /// ("Send on phone"). It stays on the page, ready, until the composer says sent or the card
    /// ends at `validUntil`. The draft it was staged with is held in memory only.
    case staged(at: Date)

    /// Whether a card in this state is on the page at `now`.
    func isShown(at now: Date) -> Bool {
        switch self {
        case .fresh, .seen, .staged: true
        case .later(let until): now >= until
        case .handedOff(_, let result): result != .sent
        case .done, .dismissed, .notUseful: false
        }
    }
}

/// Everything kept about one card: its state, the wearer's edit of its draft, and when either
/// last changed. No chips, no facts.
struct PreparedCardMemory: Codable, Equatable, Sendable {
    var state: PreparedCardState
    var editedText: String?
    var changedAt: Date

    init(state: PreparedCardState = .fresh, editedText: String? = nil, changedAt: Date) {
        self.state = state
        self.editedText = editedText
        self.changedAt = changedAt
    }
}

/// The joined day.
struct TodayFeed: Equatable {
    /// Ranked, capped at `PreparedCardJoiner.pageCardLimit`.
    let cards: [PreparedCard]
    /// My Day's rows the cards did not replace, capped as My Day caps them.
    let rows: [MyDayItem]
    /// The rows past the cap, still ranked.
    let overflow: [MyDayItem]
    /// Every row the shown cards replace — My Day's and the job day's — so the job day can drop its
    /// own copy of a "Report not sent".
    let absorbed: Set<CardRowID>

    /// The home card's one card (§3.4).
    var topCard: PreparedCard? { cards.first }
    /// "N more ready" on the home card.
    var moreReadyCount: Int { max(0, cards.count - 1) }

    static let empty = TodayFeed(cards: [], rows: [], overflow: [], absorbed: [])
}

struct PreparedCardJoiner {
    /// Cards on the My Day page before its rows.
    static let pageCardLimit = 6
    /// Short night: at most one a day.
    static let shortNightLimit = 1
    /// Weather joins as a chip when the destination's forecast has at least this chance of rain…
    static let rainChance = 0.4
    /// …or a temperature below this.
    static let coldCelsius = 5.0
    /// My Day's weather row, absorbed when a card took its chip from the weather.
    static let weatherRow = CardRowID(MyDayItemID(source: .weather, rawValue: "current"))

    let calendar: Calendar
    let locale: Locale
    /// My Day's own cap on rows.
    let maxRows: Int

    init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent, maxRows: Int = 6) {
        self.calendar = calendar
        self.locale = locale
        self.maxRows = max(1, maxRows)
    }

    func join(_ ruled: [RuledCard], items: [MyDayItem], memory: [PreparedCardID: PreparedCardMemory] = [:],
              now: Date, isFieldAssistDay: Bool = false) -> TodayFeed {
        var cards: [PreparedCard] = []
        var seen: Set<PreparedCardID> = []
        for entry in ruled {
            var card = entry.card
            // One card per id: a rule never makes two, but two rules' inputs could overlap.
            guard seen.insert(card.id).inserted else { continue }
            guard card.validUntil > now else { continue }
            if let kept = memory[card.id] {
                guard kept.state.isShown(at: now) else { continue }
                if let edited = kept.editedText, card.draft != nil { card.draft?.text = edited }
            }
            attachWeather(to: &card, window: entry.weatherWindow, hours: entry.weatherHours)
            if card.kind == .leaveBy, let place = entry.place { attachLocation(to: &card, place: place) }
            cards.append(card)
        }

        cards.sort { rankedBefore($0, $1, isFieldAssistDay: isFieldAssistDay) }
        var shortNights = 0
        cards = cards.filter { card in
            guard card.kind == .shortNight else { return true }
            shortNights += 1
            return shortNights <= Self.shortNightLimit
        }
        cards = Array(cards.prefix(Self.pageCardLimit))

        let absorbed = Set(cards.flatMap(\.absorbs))
        let surviving = items.filter { !absorbed.contains(CardRowID($0.id)) }
        return TodayFeed(cards: cards,
                         rows: Array(surviving.prefix(maxRows)),
                         overflow: Array(surviving.dropFirst(maxRows)),
                         absorbed: absorbed)
    }

    /// §3.2: urgency, then due time (none last), then kind (job kinds first on a Field Assist
    /// day), then id.
    func rankedBefore(_ lhs: PreparedCard, _ rhs: PreparedCard, isFieldAssistDay: Bool) -> Bool {
        if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
        if lhs.dueAt != rhs.dueAt { return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture) }
        if lhs.kind.isJobKind != rhs.kind.isJobKind { return isFieldAssistDay == lhs.kind.isJobKind }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.id < rhs.id
    }

    // MARK: - Chips

    /// Rain (≥ 40 %) or cold (< 5 °C) at the destination during the window: a chip and a fact
    /// ("Rain from 18:00 · take a coat"), and the weather row is absorbed.
    func attachWeather(to card: inout PreparedCard, window: DateInterval?, hours: [CardWeatherHour]) {
        guard let window else { return }
        let during = hours
            .filter { $0.start < window.end && $0.start.addingTimeInterval(3600) > window.start }
            .sorted { $0.start < $1.start }
        guard !during.isEmpty else { return }

        let chip: String
        let fact: String
        if let wet = during.first(where: { $0.precipitationChance >= Self.rainChance }) {
            let from = time(wet.start)
            chip = String(localized: "Rain from \(from)")
            fact = String(localized: "Rain from \(from) · take a coat")
        } else if let coldest = during.min(by: { $0.temperatureCelsius < $1.temperatureCelsius }),
                  coldest.temperatureCelsius < Self.coldCelsius {
            let temperature = temperatureText(coldest.temperatureCelsius)
            chip = String(localized: "Cold, \(temperature)")
            fact = String(localized: "\(temperature) · take a coat")
        } else {
            return
        }
        if card.signals.count < PreparedCard.maximumSignals {
            card.signals.append(CardSignal(source: .weather, text: chip))
        }
        if card.facts.count < PreparedCard.maximumFacts {
            card.facts.append(CardFact(label: String(localized: "Weather"), value: fact))
        }
        if !card.absorbs.contains(Self.weatherRow) { card.absorbs.append(Self.weatherRow) }
    }

    /// "You're in Te Aro", else "Near 14 Example Street"; nothing when neither fits a chip. It
    /// never makes a card on its own.
    func attachLocation(to card: inout PreparedCard, place: CardPlace) {
        guard card.signals.count < PreparedCard.maximumSignals,
              let text = Self.locationChipText(place) else { return }
        // Before the weather chip, as the catalogue lists them.
        let index = card.signals.firstIndex { $0.source == .weather } ?? card.signals.endIndex
        card.signals.insert(CardSignal(source: .location, text: text), at: index)
    }

    static func locationChipText(_ place: CardPlace) -> String? {
        let candidates = [
            place.subLocality.map { String(localized: "You're in \($0)") },
            place.street.map { String(localized: "Near \($0)") },
        ].compactMap { $0 }
        return candidates.first { $0.count <= CardSignal.maximumLength }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func temperatureText(_ celsius: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }
}

extension PreparedCardRules {
    /// The whole pipeline (§3.1) for a caller that has gathered everything: rules, then joiner.
    func todayFeed(from inputs: CardInputs, items: [MyDayItem], settings: PreparedCardSettings,
                   memory: [PreparedCardID: PreparedCardMemory] = [:], now: Date) -> TodayFeed {
        PreparedCardJoiner(calendar: calendar, locale: locale)
            .join(cards(from: inputs, now: now, settings: settings), items: items, memory: memory,
                  now: now, isFieldAssistDay: settings.isFieldAssistDay)
    }
}
