import Foundation

/// A chart as one passage retrieval can find (Plan LX §4), stored the way a table's row passages are
/// (beside the document's own chunks, `DocumentChunker.Kind.chart`, never changing the page text).
///
/// Two forms, both written from a template so the passage says nothing the page or the reading
/// does not:
/// - **Words only** — what every chart gets at import, on the phone, with no model: its caption, its
///   axis titles and units as printed, the range of each axis's ticks, and the words printed inside
///   the plot (series and family labels, a note). It says its values were not read.
/// - **Read** — a usable reading's axes, series and values at the printed x ticks, each *about*,
///   plus pass 2's sentences when they passed `ChartDescriptionCheck`. Nothing builds this form in the
///   app yet (P1); it is here so the template is one thing.
///
/// The passage's text is the model's, in English like a row passage; the technician hears a
/// chart's value only through `ChartCitation`.
enum ChartPassage {

    /// The words printed inside the plot that a words-only passage keeps, at most.
    static let insideWordCap = 16

    /// The first line: "Chart: Figure 9 — Charging chart (page 41)."
    static func heading(caption: ChartCandidate.Caption?, page: ManualTable.Page) -> String {
        var name = "Chart"
        if let caption {
            name += ": " + caption.label + (caption.title.isEmpty ? "" : " \u{2014} " + caption.title)
        }
        return name + " (page \(page.spoken))."
    }

    /// "outdoor temperature (°F), 65 to 115" for one axis; "the x axis, 65 to 115" with no title.
    static func axisPhrase(title: String?, unit: String?, range: ClosedRange<Double>?, role: ChartReading.AxisRole) -> String {
        let name = title.map(ChartAxisTitle.name(of:)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName(role)
        var phrase = name
        if let unit, !unit.isEmpty { phrase += " (\(unit))" }
        if let range { phrase += ", \(number(range.lowerBound)) to \(number(range.upperBound))" }
        return phrase
    }

    private static func defaultName(_ role: ChartReading.AxisRole) -> String {
        switch role {
        case .x: return "the x axis"
        case .y: return "the y axis"
        case .secondY: return "the second y axis"
        }
    }

    /// The words-only passage for a chart found at import (§4, §8).
    static func wordsOnlyText(for candidate: ChartCandidate) -> String {
        var lines = [heading(caption: candidate.caption, page: candidate.page)
                     + " Values not read: the manual gives them only as a chart."]
        let axes = candidate.axes.map { axisPhrase(title: $0.title, unit: $0.unit, range: $0.range, role: $0.role) }
        if !axes.isEmpty { lines.append("Axes: " + axes.joined(separator: "; ") + ".") }
        let inside = candidate.insideWords.prefix(insideWordCap).joined(separator: " ")
        if !inside.isEmpty { lines.append("Printed on the chart: " + inside + ".") }
        return lines.joined(separator: "\n")
    }

    /// The passage for a usable reading (§4): the template, then `description` when it passed the
    /// number check.
    static func readText(_ validated: ValidatedChartReading, caption: ChartCandidate.Caption?, description: String?) -> String {
        let reading = validated.reading
        var lines = [heading(caption: caption, page: reading.source.page)
                     + " Read from a picture of the chart; every value is approximate."]
        let axes = reading.axes.map { axisPhrase(title: $0.title, unit: $0.unit, range: $0.range, role: $0.role) }
        lines.append("Axes: " + axes.joined(separator: "; ") + ".")
        let familyName = reading.familyTitle.map(ChartAxisTitle.name(of:)).map { $0.lowercased() }
        if reading.kind == .family {
            lines.append("Series by \(familyName ?? "series"): " + reading.series.map(\.label).joined(separator: ", ") + ".")
        } else if !reading.series.isEmpty {
            lines.append("Series: " + reading.series.map(\.label).joined(separator: ", ") + ".")
        }
        let ticks = reading.axis(.x)?.ticks ?? []
        for series in reading.series {
            let atTicks = series.points.filter { point in ticks.contains { ChartReadingValidator.same($0, point.x) } }
            let shown = atTicks.isEmpty ? series.points : atTicks
            guard !shown.isEmpty else { continue }
            let values = shown.map { "about \(number($0.y)) at \(number($0.x))" }.joined(separator: ", ")
            let name = reading.kind == .family ? "At \(familyName ?? "series") \(series.label)" : series.label
            lines.append("\(name): \(values).")
        }
        for band in reading.bands { lines.append("Marked on the chart: \(band.note).") }
        if let description, ChartDescriptionCheck.passes(description, reading: reading, caption: caption) {
            lines.append(description)
        }
        return lines.joined(separator: "\n")
    }

    /// The words-only passages of `candidates` as chunks numbered from `index`, each on its page,
    /// named by its caption's label.
    static func chunks(for candidates: [ChartCandidate], startingAt index: Int) -> [DocumentChunker.Chunk] {
        candidates.enumerated().map { offset, candidate in
            DocumentChunker.Chunk(index: index + offset, text: wordsOnlyText(for: candidate),
                                  page: candidate.page.physical, section: nil,
                                  kind: .chart, figure: candidate.caption?.label)
        }
    }

    /// A number as printed in a passage: whole numbers without a decimal point.
    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

/// Pass 2's description kept only when every number in it is one the chart gives (Plan LX §2):
/// a value of the reading's table, a tick, a family label, or a number in the caption. A
/// description that says a number the chart does not is dropped, and the template stands alone.
enum ChartDescriptionCheck {

    /// Every number written in `text` ("0.8", "1,200", "-10").
    static func numbers(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(?:,\d{3})*(?:\.\d+)?|-?\.\d+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0].replacingOccurrences(of: ",", with: "")) }
        }
    }

    /// The numbers a description may say: the reading's points, ticks and parameters, and the
    /// caption's numbers.
    static func allowed(reading: ChartReading, caption: ChartCandidate.Caption?) -> [Double] {
        var out = reading.axes.flatMap(\.ticks)
        for series in reading.series {
            out += series.points.flatMap { [$0.x, $0.y] }
            if let parameter = series.parameter { out.append(parameter) }
            out += numbers(in: series.label)
        }
        for band in reading.bands { out += numbers(in: band.note) }
        if let caption { out += numbers(in: caption.label + " " + caption.title) }
        if let family = reading.familyTitle { out += numbers(in: family) }
        return out
    }

    /// The numbers in `description` the chart does not give; empty when it passes.
    static func strayNumbers(in description: String, reading: ChartReading, caption: ChartCandidate.Caption?) -> [Double] {
        let allowed = allowed(reading: reading, caption: caption)
        return numbers(in: description).filter { said in !allowed.contains { ChartReadingValidator.same($0, abs(said)) || ChartReadingValidator.same($0, said) } }
    }

    static func passes(_ description: String, reading: ChartReading, caption: ChartCandidate.Caption?) -> Bool {
        strayNumbers(in: description, reading: reading, caption: caption).isEmpty
    }
}
