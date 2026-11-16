import Foundation

/// What the assistant is told to say about van stock (Plan IH §3).
///
/// Every answer about a level states how it is known and as of when; an unreliable line is said to
/// be unreliable before any figure; an unknown is never a number. A write returns the read-back
/// that must be spoken, and at zero or at the minimum it offers a request and stops — it never
/// makes one.
///
/// Pure, with the clock and the calendar handed in, so the same log always reads the same way.
struct VanStockAnswerComposer {

    var now: Date
    var calendar: Calendar = .current

    // MARK: - Reading

    func check(_ item: VanStockItem, level: VanStockLevel) -> String {
        var lines: [String] = []
        if level.unreliable {
            lines.append("The count for \(item.name) cannot be trusted: a use was recorded when the log "
                + "showed none. The log shows \(item.phrase(level.onHand)). Ask the technician to count them.")
        } else if let asOf = level.asOf {
            let figure = level.onHand == 0 ? "No \(item.name) on the van" : "\(item.phrase(level.onHand)) on the van"
            lines.append("\(figure) — \(provenance(level, asOf: asOf)).")
        } else {
            lines.append("\(item.name) is on the van list with nothing recorded against it — no count yet.")
        }
        if let ordered = ordered(level) { lines.append(ordered) }
        if !level.unreliable, level.onHand > 0, let minimum = item.minimum, level.onHand <= minimum {
            lines.append("That is at or below the minimum of \(minimum).")
        }
        if item.number != nil, !item.verified {
            lines.append("The part number is not verified against the manuals.")
        }
        return lines.joined(separator: " ")
    }

    func candidates(_ items: [VanStockItem], levels: [String: VanStockLevel]) -> String {
        let listed = items.enumerated().map { offset, item in
            "\(offset + 1). \(item.name) — \(levels[item.id]?.onHand ?? 0) on the van"
        }
        return "More than one line on the van fits: " + listed.joined(separator: "; ")
            + ". Ask the technician which one; do not choose for them. Nothing was changed."
    }

    func notOnVan(_ reference: String) -> String {
        "Nothing on the van list matches \(reference). Nothing was changed."
    }

    /// A check that found nothing. It ends the search: a tester's "do I have a flame sensor in my
    /// truck" was looked up five times under five names, used the turn's every tool round and
    /// failed without an answer. The list was searched by number and by name both.
    func notCarried(_ reference: String) -> String {
        "Nothing on the van list matches \(reference), by part number or by name: as far as the van "
            + "log knows, there is none on the van. Say so — do not look it up again under another "
            + "name unless the technician gives one. "
            + "Offer to ask the office for one, and request it only if the technician says yes. "
            + "Nothing was changed."
    }

    func emptyVan() -> String {
        "The van list is empty: nothing has been loaded or counted yet. The technician can say what "
            + "they have loaded, count what is on the shelves, or import a spreadsheet from the Van stock "
            + "screen, to start it. Do not guess what is on the van."
    }

    func low(_ entries: [(item: VanStockItem, level: VanStockLevel)]) -> String {
        guard !entries.isEmpty else { return "Nothing on the van is at or below its minimum." }
        let listed = entries.map { entry -> String in
            var line = entry.level.onHand == 0 ? "\(entry.item.name) — none left"
                                               : "\(entry.item.name) — \(entry.level.onHand) left"
            if let minimum = entry.item.minimum { line += ", minimum \(minimum)" }
            if entry.level.onOrder > 0 { line += " (\(entry.level.onOrder) asked for)" }
            return line
        }
        let count = entries.count == 1 ? "1 line is low" : "\(entries.count) lines are low"
        return "\(count): " + listed.joined(separator: "; ") + "."
    }

    // MARK: - Read-backs

    func loaded(_ item: VanStockItem, quantity: Int, before: VanStockLevel, after: VanStockLevel,
                created: Bool) -> String {
        var lines = ["Loaded \(item.phrase(quantity)). \(item.phrase(after.onHand)) on the van now."]
        if created { lines.append(contentsOf: newLine(item)) }
        let covered = before.onOrder - after.onOrder
        if covered > 0 {
            let since = before.oldestOrderAt.map { " asked for \(age($0))" } ?? " asked for"
            lines.append(after.onOrder == 0 ? "That covers the \(covered)\(since)."
                                            : "That covers \(covered) of the \(before.onOrder)\(since).")
        }
        if after.unreliable {
            lines.append("The count for this line is still unreliable until somebody counts it.")
        }
        return lines.joined(separator: " ")
    }

