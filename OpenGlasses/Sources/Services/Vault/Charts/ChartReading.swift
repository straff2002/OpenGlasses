import Foundation

/// A chart on a manual page written out as data (Plan LX §3): its axes as printed, its series as
/// points, and anything printed inside the plot area. Pure and `Codable`: the cache (§9) stores it,
/// the validator checks it, and every value that leaves it is a [[ChartValue]], approximate by type.
///
/// Nothing in the app fills one from a picture yet — reading a chart (§2, P1) needs a model, and
/// where the picture may go is still an open decision. Today a reading is only ever written by hand,
/// in tests, so the parts that use one (validation, lookup, wording, precedence, caching) are proven
/// before any model is asked.
struct ChartReading: Codable, Equatable {

    /// What the chart draws, decided when it is read (§1).
    enum Kind: String, Codable, Equatable {
        /// One or more series over x.
        case lines
        /// A series per value of a third input, as a charging chart draws one curve per wet bulb.
        case family
        case bars
        case other
    }

    enum AxisRole: String, Codable, Equatable, CaseIterable {
        case x
        case y
        /// A second y axis, printed on the plot's right.
        case secondY = "second_y"
    }

    enum Scale: String, Codable, Equatable {
        case linear
        case logarithmic
        case unknown
    }

    struct Axis: Codable, Equatable {
        var role: AxisRole
        /// The axis title as printed ("Outdoor temperature").
        var title: String
        /// The unit as printed or read ("°F"); nil when the chart prints none.
        var unit: String?
        /// The tick values as printed, in the order the axis runs.
        var ticks: [Double]
        var scale: Scale

        init(role: AxisRole, title: String, unit: String? = nil, ticks: [Double], scale: Scale = .linear) {
            self.role = role
            self.title = title
            self.unit = unit
            self.ticks = ticks
            self.scale = scale
        }

        /// Lowest to highest tick; nil for an axis with no ticks.
        var range: ClosedRange<Double>? {
            guard let low = ticks.min(), let high = ticks.max() else { return nil }
            return low...high
        }

        /// The reading's resolution on this axis: half the smallest interval between two ticks.
        /// Every value given from the chart is rounded to it. Nil with fewer than two ticks.
        var step: Double? {
            let sorted = ticks.sorted()
            let gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
            return gaps.min().map { $0 / 2 }
        }
    }

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double

        init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    struct Series: Codable, Equatable {
        /// The series' label as printed ("67", "Low speed").
        var label: String
        /// For a family, the third input's value this series is drawn for (wet bulb 67).
        var parameter: Double?
        var points: [Point]

        init(label: String, parameter: Double? = nil, points: [Point]) {
            self.label = label
            self.parameter = parameter
            self.points = points
        }
    }

    /// A shaded band printed inside the plot area ("Do not charge below 55 °F"), over the x and,
    /// where the band is bounded that way, the y it covers.
    struct Band: Codable, Equatable {
        var note: String
        var x: ClosedRange<Double>?
        var y: ClosedRange<Double>?

        init(note: String, x: ClosedRange<Double>? = nil, y: ClosedRange<Double>? = nil) {
            self.note = note
            self.x = x
            self.y = y
        }
    }

    /// Where the reading came from and how it was made (§3, §9).
    struct Source: Codable, Equatable {
        var documentId: String
        /// The physical page, and the number printed on it where known.
        var page: ManualTable.Page
        var figure: String?
        /// SHA-256 of the exact image read, and of the exact prompt it was read with.
        var imageHash: String
        var promptHash: String
        var promptVersion: Int
        /// The model that read it. Recorded, not part of the cache key (decision 7).
        var modelId: String
        var date: Date

        init(documentId: String, page: ManualTable.Page, figure: String? = nil, imageHash: String = "",
             promptHash: String = "", promptVersion: Int = 1, modelId: String = "", date: Date = Date(timeIntervalSince1970: 0)) {
            self.documentId = documentId
            self.page = page
            self.figure = figure
            self.imageHash = imageHash
            self.promptHash = promptHash
            self.promptVersion = promptVersion
            self.modelId = modelId
            self.date = date
        }
    }

    var kind: Kind
    var axes: [Axis]
    var series: [Series]
    /// For a family, what the third input is called as printed ("Indoor wet bulb (°F)").
    var familyTitle: String?
    var bands: [Band]
    /// Anything else printed inside the plot area.
    var notes: [String]
    var source: Source

    init(kind: Kind, axes: [Axis], series: [Series], familyTitle: String? = nil, bands: [Band] = [],
         notes: [String] = [], source: Source) {
        self.kind = kind
        self.axes = axes
        self.series = series
        self.familyTitle = familyTitle
        self.bands = bands
        self.notes = notes
        self.source = source
    }

    func axis(_ role: AxisRole) -> Axis? { axes.first { $0.role == role } }

    /// The reading's resolution per axis (§3): half the smallest tick interval.
    func step(_ role: AxisRole) -> Double? { axis(role)?.step }
}

// MARK: - The validator

/// Whether a reading may give a value, may only be indexed for its words, or must be dropped
/// (Plan LX §3). Every check ties the reading back to what the page prints, because a model reading
/// a picture can be confidently wrong and nothing else stands between that and a technician.
enum ChartReadingValidator {

    /// Why a reading is dropped or kept for its words only.
    enum Reason: String, Codable, Equatable {
        /// An axis's lowest or highest tick is not among the numbers the page prints in that run.
        case ticksNotOnPage = "ticks_not_on_page"
        /// An axis has no unit, printed or read: words only.
        case unitMissing = "unit_missing"
        /// A point falls outside the axes by more than one step.
        case pointOutsideAxes = "point_outside_axes"
        /// A series of a lines or family chart goes back on itself.
        case seriesNotMonotonic = "series_not_monotonic"
        /// A logarithmic axis with a tick at or below zero, or ticks not a constant ratio apart.
        case logarithmicAxisInvalid = "log_axis_invalid"
        /// More series than any chart in a manual draws: a misread.
        case tooManySeries = "too_many_series"
        /// More points in a series than any chart in a manual draws: a misread.
        case tooManyPoints = "too_many_points"
        /// No x axis, or no y axis.
        case axisMissing = "axis_missing"
    }

