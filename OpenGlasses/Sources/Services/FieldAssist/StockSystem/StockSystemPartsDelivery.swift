import Foundation

/// Where one noted line stands on its way to a business's own stock system (Plan MM P4).
///
/// The states are the work record's (`van_stock[].delivery`): noted and waiting for a person,
/// queued, sent, kept on the phone with a reason (`not_sent`), or waiting for a person to look
/// (`needs_attention`). Vendor-neutral: the reason is a code and the sentence names the system.
struct StockSystemLineDelivery: Codable, Equatable, Sendable {

    enum State: String, Codable, CaseIterable, Sendable {
        /// Noted on the phone, waiting for a person to confirm the batch.
        case staged
        /// Confirmed by a person and waiting on the queue.
        case queued
        /// The system shows the write as applied.
        case sent
        /// Kept on the phone and on the record, with `reason`: the system doesn't carry it, sending
        /// is off, the office posts stock, it was discarded, and so on. Never sent.
        case notSent = "not_sent"
        /// The system refused it, or shows a different write under its key: nothing more is sent
        /// for it until a person looks.
        case needsAttention = "needs_attention"
    }

    var state: State
    /// The reason code for `notSent` and `needsAttention` (`StockSystemNotSentReason`, or a
    /// failure's `StockSystemFailure.code`); nil otherwise.
    var reason: String?
    /// What the person is told, naming the system; nil for `staged`.
    var sentence: String?
    /// The queued batch that carries the line, once confirmed.
    var batchID: String?
    /// When the line last changed state; nil for a line only noted.
    var changedAt: Date?

    init(state: State, reason: String? = nil, sentence: String? = nil, batchID: String? = nil, changedAt: Date? = nil) {
        self.state = state
        self.reason = reason
        self.sentence = sentence
        self.batchID = batchID
        self.changedAt = changedAt
    }

    static let staged = StockSystemLineDelivery(state: .staged)

    /// Nothing more will happen to it on its own: sent, or kept on the phone for good.
    var isSettled: Bool { state == .sent || state == .notSent }

    /// The system's figure does not yet show it, or will not until the next pull.
    var isOnItsWay: Bool { state == .queued }
}

/// Why a line is kept on the phone and not sent, beyond the write plan's own reasons
/// (`PartsUsedWritePlan.NotSentReason`). The codes are the record's `deliveryReason`.
enum StockSystemNotSentReason: String, CaseIterable, Sendable {
    /// Sending back is off in Settings or in the organisation's profile.
    case sendingOff = "sending_off"
    /// Medical Local Only holds the system's route.
    case localOnly = "local_only"
    /// The organisation's office posts stock now (`organizationFieldServiceRoute = office`).
    case officeRoute = "office_route"
    /// The connection was removed, or is not on this phone.
    case disconnected
    /// A person chose not to send it.
    case discarded

    func sentence(system: String) -> String {
        switch self {
        case .sendingOff:
            return "Sending back to \(system) is off, so not sent. It stays on the job's record."
        case .localOnly:
            return "Medical Local Only keeps it on this phone, so not sent to \(system). It stays on the job's record."
        case .officeRoute:
            return "Your office posts stock to \(system) now, so not sent from this phone. It stays on the job's record "
                + "for the office to post."
        case .disconnected:
            return "\(system) was disconnected on this phone, so not sent. It stays on the job's record."
        case .discarded:
            return "Not sent to \(system): it was discarded on this phone. It stays on the job's record."
        }
    }
}

/// Whether sending parts to the system is offered at all (Plan MM §6, §7): only while the
/// connection runs, sending back is on, Medical Local Only does not hold the route and the office
/// does not post stock. Pure.
enum StockSystemSendOffer: Equatable, Sendable {
    case offered
    case notOffered(StockSystemNotSentReason)

    var isOffered: Bool { self == .offered }

