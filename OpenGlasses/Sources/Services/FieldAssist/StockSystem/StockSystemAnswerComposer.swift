import Foundation

/// What the assistant is told to say when a business's own system holds the count (Plan MM §5).
///
/// English, for the model, as van stock's sentences are (Plan IH P0). Every figure names the
/// system and its as-of time, and a snapshot older than `StockSystemPolicy.staleAfter` says its
/// age first. The figure is the system's, said as "in <system>" and never "counted". An unknown is
/// never a number. Every word about the place comes from `wording` (Plan MK §3).
///
/// Pure, with the clock and the calendar handed in, so the same snapshot always reads the same way.
struct StockSystemAnswerComposer {

    /// A use of the line on the open job that the system has not taken off yet.
    struct Unsent: Equatable, Sendable {
        enum State: Equatable, Sendable {
            /// Noted on the job, waiting for the person to confirm the job's parts.
            case staged
            /// Confirmed and queued, or sent since the figure was read: the system's figure does
            /// not show it yet (Plan MM P4).
            case sending
        }
        let quantity: StockQuantity
        let state: State
    }

    /// The `van_stock` actions a system-held place refuses (Plan MM §5).
    enum RefusedAction: Equatable, Sendable {
        case load
        case count
        case setStandard
        case topUp
        case undoLoad
    }

    var now: Date
    var calendar: Calendar = .current
    var wording = StockPlaceWording(.default)
    /// The system's name, as every sentence says it.
    let system: String

    private var w: StockPlaceWording { wording }

    // MARK: - Check

    /// The answer to "have we got one?" for a joined number. `here` is the system's locations that
    /// are this place (`StockAuthority.locationIDs`).
    func check(_ outcome: StockSystemJoin.Outcome, in snapshot: StockSystemSnapshot, here: [String],
               unsent: Unsent? = nil) -> String {
        check(outcome, in: snapshot, here: here, unsent: unsent.map { [$0] } ?? [])
    }

    /// The same, with every use of the line the system has not taken off yet: still being sent
    /// (queued, or sent since the figure was read), and noted and not yet confirmed (Plan MM P4).
    func check(_ outcome: StockSystemJoin.Outcome, in snapshot: StockSystemSnapshot, here: [String],
               unsent: [Unsent]) -> String {
        switch outcome {
        case .inBoth(let line, _):
            return check(line, in: snapshot, here: here, unsent: unsent)
        case .systemOnly(let line, let bookSearched):
            let answer = check(line, in: snapshot, here: here, unsent: unsent)
            guard bookSearched else { return answer }
            return answer + " It is stocked in \(system), but I can't check that number against the book."
        case .vaultOnly, .neither:
            return notCarried()
        }
    }

    /// A line's figure at this place, with where it came from and how old it is.
    func check(_ line: StockSystemSnapshot.Line, in snapshot: StockSystemSnapshot, here: [String],
               unsent: Unsent? = nil) -> String {
        check(line, in: snapshot, here: here, unsent: unsent.map { [$0] } ?? [])
    }

