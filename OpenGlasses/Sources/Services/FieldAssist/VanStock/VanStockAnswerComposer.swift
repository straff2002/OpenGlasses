import Foundation

/// What the assistant is told to say about van stock (Plan IH §3).
///
/// Every answer about a level states how it is known and as of when; an unreliable line is said to
/// be unreliable before any figure; an unknown is never a number. A write returns the read-back
/// that must be spoken, and at zero or at the minimum it offers a request and stops — it never
/// makes one.
///
/// Pure, with the clock and the calendar handed in, so the same log always reads the same way.
/// Every word about the place comes from `wording` (Plan MK §3), so a store hears "in the store"
/// and a van hears what it always has.
struct VanStockAnswerComposer {

    var now: Date
    var calendar: Calendar = .current
    var wording = StockPlaceWording(.default)

    private var w: StockPlaceWording { wording }
    private func cap(_ phrase: String) -> String { StockPlaceWording.capitalised(phrase) }

    // MARK: - Reading

    func check(_ item: VanStockItem, level: VanStockLevel) -> String {
        var lines: [String] = []
        if level.unreliable {
            lines.append("The count for \(item.name) cannot be trusted: a use was recorded when the log "
                + "showed none. The log shows \(item.phrase(level.onHand)). Ask \(w.person) to count them.")
        } else if let asOf = level.asOf {
            let figure = level.onHand == .zero ? "No \(item.name) \(w.location)" : "\(item.phrase(level.onHand)) \(w.location)"
            lines.append("\(figure) — \(provenance(level, asOf: asOf)).")
        } else {
            lines.append("\(item.name) is on \(w.list) with nothing recorded against it — no count yet.")
        }
        if let ordered = ordered(level, of: item) { lines.append(ordered) }
        if !level.unreliable, level.onHand > .zero, let minimum = item.minimum, level.onHand <= minimum {
            lines.append("That is at or below the minimum of \(item.figure(minimum)).")
        }
        if item.number != nil, let notFound = notFound(item.verification) {
            lines.append(notFound)
        }
        return lines.joined(separator: " ")
    }

    /// The sentence for a number its book did not hold (Plan MK §4), naming the book. Nil for a
    /// number that was found, and for one nothing was searched for: a store that has named no
    /// book never hears about one.
    private func notFound(_ verification: VanStockVerification) -> String? {
        guard verification.state == .notFound else { return nil }
        guard let vault = verification.vault else { return "The part number was not found where it was looked up." }
        return "The part number is not found in \(vault)."
    }

    func candidates(_ items: [VanStockItem], levels: [String: VanStockLevel]) -> String {
        let listed = items.enumerated().map { offset, item in
            "\(offset + 1). \(item.name) — \(item.figure(levels[item.id]?.onHand ?? .zero)) \(w.location)"
        }
        return "More than one line \(w.location) fits: " + listed.joined(separator: "; ")
            + ". Ask \(w.person) which one; do not choose for them. Nothing was changed."
    }

    /// A check that matched nothing word for word but found a line that sounds like it. The
    /// figure is given, to be confirmed rather than asserted, and the search is not closed the way
    /// `notCarried` closes it: a tester's brand was heard as an everyday word, the check said
    /// none, and 22 packs were on the van.
    func closest(_ items: [VanStockItem], to reference: String, levels: [String: VanStockLevel]) -> String {
        let figures = items.map { check($0, level: levels[$0.id] ?? VanStockLevel(itemID: $0.id)) }
        let ask: String
        if figures.count == 1 {
            ask = "The closest \(w.location): " + figures[0] + " It may have been misheard: ask \(w.person) "
                + "whether that is the part; if it is, give them this figure."
        } else {
            let listed = figures.enumerated().map { "\($0.offset + 1). \($0.element)" }
            ask = "The closest \(w.location): " + listed.joined(separator: " ") + " It may have been misheard: ask "
                + "\(w.person) which, if any, is the part; give them that line's figure, and do not choose for them."
        }
        return "No line on \(w.list) matches '\(reference)' word for word. " + ask
            + " Do not say there is none \(w.location) unless they say it is none of these. Nothing was changed."
    }

    /// A write that matched nothing word for word but sounds like a line already on the van:
    /// nothing is recorded against it, and a load or a count does not start a near-duplicate line
    /// beside it, until the technician says which.
    func misheard(_ items: [VanStockItem], reference: String, levels: [String: VanStockLevel],
                  mayCreate: Bool) -> String {
        let listed = items.enumerated().map { offset, item in
            "\(items.count == 1 ? "" : "\(offset + 1). ")\(item.name) — \(item.figure(levels[item.id]?.onHand ?? .zero)) \(w.location)"
        }
        var answer = "Nothing on \(w.list) matches '\(reference)' word for word, but a word may have been "
            + "misheard. Did they mean " + listed.joined(separator: "; ") + "? Ask \(w.person); do not choose for them."
        if mayCreate {
            answer += " If it is a different part, record it again with 'new_line' true and it goes on \(w.list) as a new line."
        }
        return answer + " Nothing was changed."
    }