    static func decide(officeRoute: Bool, connected: Bool, sendingBack: Bool, localOnly: Bool) -> StockSystemSendOffer {
        if officeRoute { return .notOffered(.officeRoute) }
        if !connected { return .notOffered(.disconnected) }
        if localOnly { return .notOffered(.localOnly) }
        if !sendingBack { return .notOffered(.sendingOff) }
        return .offered
    }
}

/// The one question a batch is put with (Plan MM §6): "Two parts used on this job: one Run
/// capacitor 45/5, half a litre of Coolant. Send them to <system>?" English, as van stock's
/// sentences are. Pure.
enum StockSystemPartsQuestion {

    static func question(_ entries: [StagedStockUseEntry], system: String, onJob: Bool) -> String {
        let count = entries.count
        let parts = count == 1 ? "part" : "parts"
        let lead = "\(StockPlaceWording.capitalised(numberWord(count))) \(parts) used \(onJob ? "on this job" : "today")"
        let list = entries.map(phrase).joined(separator: ", ")
        return "\(lead): \(list). Send \(count == 1 ? "it" : "them") to \(system)?"
    }

    /// "one Run capacitor 45/5", "half a litre of Coolant", "2.25 metres of Hose", "one Filter
    /// written off as damaged".
    static func phrase(_ entry: StagedStockUseEntry) -> String {
        let use = entry.use
        let described = use.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = described.isEmpty ? (use.part ?? "unnamed part") : described
        var phrase: String
        switch use.unit {
        case .each:
            phrase = use.quantity.isWhole ? "\(numberWord(use.quantity.scaled / StockQuantity.perUnit)) \(name)"
                                          : "\(use.quantity.decimalString) of \(name)"
        default:
            if use.quantity.scaled == StockQuantity.perUnit / 2 {
                phrase = "half a \(use.unit.singularWord) of \(name)"
            } else if use.quantity.isWhole, use.quantity.scaled / StockQuantity.perUnit <= 12 {
                let whole = use.quantity.scaled / StockQuantity.perUnit
                phrase = "\(numberWord(whole)) \(whole == 1 ? use.unit.singularWord : use.unit.pluralWord) of \(name)"
            } else {
                phrase = use.unit.spoken(use.quantity, of: name)
            }
        }
        if entry.reason != nil { phrase += " written off as damaged" }
        return phrase
    }

    static func numberWord(_ value: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve"]
        return (0..<words.count).contains(value) ? words[value] : String(value)
    }
}

/// The parts step's stepper for one line (Plan MM P4): how far one press moves the amount, and
/// the least and most it can be, from the line's unit and the system's `decimalPlaces` for the
/// item, so the stepper can never make an amount the system would refuse. Pure.
struct StockSystemQuantityStepper: Equatable, Sendable {
    /// The finest amount the item takes, in thousandths.
    let granule: Int
    /// One press, in thousandths: a whole one for a counted unit, a tenth for a measured one (or
    /// the item's finest, when coarser).
    let step: Int
    let minimum: StockQuantity
    let maximum: StockQuantity

    init(unit: VanStockUnit, decimalPlaces: Int?, wholeNumbersOnly: Bool = false) {
        let places: Int
        if wholeNumbersOnly || !unit.allowsFraction {
            places = 0
        } else {
            places = min(max(decimalPlaces ?? StockQuantity.scale, 0), StockQuantity.scale)
        }
        var granule = 1
        for _ in 0..<(StockQuantity.scale - places) { granule *= 10 }
        self.granule = max(granule, unit.step)
        step = max(self.granule, unit.allowsFraction && places > 0 ? StockQuantity.perUnit / 10 : StockQuantity.perUnit)
        minimum = StockQuantity(scaled: self.granule)
        maximum = StockQuantity(scaled: StockQuantity.maximumScaled - StockQuantity.maximumScaled % self.granule)
    }

