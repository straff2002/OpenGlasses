import CoreGraphics
import Foundation

/// A picture on a manual page that is a chart, found from the page's placed words alone (Plan LX
/// §1 and §11). No model and no image: the tick labels and axis titles a chart prints are text in
/// the PDF, and their positions say whether they are a chart's.
///
/// Two signals, and a candidate needs both:
/// - **Ticks** (§1): at least `minimumTicks` numbers in a row along one edge and at least as many
///   in a column along the perpendicular edge, each run evenly spaced on the page and stepping
///   evenly in value (linearly, or by a constant ratio for a logarithmic axis).
/// - **Shape** (§11, [[ChartShape]]): the two runs meet at the plot's lower corner — the row under
///   the column, the column at the row's start; the tick labels stand alone, not at the head of a
///   line of text or a row of cells; and few words are printed inside the plot area. A flow
///   diagram drawn as numbered boxes, a wiring sequence and a table of numbers carry evenly spaced
///   runs too, and fail here.
///
/// The drawn axes themselves (two long lines meeting at a corner) are not read: PDFKit gives no
/// access to a page's paths, so the shape rule works from the words. The optional on-device picture
/// classifier §11 allows for is not built; `pictureType` is where its answer goes.
struct ChartCandidate: Equatable {

    struct Tick: Equatable {
        /// As printed ("65", "0.8", "1,000").
        var text: String
        var value: Double
        var rect: CGRect
    }

    struct Axis: Equatable {
        var role: ChartReading.AxisRole
        var ticks: [Tick]
        /// The axis title as printed, nil when none was found beside the run.
        var title: String?
        /// The unit the title carries ("°F" from "Outdoor temperature (°F)"), nil when none.
        var unit: String?
        var scale: ChartReading.Scale

        var values: [Double] { ticks.map(\.value) }
        var range: ClosedRange<Double>? {
            guard let low = values.min(), let high = values.max() else { return nil }
            return low...high
        }
    }

    struct Caption: Equatable {
        /// "Figure 9".
        var label: String
        /// What follows the label, as printed.
        var title: String
    }

    /// What an on-device classifier made of the picture (§11). Nil: not run, which is every
    /// candidate today.
    enum PictureType: String, Equatable {
        case chart, diagram, photograph, other
    }

    /// The physical page (1-based), and the number printed on it where known.
    var page: ManualTable.Page
    var caption: Caption?
    /// The chart in top-down page points: its plot area, its tick labels and its axis titles.
    var region: CGRect
    /// The area the ticks bound, above the x run and beside the y run.
    var plotArea: CGRect
    var axes: [Axis]
    /// The words printed inside the plot area, in reading order and as printed: series labels, a
    /// legend, a note.
    var insideWords: [String]
    /// The caption, or a title printed over the chart, holds a word such as *chart* or *curve*.
    var hasChartWord: Bool
    var pictureType: PictureType?

    func axis(_ role: ChartReading.AxisRole) -> Axis? { axes.first { $0.role == role } }

    /// The numbers among `insideWords` (a family's labels, mostly).
    var insideNumbers: [Double] { insideWords.compactMap(ChartTicks.value(of:)) }

    /// May be read for values later (P1). A classifier that disagrees leaves it words-only (§11).
    var allowsReading: Bool { pictureType == nil || pictureType == .chart }

    // MARK: - Detection

    /// The share of the page's height at its top and foot where running heads and folios print;
    /// numbers there are never ticks.
    static let furnitureBand = 0.09