    func notOnVan(_ reference: String) -> String {
        "Nothing on \(w.list) matches \(reference). Nothing was changed."
    }

    /// A check that found nothing. It ends the search: a tester's "do I have a flame sensor in my
    /// truck" was looked up five times under five names, used the turn's every tool round and
    /// failed without an answer. The list was searched by number and by name both.
    func notCarried(_ reference: String) -> String {
        "Nothing on \(w.list) matches \(reference), by part number or by name: as far as \(w.log) "
            + "knows, there is none \(w.location). Say so — do not look it up again under another "
            + "name unless \(w.person) gives one. "
            + "Offer to ask the office for one, and request it only if \(w.person) says yes. "
            + "Nothing was changed."
    }

    func emptyVan() -> String {
        "\(cap(w.list)) is empty: nothing has been \(w.putVerb) or counted yet. \(cap(w.person)) can say what "
            + "they have \(w.putVerb), count what is on the shelves, or import a spreadsheet from \(w.screen), "
            + "to start it. Do not guess what is \(w.location)."
    }

    func low(_ entries: [(item: VanStockItem, level: VanStockLevel)]) -> String {
        guard !entries.isEmpty else { return "Nothing \(w.location) is at or below its minimum." }
        let listed = entries.map { entry -> String in
            var line = entry.level.onHand == .zero ? "\(entry.item.name) — none left"
                                                   : "\(entry.item.name) — \(entry.item.figure(entry.level.onHand)) left"
            if let minimum = entry.item.minimum { line += ", minimum \(entry.item.figure(minimum))" }
            if entry.level.onOrder > .zero { line += " (\(entry.item.figure(entry.level.onOrder)) asked for)" }
            return line
        }
        let count = entries.count == 1 ? "1 line is low" : "\(entries.count) lines are low"
        return "\(count): " + listed.joined(separator: "; ") + "."
    }

    // MARK: - Read-backs

    func loaded(_ item: VanStockItem, quantity: StockQuantity, before: VanStockLevel, after: VanStockLevel,
                created: Bool) -> String {
        var lines = ["\(cap(w.putVerb)) \(item.phrase(quantity)). \(item.phrase(after.onHand)) \(w.location) now."]
        if created { lines.append(contentsOf: newLine(item)) }
        let covered = before.onOrder - after.onOrder
        if covered > .zero {
            let since = before.oldestOrderAt.map { " asked for \(age($0))" } ?? " asked for"
            lines.append(after.onOrder == .zero ? "That covers the \(item.figure(covered))\(since)."
                                                : "That covers \(item.figure(covered)) of the \(item.figure(before.onOrder))\(since).")
        }
        if after.unreliable {
            lines.append("The count for this line is still unreliable until somebody counts it.")
        }
        return lines.joined(separator: " ")
    }

    func used(_ item: VanStockItem, quantity: StockQuantity, before: VanStockLevel, after: VanStockLevel,
              jobReference: String?) -> String {
        let job = jobReference.map { " on job \($0)" } ?? ""
        var lines = ["\(cap(w.takenVerb)) \(item.phrase(quantity))\(job)."]
        lines.append(contentsOf: remaining(item, before: before, after: after, offer: true))
        return lines.joined(separator: " ")
    }

    func removed(_ item: VanStockItem, quantity: StockQuantity, reason: VanStockMovement.RemovalReason,
                 before: VanStockLevel, after: VanStockLevel) -> String {
        var lines = ["Removed \(item.phrase(quantity)) (\(reason.rawValue))."]
        lines.append(contentsOf: remaining(item, before: before, after: after, offer: false))
        return lines.joined(separator: " ")
    }

    /// A stocktake reads back what was counted and how it compares with what the log expected, so
    /// "I counted 16, check that against stock" is answered "2 short" by the tool rather than by
    /// the model doing sums across two results.
    func counted(_ item: VanStockItem, before: VanStockLevel, after: VanStockLevel, created: Bool) -> String {
        var lines = ["Counted: \(item.phrase(after.onHand)) \(w.location)."]
        switch VanStockCountCheck(before: before, counted: after.onHand) {
        case nil: break
        case .matches(let expected):
            lines.append("That matches the \(item.unit.spoken(expected)) the log expected.")
        case .short(let expected, let by):
            lines.append("The log expected \(item.unit.spoken(expected)), so that is \(item.unit.spoken(by)) short.")
        case .over(let expected, let by):
            lines.append("The log expected \(item.unit.spoken(expected)), so that is \(item.unit.spoken(by)) over.")
        case .unreliable:
            lines.append("The log's figure could not be trusted, so there was nothing to check this against; "
                + "the count is the figure now.")
        }
        if created { lines.append(contentsOf: newLine(item)) }
        return lines.joined(separator: " ")
    }