    /// One press up, never past the most.
    func up(_ value: StockQuantity) -> StockQuantity {
        StockQuantity(scaled: min(value.scaled + step, maximum.scaled))
    }

    /// One press down, never below the least: a line is taken off with Discard, never stepped to 0.
    func down(_ value: StockQuantity) -> StockQuantity {
        StockQuantity(scaled: max(value.scaled - step, minimum.scaled))
    }

    /// Whether the amount is one the item can take.
    func accepts(_ value: StockQuantity) -> Bool {
        value >= minimum && value <= maximum && value.scaled % granule == 0
    }
}

/// What a job's row, and the parts step, say about its parts for the system (Plan MM P4): "Sent to
/// <system>", "Waiting for a connection", "Needs attention — …", "2 parts not sent to <system>"
/// (noted, not yet confirmed), and "1 not sent: …" per reason. Pure.
enum StockSystemJobRowState {

    static func lines(_ entries: [StagedStockUseEntry], system: String) -> [String] {
        guard !entries.isEmpty else { return [] }
        var lines: [String] = []
        let states = entries.map(\.delivery.state)
        if let attention = entries.first(where: { $0.delivery.state == .needsAttention }) {
            lines.append("Needs attention — " + (attention.delivery.sentence ?? "check the parts in \(system)."))
        } else if states.contains(.queued) {
            lines.append("Waiting for a connection")
        } else if states.contains(.sent), !states.contains(.staged) {
            lines.append("Sent to \(system)")
        }
        let waiting = entries.filter(\.isAwaitingConfirmation).count
        if waiting > 0 {
            lines.append("\(waiting) \(waiting == 1 ? "part" : "parts") not sent to \(system)")
        }
        // One line per reason, in the order the reasons first appear.
        var seen: [String] = []
        var counts: [String: (count: Int, sentence: String)] = [:]
        for entry in entries where entry.delivery.state == .notSent {
            let key = entry.delivery.reason ?? "not_sent"
            if counts[key] == nil { seen.append(key) }
            let sentence = entry.delivery.sentence.map(Self.reasonOnly) ?? "not sent"
            counts[key] = ((counts[key]?.count ?? 0) + 1, sentence)
        }
        for key in seen {
            if let entry = counts[key] { lines.append("\(entry.count) not sent: \(entry.sentence)") }
        }
        return lines
    }

    /// "Grease: not in X's catalogue, so not sent." → "not in X's catalogue, so not sent".
    static func reasonOnly(_ sentence: String) -> String {
        var text = sentence
        if let colon = text.range(of: ": ") { text = String(text[colon.upperBound...]) }
        if let stop = text.range(of: ". ") { text = String(text[..<stop.lowerBound]) }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// A job's parts for a business's own system, as the job and its record carry them (Plan MM P4):
/// which system, and each line with its item id and where it stands. Kept on the session so the
/// work record, built from the session alone, can say what went where.
struct StockSystemJobUses: Codable, Equatable, Sendable {
    let connectorID: String
    let displayName: String
    /// Each line as the record's `van_stock` line, with `itemID`, `delivery` and `deliveryReason`.
    let lines: [VanStockUse]

    /// The job's staged lines, as the record says them. Nil when the job noted none.
    init?(entries: [StagedStockUseEntry], displayName: String) {
        guard let first = entries.first else { return nil }
        connectorID = first.connectorID
        self.displayName = displayName
        lines = entries.map { entry in
            VanStockUse(id: entry.id, number: entry.use.part, description: entry.use.description,
                        quantity: entry.use.quantity, unit: entry.use.unit,
                        verified: entry.use.verification.state == .found, at: entry.stagedAt,
                        itemID: entry.use.itemID, delivery: entry.delivery.state,
                        deliveryReason: entry.delivery.state == .notSent || entry.delivery.state == .needsAttention
                            ? (entry.delivery.reason ?? entry.delivery.state.rawValue) : nil)
        }
    }
}