    /// Every chart on one page, in reading order. `words` are the page's text-layer words in
    /// top-down points ([[PositionedWord]]); `page` names the page. Pure.
    static func detect(words: [PositionedWord], pageBounds: CGRect, page: ManualTable.Page) -> [ChartCandidate] {
        let top = Double(pageBounds.minY) + furnitureBand * Double(pageBounds.height)
        let bottom = Double(pageBounds.maxY) - furnitureBand * Double(pageBounds.height)
        let body = words.filter { Double($0.rect.midY) > top && Double($0.rect.midY) < bottom && !$0.text.isEmpty }
        let rows = ChartTicks.horizontalRuns(body)
        let columns = ChartTicks.verticalRuns(body)
        guard !rows.isEmpty, !columns.isEmpty else { return [] }

        var used = Set<Int>()
        var found: [ChartCandidate] = []
        for row in rows {
            // The column meeting this row at its lower-left corner, the closest first.
            let pairs = columns.enumerated().filter { !used.contains($0.offset) }
                .compactMap { pair -> (Int, Double)? in
                    guard let distance = ChartShape.cornerDistance(row: row, column: pair.element) else { return nil }
                    return (pair.offset, distance)
                }
                .sorted { $0.1 < $1.1 }
            for (index, _) in pairs {
                let column = columns[index]
                let right = rightColumn(for: row, among: columns, used: used.union([index]))
                guard let candidate = candidate(row: row, column: column, right: right.map { columns[$0] },
                                                words: body, allWords: words, pageBounds: pageBounds, page: page)
                else { continue }
                used.insert(index)
                if let right { used.insert(right) }
                found.append(candidate)
                break
            }
        }
        return found.sorted { ($0.region.minY, $0.region.minX) < ($1.region.minY, $1.region.minX) }
    }

    /// A column at the row's far end, for a second y axis.
    private static func rightColumn(for row: ChartTicks.Run, among columns: [ChartTicks.Run], used: Set<Int>) -> Int? {
        columns.indices.filter { !used.contains($0) }.first { ChartShape.rightCornerDistance(row: row, column: columns[$0]) != nil }
    }

    private static func candidate(row: ChartTicks.Run, column: ChartTicks.Run, right rightRun: ChartTicks.Run?, words: [PositionedWord],
                                  allWords: [PositionedWord], pageBounds: CGRect, page: ManualTable.Page) -> ChartCandidate? {
        let size = max(row.size, column.size, 1)
        // The plot area: right of the column, above the row, up to the column's top tick and the
        // row's last tick.
        let plot = CGRect(x: column.box.maxX + 0.25 * size, y: column.box.minY,
                          width: max(0, row.box.maxX - column.box.maxX - 0.25 * size),
                          height: max(0, row.box.minY - column.box.minY))
        guard plot.width > 0, plot.height > 0 else { return nil }
        let tickWords = Set(row.indices + column.indices + (rightRun?.indices ?? []))
        let inside = words.enumerated().filter { !tickWords.contains($0.offset) && plot.contains(CGPoint(x: $0.element.rect.midX, y: $0.element.rect.midY)) }
            .map(\.element)
        guard ChartShape.check(row: row, column: column, inside: inside, words: words).isChart else { return nil }

        let xTitle = ChartAxisTitle.below(row: row, words: words, excluding: tickWords)
        let yTitle = ChartAxisTitle.beside(column: column, plot: plot, words: words, excluding: tickWords)
        var axes = [
            Axis(role: .x, ticks: row.ticks, title: xTitle?.text, unit: xTitle.flatMap { ChartAxisTitle.unit(in: $0.text) }, scale: row.scale),
            Axis(role: .y, ticks: column.ticks, title: yTitle?.text, unit: yTitle.flatMap { ChartAxisTitle.unit(in: $0.text) }, scale: column.scale),
        ]
        if let rightRun {
            axes.append(Axis(role: .secondY, ticks: rightRun.ticks, title: nil, unit: nil, scale: rightRun.scale))
        }
        var region = plot.union(row.box).union(column.box)
        if let rightRun { region = region.union(rightRun.box) }
        for title in [xTitle?.box, yTitle?.box].compactMap({ $0 }) { region = region.union(title) }
        let caption = ChartCaption.nearest(to: region, words: allWords, pageBounds: pageBounds)
        if let box = caption?.box { region = region.union(box) }
        let readingOrder = inside.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        let titleText = [caption?.caption.title, caption?.caption.label].compactMap { $0 }.joined(separator: " ")
        return ChartCandidate(page: page, caption: caption?.caption, region: region, plotArea: plot, axes: axes,
                              insideWords: readingOrder.map(\.text),
                              hasChartWord: ChartCaption.hasChartWord(titleText), pictureType: nil)
    }
}

// MARK: - Tick runs

/// Evenly spaced, evenly stepping runs of numbers: the tick labels of an axis. Pure.
enum ChartTicks {

    struct Run: Equatable {
        /// Indices into the words the run was found among.
        var indices: [Int]
        var ticks: [ChartCandidate.Tick]
        var scale: ChartReading.Scale
        var size: Double

        var box: CGRect { ticks.map(\.rect).reduce(ticks[0].rect) { $0.union($1) } }
    }