    func undone(_ undone: VanStockLog.Undone, items: [VanStockItem]) -> String {
        let names = Dictionary((items + undone.removedItems).map { ($0.id, $0) }) { first, _ in first }
        let taken = undone.movements.map { movement -> String in
            let item = names[movement.itemID]
            let name = item?.name ?? "a line"
            switch movement.kind {
            case .loaded: return "the \(w.putNoun) of \(item?.phrase(movement.quantity) ?? name)"
            case .used:
                return w.clinical ? "the dose given of \(item?.phrase(movement.quantity) ?? name)"
                                  : "the use of \(item?.phrase(movement.quantity) ?? name)"
            case .removed: return "the removal of \(item?.phrase(movement.quantity) ?? name)"
            case .wasted: return "the waste of \(item?.phrase(movement.quantity) ?? name)"
            case .counted: return "the count of \(name)"
            case .ordered: return "the order for \(name)"
            case .edited, .reversed, .opening: return "a change to \(name)"
            }
        }
        var lines = ["Undone: " + taken.joined(separator: "; ") + "."]
        if !undone.removedItems.isEmpty {
            lines.append("Taken off \(w.list) again: "
                + undone.removedItems.map(\.name).joined(separator: "; ") + ".")
        }
        return lines.joined(separator: " ")
    }

    func nothingToUndo() -> String {
        "There is nothing to undo: the last \(w.stockName) entry has already been taken back, or there is none."
    }

    // MARK: - Pieces

    /// A line the list has not held before. A number nothing knows is read back a character at a
    /// time, because this is the one place a misheard digit becomes a wrong line of stock: as
    /// costly for a stock code as for a part number, so every place hears it. The reason given is
    /// the one the lookup supports (Plan MK §4): a number nothing was searched for has only not
    /// been on the list; one its book did not hold is said to be missing from that book.
    /// The same, as one sentence run, for a read-back built elsewhere (Plan MY's lot read-backs).
    func newLineNote(_ item: VanStockItem) -> String { newLine(item).joined(separator: " ") }

    private func newLine(_ item: VanStockItem) -> [String] {
        var lines = ["That is a new line on \(w.list)."]
        if let number = item.number, !item.verification.isFound {
            let reason: String
            if item.verification.state == .notFound {
                reason = "is not in \(item.verification.vault ?? "the book it was looked up in") and has not been on this list"
            } else {
                reason = "has not been on this list before"
            }
            lines.append("Part number \(number) \(reason). Read it back as: \(SpokenPartNumber.spoken(number)). "
                + "\(cap(w.person)) can say 'undo that' if it was misheard.")
        }
        return lines
    }

    private func remaining(_ item: VanStockItem, before: VanStockLevel, after: VanStockLevel,
                           offer: Bool) -> [String] {
        if after.unreliable, !before.unreliable {
            return ["The log showed \(item.figure(before.onHand)), so it cannot say how many are left. "
                + "Ask \(w.person) to count them when they can."]
        }
        if after.unreliable {
            return ["The count for this line is unreliable; ask \(w.person) to count them."]
        }
        if after.onHand == .zero {
            return ["That was the last \(w.location)."] + (offer ? [replacement(after, of: item)] : [])
        }
        if let minimum = item.minimum, after.onHand <= minimum {
            return ["\(item.figure(after.onHand)) left, at or below the minimum of \(item.figure(minimum))."]
                + (offer ? [replacement(after, of: item)] : [])
        }
        return ["\(item.figure(after.onHand)) left."]
    }

    /// The offer, and where it stops: nothing is requested unless the technician says so.
    private func replacement(_ level: VanStockLevel, of item: VanStockItem) -> String {
        if let ordered = ordered(level, of: item) { return ordered }
        return "Offer to ask the office for a replacement, and request one only if \(w.person) says yes."
    }

    private func ordered(_ level: VanStockLevel, of item: VanStockItem) -> String? {
        guard level.onOrder > .zero else { return nil }
        let since = level.oldestOrderAt.map { " \(age($0))" } ?? ""
        return "\(item.figure(level.onOrder)) asked for\(since) and not yet \(w.putVerb)."
    }

    /// How a figure is known and as of when: "counted today at 10:40".
    func provenance(_ level: VanStockLevel, asOf: Date) -> String {
        if level.handedOver { return "as handed over \(age(asOf))" }
        switch level.provenance {
        case .counted: return "counted \(age(asOf))"
        case .inferred:
            return "worked out from what was \(w.putVerb) and \(w.takenVerb), not counted; last changed \(age(asOf))"
        }
    }

    // MARK: - Age

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    /// "today at 10:40", "yesterday at 17:10", "on Monday", "on 3 October", "on 3 October 2025".
    func age(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today at \(time)"
        case 1: return "yesterday at \(time)"
        case 2...6:
            return "on \(Self.weekdays[((parts.weekday ?? 1) - 1) % 7])"
        default:
            let day = "on \(parts.day ?? 1) \(Self.months[((parts.month ?? 1) - 1) % 12])"
            let sameYear = parts.year == calendar.component(.year, from: now)
            return sameYear ? day : "\(day) \(parts.year ?? 0)"
        }
    }
}