    func check(_ line: StockSystemSnapshot.Line, in snapshot: StockSystemSnapshot, here: [String],
               unsent: [Unsent]) -> String {
        let asOf = line.lineAsOf ?? snapshot.asOf
        let values = here.map { line.level(at: $0) ?? .unknown(.noCount) }
        let known = values.compactMap(\.quantity)

        guard !known.isEmpty else { return unknown(line, values: values) }

        let total = known.reduce(StockQuantity.zero, +)
        var lines: [String] = []
        let stale = now.timeIntervalSince(asOf) > StockSystemPolicy.staleAfter
        let figure = total == .zero ? "no \(line.name) \(w.location)" : "\(phrase(line, total)) \(w.location)"
        var lead: String
        if stale {
            lead = "As of \(time(asOf)), \(system) had \(figure)"
        } else {
            lead = "\(StockPlaceWording.capitalised(figure)) in \(system), as of \(time(asOf))"
        }
        if total == .zero, let elsewhere = elsewhere(line, in: snapshot, here: here) {
            lead += "; \(elsewhere)"
        }
        // What is on its way first, then what is only noted.
        for state in [Unsent.State.sending, .staged] {
            let quantity = unsent.filter { $0.state == state }.reduce(StockQuantity.zero) { $0 + $1.quantity }
            if quantity > .zero { lead += ", and " + unsentPhrase(line, Unsent(quantity: quantity, state: state)) }
        }
        lines.append(lead + ".")

        let missing = zip(here, values).filter { $0.1.quantity == nil }.map { snapshot.location($0.0)?.name ?? $0.0 }
        if !missing.isEmpty {
            lines.append("\(system) has no count for it at " + missing.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: " ")
    }

    /// The system lists the line but gives no figure this phone can hold.
    private func unknown(_ line: StockSystemSnapshot.Line, values: [StockSystemLevelValue]) -> String {
        var lines = ["\(system) lists \(line.name) but has no count for it."]
        let reasons = values.compactMap { value -> StockSystemUnknownReason? in
            if case .unknown(let reason) = value { return reason }
            return nil
        }
        if let reason = reasons.first(where: { $0 != .noCount }),
           let sentence = reason.sentence(system: system, unit: line.unit) {
            lines.append(sentence)
        }
        lines.append("Do not give a figure for it.")
        return lines.joined(separator: " ")
    }

    /// "2 at North Bay, 1 at Rear Shelf": the snapshot's other locations that hold some.
    private func elsewhere(_ line: StockSystemSnapshot.Line, in snapshot: StockSystemSnapshot, here: [String]) -> String? {
        let others = line.levels.compactMap { level -> String? in
            guard !here.contains(level.locationID), let quantity = level.value.quantity, quantity > .zero else { return nil }
            let name = snapshot.location(level.locationID)?.name ?? level.locationID
            return "\(figure(line, quantity)) at \(name)"
        }
        return others.isEmpty ? nil : others.joined(separator: ", ")
    }

    private func unsentPhrase(_ line: StockSystemSnapshot.Line, _ unsent: Unsent) -> String {
        let amount = figure(line, unsent.quantity)
        switch unsent.state {
        case .staged:
            return "\(amount) used on this job is noted and not yet sent to \(system)"
        case .sending:
            return "\(amount) used on this job is still being sent"
        }
    }

    /// "Fixture Till doesn't carry that number."
    func notCarried() -> String {
        "\(system) doesn't carry that number, so there is no figure for it. Do not look it up again under another name "
            + "unless \(w.person) gives one."
    }

    /// The system holds the count and no figures from it are on the phone yet.
    func noFigures() -> String {
        "Stock \(w.location) is kept in \(system), and no figures from \(system) are on this phone yet, so there is "
            + "no figure to give. Do not guess one; \(StockPlaceWording.capitalised(w.person)) can open \(w.screen) "
            + "with signal to read them."
    }

    /// Several of the system's lines fit what was said: they are asked about, never picked.
    func candidates(_ lines: [StockSystemSnapshot.Line]) -> String {
        "More than one line in \(system) fits that: " + lines.prefix(6).map(\.name).joined(separator: "; ")
            + ". Ask \(w.person) which one they mean."
    }

    /// The opening of a sentence about the snapshot's age: "In Fixture Till, as of 09:10" or, once
    /// stale, "As of yesterday at 16:10, in Fixture Till".
    private func asOfLead(_ snapshot: StockSystemSnapshot) -> String {
        let stale = now.timeIntervalSince(snapshot.asOf) > StockSystemPolicy.staleAfter
        return stale ? "As of \(time(snapshot.asOf)), in \(system)" : "In \(system), as of \(time(snapshot.asOf))"
    }

    // MARK: - Low

    /// The lines at or below the system's own reorder point, where it has one, and otherwise the
    /// lines at nothing, as the system's figures with the as-of time. A line with no figure is
    /// never counted as low or as not low: it is named as having no count.
    func low(in snapshot: StockSystemSnapshot, here: [String]) -> String {
        var short: [String] = []
        var unknown: [String] = []
        for line in snapshot.lines {
            let values = here.map { line.level(at: $0) ?? .unknown(.noCount) }
            let known = values.compactMap(\.quantity)
            guard !known.isEmpty else {
                unknown.append(line.name)
                continue
            }
            let total = known.reduce(StockQuantity.zero, +)
            if let point = line.reorderPoint {
                if total <= point { short.append("\(figure(line, total)) \(line.name) (reorder at \(figure(line, point)))") }
            } else if total == .zero {
                short.append("none of \(line.name)")
            }
        }
        var lines: [String] = []
        if short.isEmpty {
            lines.append("\(asOfLead(snapshot)), nothing \(w.location) is at its reorder point or at none.")
        } else {
            lines.append("\(asOfLead(snapshot)), at or below its reorder point or at none: "
                + short.joined(separator: "; ") + ".")
        }
        if !unknown.isEmpty {
            lines.append(unknown.count == 1
                ? "\(system) has no count for 1 line, so it is not in this answer."
                : "\(system) has no count for \(unknown.count) lines, so they are not in this answer.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - List

    /// What the system holds for the place, as its figures with the as-of time. At most `limit`
    /// lines are read out. The system's figures carry no bins on the phone.
    func list(_ snapshot: StockSystemSnapshot, here: [String], bin: String?, limit: Int = 30) -> String {
        guard !snapshot.lines.isEmpty else {
            return "\(asOfLead(snapshot)), there are no tracked lines \(w.location)."
        }
        let read = snapshot.lines.prefix(limit).map { line -> String in
            let known = here.compactMap { line.level(at: $0)?.quantity }
            guard !known.isEmpty else { return "\(line.name): no count" }
            return "\(line.name): \(figure(line, known.reduce(StockQuantity.zero, +)))"
        }
        var answer = "\(asOfLead(snapshot)), \(w.location): " + read.joined(separator: "; ") + "."
        if snapshot.lines.count > limit { answer += " And \(snapshot.lines.count - limit) more lines." }
        if let bin, !bin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answer = "\(system)'s figures carry no bins on the phone, so this is everything. " + answer
        }
        return answer
    }

    // MARK: - Use

    /// A use noted on the open job, and what happens next.
    func staged(_ quantity: StockQuantity, of line: StockSystemSnapshot.Line, jobReference: String?) -> String {
        let job = jobReference.map { "job \($0)" } ?? "this job"
        return "I've noted \(phrase(line, quantity)) used on \(job). It goes to \(system) when \(w.person) confirms "
            + "the job's parts, and \(system)'s count does not change until then."
    }

    /// A use noted on the day's list for a place with no job open (premises).
    func stagedForToday(_ quantity: StockQuantity, of line: StockSystemSnapshot.Line) -> String {
        // "Used", never "sold": the till records a sale, and the phone never does (Decision 7).
        "I've noted \(phrase(line, quantity)) used today. It goes to \(system) when \(w.person) confirms "
            + "today's list, and \(system)'s count does not change until then."
    }

    /// A line written off for a reason the system keeps, noted like a use.
    func stagedWrittenOff(_ quantity: StockQuantity, of line: StockSystemSnapshot.Line, jobReference: String?,
                          onJob: Bool) -> String {
        let job = onJob ? (jobReference.map { "job \($0)" } ?? "this job") : "today's list"
        let confirm = onJob ? "the job's parts" : "today's list"
        return "I've noted \(phrase(line, quantity)) written off as damaged, on \(job). It goes to \(system) when "
            + "\(w.person) confirms \(confirm), and \(system)'s count does not change until then."
    }

    /// A quantity the system cannot take for the item, refused before anything is noted.
    func notStaged(_ line: StockSystemSnapshot.Line, _ refusal: StockSystemOutRefusal, quantity: StockQuantity,
                   unit: VanStockUnit) -> String {
        "Nothing noted for \(line.name): "
            + refusal.sentence(system: system, quantity: quantity, unit: unit, decimalPlaces: line.decimalPlaces)
            + " Ask \(w.person) for the amount again."
    }

    /// What one undo took back, before anything was sent.
    func unstaged(_ entries: [StagedStockUseEntry]) -> String {
        let names = entries.map { $0.use.unit.spoken($0.use.quantity, of: $0.use.name) }
        return "Taken back: " + names.joined(separator: "; ") + ". Nothing goes to \(system) for "
            + (entries.count == 1 ? "it" : "them") + "."
    }

    /// Nothing noted to take back.
    func nothingToUnstage() -> String {
        "Nothing is noted on the phone to take back. " + refused(.undoLoad)
    }

    /// A removal for a reason the system does not keep.
    func removalNotKept(keepsDamage: Bool) -> String {
        let tail = keepsDamage
            ? " Only stock written off as damaged is noted here, to go to \(system) when the parts are confirmed."
            : ""
        return refused(.load) + tail
    }

    /// The phone could not keep the note.
    func notSaved() -> String {
        "The note couldn't be kept on this phone, so nothing was noted for \(system). Tell \(w.person)."
    }

    /// A use on a vehicle with no job open: every use from a vehicle belongs to a job.
    func useNeedsJob() -> String {
        "Every part \(w.takenFrom) goes on a job, and no job is open, so nothing was noted. Ask \(w.person) which "
            + "job it was for."
    }

    // MARK: - Refusals

    /// "Stock is kept in Fixture Till, so each receipt and count is done there, not on the phone."
    func refused(_ action: RefusedAction) -> String {
        let lead = "Stock is kept in \(system)"
        switch action {
        case .load, .undoLoad:
            return "\(lead), so each \(w.putNoun) and count is done there, not on the phone. Nothing was changed."
        case .count:
            return "\(lead), so counting is done there; the phone never sends a count. Nothing was changed."
        case .setStandard, .topUp:
            return "\(lead), so the \(w.usualFigure) and reordering are set there. Nothing was changed."
        }
    }

    /// The handover is not offered: the system already has the stock.
    func handoverNotOffered() -> String {
        "Stock is kept in \(system), so there is no need to \(w.handover): \(system) already has it."
    }

    /// At a till: the phone never records a sale (Decision 7).
    func noSale() -> String {
        "Sales come off \(system)'s count at the till; the phone never records a sale. Nothing was changed."
    }

    // MARK: - Pieces

    /// "3 × Capacitor 45/5 (ZX-1001)", "4.25 litres of Coolant", or the bare item name when the
    /// phone could not map the line's unit.
    func phrase(_ line: StockSystemSnapshot.Line, _ quantity: StockQuantity) -> String {
        guard let unit = line.unit else { return "\(quantity.decimalString) × \(line.name)" }
        return unit.spoken(quantity, of: line.name)
    }

    /// "3", "4.25 litres".
    private func figure(_ line: StockSystemSnapshot.Line, _ quantity: StockQuantity) -> String {
        line.unit?.figure(quantity) ?? quantity.decimalString
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    /// After "as of": "09:10" today, "yesterday at 16:10", "Monday at 16:10", "3 October",
    /// "3 October 2025". The clock in van stock's style (`VanStockAnswerComposer.age`).
    func time(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return clock
        case 1: return "yesterday at \(clock)"
        case 2...6: return "\(Self.weekdays[((parts.weekday ?? 1) - 1) % 7]) at \(clock)"
        default:
            let day = "\(parts.day ?? 1) \(Self.months[((parts.month ?? 1) - 1) % 12])"
            let sameYear = parts.year == calendar.component(.year, from: now)
            return sameYear ? day : "\(day) \(parts.year ?? 0)"
        }
    }
}