    static let minimumTicks = 3
    /// How far one gap between neighbouring ticks may differ from their median gap, as a share of it.
    static let spacingTolerance = 0.12
    /// Two neighbouring ticks are at least this many type sizes apart: digits set close together
    /// are a number, not an axis.
    static let minimumGapSizes = 1.0

    /// A tick label's value: "65", "-10", "0.8", "1,000", "65°", "20%". Nil for anything else.
    static func value(of text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        for suffix in ["\u{00B0}", "%"] where t.hasSuffix(suffix) { t.removeLast() }
        t = t.replacingOccurrences(of: "\u{2212}", with: "-")
        guard !t.isEmpty, t.count <= 8 else { return nil }
        if t.range(of: #"^-?\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
            return Double(t.replacingOccurrences(of: ",", with: ""))
        }
        guard t.range(of: #"^-?(\d+(\.\d+)?|\.\d+)$"#, options: .regularExpression) != nil else { return nil }
        return Double(t)
    }

    /// The upright numbers among `words`, each with its index in `words`.
    private static func numbers(_ words: [PositionedWord]) -> [(Int, PositionedWord)] {
        words.enumerated().filter { !$0.element.isRotated && value(of: $0.element.text) != nil }.map { ($0.offset, $0.element) }
    }

    /// Runs along a line: numbers sharing a baseline, left to right, values increasing. A run's
    /// `indices` are into `words`.
    static func horizontalRuns(_ words: [PositionedWord]) -> [Run] {
        let indexed = numbers(words)
        var groups: [[(Int, PositionedWord)]] = []
        for item in indexed.sorted(by: { $0.1.rect.midY < $1.1.rect.midY }) {
            if let last = groups.last?.last, abs(item.1.rect.midY - last.1.rect.midY) <= 0.5 * max(item.1.size, 1) {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups.compactMap { group in
            let sorted = group.sorted { $0.1.rect.midX < $1.1.rect.midX }
            return longestRun(sorted, position: { Double($0.rect.midX) }, increasingValues: true)
        }
    }

    /// Runs down a column: numbers aligned at their right edge (or their centre), top to bottom,
    /// values increasing upwards.
    static func verticalRuns(_ words: [PositionedWord]) -> [Run] {
        let indexed = numbers(words)
        var runs: [Run] = []
        for edge in [{ (w: PositionedWord) in Double(w.rect.maxX) }, { (w: PositionedWord) in Double(w.rect.midX) }] {
            var groups: [[(Int, PositionedWord)]] = []
            for item in indexed.sorted(by: { edge($0.1) < edge($1.1) }) {
                if let last = groups.last?.last, abs(edge(item.1) - edge(last.1)) <= 0.6 * max(item.1.size, 1) {
                    groups[groups.count - 1].append(item)
                } else {
                    groups.append([item])
                }
            }
            for group in groups {
                let sorted = group.sorted { $0.1.rect.midY < $1.1.rect.midY }
                // Top to bottom on the page is high to low on the axis.
                if let run = longestRun(sorted, position: { Double($0.rect.midY) }, increasingValues: false),
                   !runs.contains(where: { Set($0.indices) == Set(run.indices) }) {
                    runs.append(run)
                }
            }
        }
        return runs
    }

    /// The longest stretch of `items` (already in page order) at least `minimumTicks` long whose
    /// positions are evenly spaced and whose values step evenly, increasing along the run (or,
    /// down a column, decreasing — a y axis prints its highest tick at the top).
    private static func longestRun(_ items: [(Int, PositionedWord)], position: (PositionedWord) -> Double,
                                   increasingValues: Bool) -> Run? {
        guard items.count >= minimumTicks else { return nil }
        var best: Run?
        for start in items.indices {
            for end in stride(from: items.count, through: start + minimumTicks, by: -1) {
                let slice = Array(items[start..<end])
                if let best, best.ticks.count >= slice.count { break }
                guard let run = run(slice, position: position, increasingValues: increasingValues) else { continue }
                best = run
                break
            }
        }
        return best
    }

    private static func run(_ items: [(Int, PositionedWord)], position: (PositionedWord) -> Double,
                            increasingValues: Bool) -> Run? {
        let values = items.compactMap { ChartTicks.value(of: $0.1.text) }
        guard values.count == items.count else { return nil }
        let size = items.map(\.1.size).sorted()[items.count / 2]
        let positions = items.map { position($0.1) }
        let gaps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        let median = gaps.sorted()[gaps.count / 2]
        guard median >= minimumGapSizes * max(size, 1),
              gaps.allSatisfy({ abs($0 - median) <= spacingTolerance * median }) else { return nil }
        let ordered = increasingValues ? values : values.reversed()
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $1 > $0 }) else { return nil }
        let scale: ChartReading.Scale
        let steps = zip(ordered, ordered.dropFirst()).map { $1 - $0 }
        if steps.allSatisfy({ ChartReadingValidator.same($0, steps[0]) }) {
            scale = .linear
        } else if ChartReadingValidator.isLogarithmic(ordered) {
            scale = .logarithmic
        } else {
            return nil
        }
        let ticks = items.map { ChartCandidate.Tick(text: $0.1.text, value: ChartTicks.value(of: $0.1.text)!, rect: $0.1.rect) }
        // The axis runs low to high: a column is read bottom to top.
        return Run(indices: items.map(\.0), ticks: increasingValues ? ticks : ticks.reversed(), scale: scale, size: size)
    }
}

// MARK: - Shape

/// The second signal (Plan LX §11): whether two tick runs, and what lies between them, look like a
/// chart's axes rather than a flow diagram's numbered steps, a wiring sequence or a table. Pure.
enum ChartShape {