    func used(_ item: VanStockItem, quantity: Int, before: VanStockLevel, after: VanStockLevel,
              jobReference: String?) -> String {
        let job = jobReference.map { " on job \($0)" } ?? ""
        var lines = ["Used \(item.phrase(quantity))\(job)."]
        lines.append(contentsOf: remaining(item, before: before, after: after, offer: true))
        return lines.joined(separator: " ")
    }

    func removed(_ item: VanStockItem, quantity: Int, reason: VanStockMovement.RemovalReason,
                 before: VanStockLevel, after: VanStockLevel) -> String {
        var lines = ["Removed \(item.phrase(quantity)) (\(reason.rawValue))."]
        lines.append(contentsOf: remaining(item, before: before, after: after, offer: false))
        return lines.joined(separator: " ")
    }

    /// A stocktake reads back what was counted and how it compares with what the log expected, so
    /// "I counted 16, check that against stock" is answered "2 short" by the tool rather than by
    /// the model doing sums across two results.
    func counted(_ item: VanStockItem, before: VanStockLevel, after: VanStockLevel, created: Bool) -> String {
        var lines = ["Counted: \(item.phrase(after.onHand)) on the van."]
        switch VanStockCountCheck(before: before, counted: after.onHand) {
        case nil: break
        case .matches(let expected):
            lines.append("That matches the \(item.unit.amount(expected)) the log expected.")
        case .short(let expected, let by):
            lines.append("The log expected \(item.unit.amount(expected)), so that is \(item.unit.amount(by)) short.")
        case .over(let expected, let by):
            lines.append("The log expected \(item.unit.amount(expected)), so that is \(item.unit.amount(by)) over.")
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
            case .loaded: return "the load of \(item?.phrase(movement.quantity) ?? name)"
            case .used: return "the use of \(item?.phrase(movement.quantity) ?? name)"
            case .removed: return "the removal of \(item?.phrase(movement.quantity) ?? name)"
            case .counted: return "the count of \(name)"
            case .ordered: return "the order for \(name)"
            case .edited, .reversed, .opening: return "a change to \(name)"
            }
        }
        var lines = ["Undone: " + taken.joined(separator: "; ") + "."]
        if !undone.removedItems.isEmpty {
            lines.append("Taken off the van list again: "
                + undone.removedItems.map(\.name).joined(separator: "; ") + ".")
        }
        return lines.joined(separator: " ")
    }

    func nothingToUndo() -> String {
        "There is nothing to undo: the last van stock entry has already been taken back, or there is none."
    }

    // MARK: - Pieces

    /// A line the van has not carried before. A number nothing knows is read back a character at a
    /// time, because this is the one place a misheard digit becomes a wrong line of stock.
    private func newLine(_ item: VanStockItem) -> [String] {
        var lines = ["That is a new line on the van list."]
        if let number = item.number, !item.verified {
            lines.append("Part number \(number) is not in the manuals and has not been on this van "
                + "before. Read it back as: \(SpokenPartNumber.spoken(number)). "
                + "The technician can say 'undo that' if it was misheard.")
        }
        return lines
    }

    private func remaining(_ item: VanStockItem, before: VanStockLevel, after: VanStockLevel,
                           offer: Bool) -> [String] {
        if after.unreliable, !before.unreliable {
            return ["The log showed \(before.onHand), so it cannot say how many are left. "
                + "Ask the technician to count them when they can."]
        }
        if after.unreliable {
            return ["The count for this line is unreliable; ask the technician to count them."]
        }
        if after.onHand == 0 {
            return ["That was the last on the van."] + (offer ? [replacement(after)] : [])
        }
        if let minimum = item.minimum, after.onHand <= minimum {
            return ["\(after.onHand) left, at or below the minimum of \(minimum)."]
                + (offer ? [replacement(after)] : [])
        }
        return ["\(after.onHand) left."]
    }

    /// The offer, and where it stops: nothing is requested unless the technician says so.
    private func replacement(_ level: VanStockLevel) -> String {
        if let ordered = ordered(level) { return ordered }
        return "Offer to ask the office for a replacement, and request one only if the technician says yes."
    }

    private func ordered(_ level: VanStockLevel) -> String? {
        guard level.onOrder > 0 else { return nil }
        let since = level.oldestOrderAt.map { " \(age($0))" } ?? ""
        return "\(level.onOrder) asked for\(since) and not yet loaded."
    }

    private func provenance(_ level: VanStockLevel, asOf: Date) -> String {
        if level.handedOver { return "as handed over \(age(asOf))" }
        switch level.provenance {
        case .counted: return "counted \(age(asOf))"
        case .inferred: return "worked out from what was loaded and used, not counted; last changed \(age(asOf))"
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
