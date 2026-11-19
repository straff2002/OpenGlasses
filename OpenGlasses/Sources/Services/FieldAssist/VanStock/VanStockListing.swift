import Foundation

/// What is there, read out (Plan MK §8): the whole list, or the lines in the bins that were named.
///
/// A technician asks part by part; a shop asks by place: "what's in the main fridge?". Each line
/// says its figure with `check`'s honesty rules: an unreliable line is called unreliable before any
/// figure, a line at zero says none, and a line nothing has been recorded against gives no number.
/// How the figures are known is said once when every line shares it. Pure, and it writes nothing.
extension VanStockAnswerComposer {

    /// The most lines a spoken list reads out before it sends the rest to the Stock screen.
    static let listLimit = 8

    /// Words a bin's name never needs: "the main fridge" finds "Main fridge".
    private static let binFiller: Set<String> = ["the", "a", "an", "in", "on", "at", "my", "our"]

    /// The list, or the lines in the bins `bin` names. A bin is named when its label holds every
    /// word said, ignoring case; several bins can be. A bin that matches nothing names the bins
    /// there are, so the model can ask which one.
    func list(_ log: VanStockLog, bin said: String?) -> String {
        guard !log.isEmpty else { return emptyVan() }
        let words = Self.binWords(said)
        var items = log.items
        var named: [String] = []
        if !words.isEmpty {
            let labels = Self.binLabels(log.items)
            named = labels.filter { label in
                let lower = label.lowercased()
                return words.allSatisfy { lower.contains($0) }
            }
            guard !named.isEmpty else { return unknownBin(said ?? "", labels: labels) }
            let keys = Set(named.map(Self.binKey))
            items = items.filter { item in Self.bin(of: item).map { keys.contains(Self.binKey($0)) } ?? false }
        }

        let levels = log.levels
        let ordered = items.sorted(by: Self.shelfOrder)
        let levelOf = { (item: VanStockItem) in levels[item.id] ?? VanStockLevel(itemID: item.id) }
        // How the figures are known, when every line shares it: said once, not eight times.
        let provenances = ordered.map { item -> String? in
            let level = levelOf(item)
            guard !level.unreliable, let asOf = level.asOf else { return nil }
            return provenance(level, asOf: asOf)
        }
        let shared: String? = {
            guard let first = provenances.first ?? nil, provenances.allSatisfy({ $0 == first }) else { return nil }
            return first
        }()
        let byBin = named.count != 1

        let count = ordered.count == 1 ? "1 line" : "\(ordered.count) lines"
        var heading: String
        switch named.count {
        case 0: heading = "Everything \(wording.location): \(count), by bin"
        case 1: heading = "In \(named[0]): \(count)"
        default: heading = "In \(Self.joined(named)): \(count), by bin"
        }
        if let shared { heading += ", all \(shared)" }

        var lines = [heading + ":"]
        for item in ordered.prefix(Self.listLimit) {
            var line = figure(item, level: levelOf(item), provenance: shared == nil)
            if byBin { line = "\(Self.bin(of: item) ?? "No bin") — " + line }
            lines.append(line + ".")
        }
        let rest = ordered.count - Self.listLimit
        if rest > 0 {
            lines.append("And \(rest) more: the full list is on \(wording.screen).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    /// One line's figure, by `check`'s rules.
    private func figure(_ item: VanStockItem, level: VanStockLevel, provenance perLine: Bool) -> String {
        var line: String
        if level.unreliable {
            line = "\(item.name): unreliable, the count cannot be trusted; the log shows \(level.onHand.decimalString), "
                + "so ask \(wording.person) to count it"
        } else if let asOf = level.asOf {
            line = level.onHand == .zero ? "\(item.name): none" : item.phrase(level.onHand)
            if perLine { line += " (\(provenance(level, asOf: asOf)))" }
        } else {
            line = "\(item.name): nothing recorded yet, no count"
        }
        if level.onOrder > .zero { line += "; \(level.onOrder.decimalString) asked for" }
        return line
    }

    private func unknownBin(_ said: String, labels: [String]) -> String {
        let cleaned = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !labels.isEmpty else {
            return "No bin called \(cleaned): no line on \(wording.list) has a bin. Leave 'bin' out to read the whole list."
        }
        return "No bin called \(cleaned). The bins are: \(labels.joined(separator: ", ")). Ask which one they mean."
    }

    private static func binWords(_ said: String?) -> [String] {
        (said ?? "").lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init).filter { !binFiller.contains($0) }
    }

    /// A line's bin, trimmed; nil for none.
    private static func bin(of item: VanStockItem) -> String? {
        let trimmed = item.bin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func binKey(_ label: String) -> String { label.lowercased() }

    /// The list's bins, each once, in order.
    private static func binLabels(_ items: [VanStockItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap(bin(of:)).filter { seen.insert(binKey($0)).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// By bin, then by name, so a spoken list follows the shelves; lines with no bin last.
    private static func shelfOrder(_ lhs: VanStockItem, _ rhs: VanStockItem) -> Bool {
        switch (bin(of: lhs), bin(of: rhs)) {
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(left), .some(right)):
            let order = left.localizedCaseInsensitiveCompare(right)
            if order != .orderedSame { return order == .orderedAscending }
        case (nil, nil): break
        }
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    /// "Main fridge", "Main fridge and Door fridge", "A, B and C".
    private static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