    enum Failure: String, Equatable {
        /// The row is not under the column, or the column is not at the row's start.
        case axesDoNotMeet = "axes_do_not_meet"
        /// The column's numbers head lines of text, or the row's sit among words: numbered boxes.
        case numbersInsideBoxes = "numbers_inside_boxes"
        /// Words line up with most ticks inside the plot: a table's rows or columns.
        case gridOfValues = "grid_of_values"
        /// Too many words inside the plot area for a chart.
        case wordyPlotArea = "wordy_plot_area"
    }

    struct Verdict: Equatable {
        var failures: [Failure]
        var isChart: Bool { failures.isEmpty }
    }

    /// The most words a chart's plot area prints: series labels, a legend, a note or two.
    static let maximumInsideWords = 24
    /// How far apart, in type sizes, the row's start and the column's foot may be and still meet.
    static let cornerSizes = 5.0

    /// How far the row's start is from the column's foot, when the row is under the column and the
    /// column at the row's start; nil when they do not meet at the plot's lower-left corner.
    static func cornerDistance(row: ChartTicks.Run, column: ChartTicks.Run) -> Double? {
        let size = max(row.size, column.size, 1)
        let rowBox = row.box, columnBox = column.box
        guard let first = row.ticks.first, let lowest = column.ticks.first else { return nil }
        // The row is under the column's lowest tick, and the column is left of the row's first.
        guard Double(rowBox.midY) > Double(lowest.rect.midY), Double(columnBox.maxX) <= Double(first.rect.midX) + size else {
            return nil
        }
        let down = Double(rowBox.midY - lowest.rect.midY)
        let across = Double(first.rect.midX - columnBox.maxX)
        guard down <= cornerSizes * size, across <= cornerSizes * size else { return nil }
        return down + abs(across)
    }

    /// A column meeting the row at its lower-right corner: a second y axis.
    static func rightCornerDistance(row: ChartTicks.Run, column: ChartTicks.Run) -> Double? {
        let size = max(row.size, column.size, 1)
        guard let last = row.ticks.last, let lowest = column.ticks.first else { return nil }
        guard Double(row.box.midY) > Double(lowest.rect.midY), Double(column.box.minX) >= Double(last.rect.midX) - size else { return nil }
        let down = Double(row.box.midY - lowest.rect.midY)
        let across = Double(column.box.minX - last.rect.midX)
        guard down <= cornerSizes * size, across <= cornerSizes * size else { return nil }
        return down + across
    }