    enum Warning: String, Codable, Equatable {
        /// A family's series label is not a number, or is not printed in the chart's region.
        case familyLabelNotOnPage = "family_label_not_on_page"
    }

    enum Verdict: Equatable {
        /// May give values, through `ChartLookup`.
        case usable(ValidatedChartReading)
        /// Indexed for its words; never gives a value.
        case wordsOnly([Reason])
        /// Not used at all.
        case rejected([Reason])

        var validated: ValidatedChartReading? {
            if case .usable(let reading) = self { return reading }
            return nil
        }
    }

    static let maximumSeries = 12
    static let maximumPoints = 60
    /// How far two log-axis tick ratios may differ and still be "constant".
    static let logRatioTolerance = 0.02

    static func check(_ reading: ChartReading, against candidate: ChartCandidate) -> Verdict {
        var rejected: [Reason] = []
        var wordsOnly: [Reason] = []
        func reject(_ reason: Reason) { if !rejected.contains(reason) { rejected.append(reason) } }

        guard let x = reading.axis(.x), let y = reading.axis(.y), x.range != nil, y.range != nil else {
            return .rejected([.axisMissing])
        }
        // Bounds first: a reading this large is a misread whatever else it says.
        if reading.series.count > maximumSeries { reject(.tooManySeries) }
        if reading.series.contains(where: { $0.points.count > maximumPoints }) { reject(.tooManyPoints) }

        // Every axis's lowest and highest tick are among the numbers recognised in that run.
        for axis in reading.axes {
            guard let range = axis.range else { reject(.ticksNotOnPage); continue }
            let printed = candidate.axis(axis.role)?.values ?? []
            if !printed.contains(where: { same($0, range.lowerBound) }) || !printed.contains(where: { same($0, range.upperBound) }) {
                reject(.ticksNotOnPage)
            }
            if axis.scale == .logarithmic, !isLogarithmic(axis.ticks) { reject(.logarithmicAxisInvalid) }
            let printedUnit = candidate.axis(axis.role)?.unit
            if (axis.unit ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
               (printedUnit ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
               !wordsOnly.contains(.unitMissing) {
                wordsOnly.append(.unitMissing)
            }
        }

        // Points inside the axes, within one step.
        let xRange = x.range!, yRange = y.range!
        let xStep = x.step ?? 0, yStep = y.step ?? 0
        for series in reading.series {
            for point in series.points
            where point.x < xRange.lowerBound - xStep || point.x > xRange.upperBound + xStep
                || point.y < yRange.lowerBound - yStep || point.y > yRange.upperBound + yStep {
                reject(.pointOutsideAxes)
            }
        }

        // x increases along each series; a repeated x merges only when its y values agree.
        var merged = reading
        if reading.kind == .lines || reading.kind == .family {
            for index in merged.series.indices {
                guard let points = mergedPoints(merged.series[index].points, yStep: yStep) else {
                    reject(.seriesNotMonotonic)
                    continue
                }
                merged.series[index].points = points
            }
        }

        guard rejected.isEmpty else { return .rejected(rejected) }
        guard wordsOnly.isEmpty else { return .wordsOnly(wordsOnly) }

        // A family's labels are numbers printed in the region; a missing one only warns.
        var warnings: [Warning] = []
        if reading.kind == .family {
            let printed = candidate.insideNumbers
            for series in reading.series {
                guard let parameter = series.parameter, printed.contains(where: { same($0, parameter) }) else {
                    warnings.append(.familyLabelNotOnPage)
                    break
                }
            }
        }
        return .usable(ValidatedChartReading(reading: merged, warnings: warnings))
    }

    /// The points with each repeated x merged, or nil when x goes backwards or a repeat's y values
    /// are more than a step apart.
    static func mergedPoints(_ points: [ChartReading.Point], yStep: Double) -> [ChartReading.Point]? {
        var out: [ChartReading.Point] = []
        for point in points {
            guard let last = out.last else { out.append(point); continue }
            if point.x < last.x { return nil }
            if same(point.x, last.x) {
                guard abs(point.y - last.y) <= yStep + 1e-9 else { return nil }
                out[out.count - 1] = .init(last.x, (last.y + point.y) / 2)
            } else {
                out.append(point)
            }
        }
        return out
    }

    /// Positive ticks, each a constant ratio from the last.
    static func isLogarithmic(_ ticks: [Double]) -> Bool {
        guard ticks.count >= 2, ticks.allSatisfy({ $0 > 0 }) else { return false }
        let sorted = ticks.sorted()
        let ratios = zip(sorted, sorted.dropFirst()).map { $1 / $0 }
        guard let first = ratios.first, first > 1 else { return false }
        return ratios.allSatisfy { abs($0 - first) / first <= logRatioTolerance }
    }

    static func same(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(1e-9, 1e-6 * max(abs(a), abs(b)))
    }
}

/// A reading the validator accepted (`ChartReadingValidator.Verdict.usable`). The only thing
/// `ChartLookup` takes, so a value can only come from a chart that read cleanly against its page.
struct ValidatedChartReading: Equatable {
    let reading: ChartReading
    let warnings: [ChartReadingValidator.Warning]

    fileprivate init(reading: ChartReading, warnings: [ChartReadingValidator.Warning]) {
        self.reading = reading
        self.warnings = warnings
    }
}