    static func check(row: ChartTicks.Run, column: ChartTicks.Run,
                      inside: [PositionedWord], words: [PositionedWord]) -> Verdict {
        var failures: [Failure] = []
        if cornerDistance(row: row, column: column) == nil { failures.append(.axesDoNotMeet) }
        let size = max(row.size, column.size, 1)
        let tickIndices = Set(row.indices + column.indices)
        let others = words.enumerated().filter { !tickIndices.contains($0.offset) }.map(\.element)

        // A y tick stands alone: no letters set right after it on its line, the way a numbered
        // step's text follows its number. An x tick sits among no words on its row.
        let headsText = column.ticks.filter { tick in
            others.contains { word in
                word.text.contains(where: \.isLetter) && abs(word.rect.midY - tick.rect.midY) <= 0.5 * size
                    && word.rect.minX >= tick.rect.maxX - 0.1 * size && word.rect.minX - tick.rect.maxX <= 2 * size
            }
        }
        let rowAmongWords = row.ticks.indices.dropLast().filter { index in
            let a = row.ticks[index].rect, b = row.ticks[index + 1].rect
            return others.contains { word in
                word.text.contains(where: \.isLetter) && abs(word.rect.midY - a.midY) <= 0.5 * size
                    && word.rect.minX >= a.maxX && word.rect.maxX <= b.minX
            }
        }
        if 2 * headsText.count >= column.ticks.count || 2 * rowAmongWords.count >= row.ticks.count - 1 {
            failures.append(.numbersInsideBoxes)
        }

        // A table's rows run level with its row keys, and its columns under its headings: most
        // ticks have a word lined up with them inside the plot. A chart's curves do not.
        let rowsAligned = column.ticks.filter { tick in inside.contains { abs($0.rect.midY - tick.rect.midY) <= 0.4 * size } }
        let columnsAligned = row.ticks.filter { tick in inside.contains { abs($0.rect.midX - tick.rect.midX) <= 0.4 * size } }
        if (rowsAligned.count >= 2 && 2 * rowsAligned.count >= column.ticks.count)
            || (columnsAligned.count >= 2 && 2 * columnsAligned.count >= row.ticks.count) {
            failures.append(.gridOfValues)
        }
        if inside.count > maximumInsideWords { failures.append(.wordyPlotArea) }
        return Verdict(failures: failures)
    }
}

// MARK: - Axis titles

/// The words beside a tick run that are not numbers: its axis title, and the unit it carries. Pure.
enum ChartAxisTitle {

    struct Found: Equatable {
        var text: String
        var box: CGRect
    }

    /// The x axis's title: the first line of words under the row, overlapping its span.
    static func below(row: ChartTicks.Run, words: [PositionedWord], excluding: Set<Int>) -> Found? {
        let size = max(row.size, 1)
        let box = row.box
        let under = words.enumerated().filter { item in
            !excluding.contains(item.offset) && !item.element.isRotated
                && item.element.rect.minY >= box.maxY - 0.2 * size && item.element.rect.minY - box.maxY <= 3 * size
                && item.element.rect.maxX >= box.minX - 2 * size && item.element.rect.minX <= box.maxX + 2 * size
                && ChartTicks.value(of: item.element.text) == nil
        }.map(\.element)
        guard let topLine = under.map(\.rect.minY).min() else { return nil }
        let line = under.filter { abs($0.rect.minY - topLine) <= 0.5 * size }.sorted { $0.rect.minX < $1.rect.minX }
        return found(line)
    }

    /// The y axis's title: words set on their side left of the column, read bottom to top; else
    /// the line of words just over its top tick.
    static func beside(column: ChartTicks.Run, plot: CGRect, words: [PositionedWord], excluding: Set<Int>) -> Found? {
        let size = max(column.size, 1)
        let box = column.box
        let rotated = words.enumerated().filter { item in
            !excluding.contains(item.offset) && item.element.isRotated
                && item.element.rect.maxX <= box.minX + 0.2 * size && box.minX - item.element.rect.maxX <= 4 * size
                && item.element.rect.maxY >= box.minY - size && item.element.rect.minY <= box.maxY + size
        }.map(\.element).sorted { $0.rect.maxY > $1.rect.maxY }
        if let title = found(rotated) { return title }
        let over = words.enumerated().filter { item in
            !excluding.contains(item.offset) && !item.element.isRotated
                && item.element.rect.maxY <= box.minY + 0.2 * size && box.minY - item.element.rect.maxY <= 2.5 * size
                && item.element.rect.minX >= box.minX - 6 * size && item.element.rect.minX <= plot.minX + plot.width / 2
                && ChartTicks.value(of: item.element.text) == nil
        }.map(\.element)
        guard let bottomLine = over.map(\.rect.maxY).max() else { return nil }
        let line = over.filter { abs($0.rect.maxY - bottomLine) <= 0.5 * size }.sorted { $0.rect.minX < $1.rect.minX }
        return found(line)
    }

    private static func found(_ words: [PositionedWord]) -> Found? {
        guard let first = words.first, words.contains(where: { $0.text.contains(where: \.isLetter) }) else { return nil }
        let box = words.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        return Found(text: words.map(\.text).joined(separator: " "), box: box)
    }

    /// Units an axis prints after its title without brackets.
    static let bareUnits: Set<String> = [
        "°f", "°c", "f", "c", "k", "psi", "psig", "psia", "kpa", "bar", "pa", "cfm", "gpm", "rpm", "hz",
        "a", "amps", "v", "w", "kw", "%", "in.", "in", "mm", "m", "ft", "°", "l/s", "m³/h", "w.c.", "wc",
    ]

    /// The unit a title carries: a bracketed run at its end ("(°F)", "[kPa]", "(in. w.c.)"), else a
    /// last word that is a unit ("Outdoor temperature °F"). Nil when it carries none.
    static func unit(in title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.range(of: #"[\(\[]([^\(\)\[\]]{1,16})[\)\]]\s*$"#, options: .regularExpression) {
            let inner = trimmed[match].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : String(inner.trimmingCharacters(in: CharacterSet(charactersIn: "])")))
        }
        guard let last = trimmed.split(separator: " ").last.map(String.init), trimmed.contains(" ") else { return nil }
        if bareUnits.contains(last.lowercased()) || last.hasPrefix("\u{00B0}") { return last }
        return nil
    }

    /// The title with its unit taken off ("Outdoor temperature").
    static func name(of title: String) -> String {
        guard let unit = unit(in: title) else { return title }
        var name = title.trimmingCharacters(in: .whitespaces)
        for form in ["(\(unit))", "[\(unit)]", unit] where name.hasSuffix(form) {
            name = String(name.dropLast(form.count))
            break
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " ,:-\u{2014}"))
    }
}

// MARK: - Captions

/// The figure caption that names a chart: the nearest caption line above or below it. Pure.
enum ChartCaption {

    struct Found: Equatable {
        var caption: ChartCandidate.Caption
        var box: CGRect
    }

    /// The farthest a caption may be from the chart, as a share of the page's height.
    static let maximumDistance = 0.2

    private static let pattern = #"^(?i:FIGURE|FIG\.?)\s+("# + TableExtractor.labelPattern + ")"

    /// A caption line's label and title: "Figure 9. Charging chart" → ("Figure 9", "Charging chart").
    static func caption(of text: String) -> ChartCandidate.Caption? {
        let line = TableExtractor.droppingMarginMarks(text).trimmingCharacters(in: .whitespaces)
        if let match = line.range(of: pattern, options: .regularExpression) {
            let head = String(line[match])
            let number = head.range(of: TableExtractor.labelPattern + "$", options: .regularExpression).map { String(head[$0]) } ?? ""
            let title = String(line[match.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t.:\u{2014}\u{2013}-"))
            return .init(label: "Figure \(number)", title: title)
        }
        guard let other = CaptionWords.match(line), other.kind == .figure else { return nil }
        return .init(label: other.label, title: other.title)
    }

    static func nearest(to region: CGRect, words: [PositionedWord], pageBounds: CGRect) -> Found? {
        let lines = TableExtractor.lines(of: words)
        let limit = maximumDistance * Double(pageBounds.height)
        var best: (Found, Double)?
        for line in lines {
            guard let caption = caption(of: line.text) else { continue }
            let box = line.words.dropFirst().reduce(line.words[0].rect) { $0.union($1.rect) }
            let distance: Double
            if box.minY >= region.maxY {
                distance = Double(box.minY - region.maxY)
            } else if box.maxY <= region.minY {
                distance = Double(region.minY - box.maxY)
            } else {
                continue
            }
            guard distance <= limit, distance < (best?.1 ?? .infinity) else { continue }
            best = (Found(caption: caption, box: box), distance)
        }
        return best?.0
    }

    /// Words a chart's caption or title uses (§1). They raise confidence; none is required.
    static let chartWords: Set<String> = [
        "chart", "charts", "curve", "curves", "graph", "graphs", "performance", "derating", "plot",
    ]

    static func hasChartWord(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).contains { chartWords.contains(String($0)) }
    }
}
