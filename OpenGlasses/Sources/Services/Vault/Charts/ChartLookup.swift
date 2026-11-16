import Foundation

/// A value read off a chart (Plan LX §3, §5). Approximate by type: it carries `about` and the
/// `step` it was rounded to, and it can only be made here, by `ChartLookup`, from a reading the
/// validator accepted — there is no initialiser from a plain number, so nothing can hand a chart's
/// value on as though it were printed.
struct ChartValue: Equatable {
    /// The value, rounded to `step`.
    let about: Double
    /// The reading's resolution on the value's axis: half its smallest tick interval.
    let step: Double
    /// The value's unit as the chart prints it, nil when it prints none.
    let unit: String?

    fileprivate init(rounding raw: Double, toStep step: Double, unit: String?) {
        self.step = step
        self.unit = unit
        self.about = step > 0 ? (raw / step).rounded() * step : raw
    }
}

/// Giving a value from a chart's reading (Plan LX §5): linear interpolation along a series, and for
/// a family between the two series that bracket the asked parameter; rounded to the step; never
/// extrapolated. Pure.
enum ChartLookup {

    enum Outside: String, Equatable {
        /// The x asked is beyond the axis's first or last tick.
        case xOutsideAxis = "x_outside_axis"
        /// The x asked is inside the axis but past the ends of the series drawn.
        case xOutsideSeries = "x_outside_series"
        /// The family parameter asked is beyond the lowest or highest series drawn.
        case parameterOutsideFamily = "parameter_outside_family"
    }

    enum Result: Equatable {
        /// A value, and the printed note of a shaded band it falls inside, when it does.
        case value(ChartValue, bandNote: String?)
        /// The chart does not reach what was asked; the answer says so and gives nothing.
        case outsideChart(Outside)
        /// No series by that label, or the reading draws none.
        case noSuchSeries
    }

    /// The y value of the series labelled `series` at `x`.
    static func value(in validated: ValidatedChartReading, series label: String, at x: Double) -> Result {
        let reading = validated.reading
        guard let series = reading.series.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
            return .noSuchSeries
        }
        return value(in: reading, along: [series], at: x) { _ in 0 }
    }

    /// The y value at `x` for the family parameter `parameter` (wet bulb 64 between the 62 and 67
    /// curves). A reading of one series answers for that series alone.
    static func value(in validated: ValidatedChartReading, parameter: Double, at x: Double) -> Result {
        let reading = validated.reading
        let family = reading.series.filter { $0.parameter != nil }.sorted { $0.parameter! < $1.parameter! }
        guard let low = family.first?.parameter, let high = family.last?.parameter else { return .noSuchSeries }
        guard parameter >= low - 1e-9, parameter <= high + 1e-9 else { return .outsideChart(.parameterOutsideFamily) }
        if let exact = family.first(where: { ChartReadingValidator.same($0.parameter!, parameter) }) {
            return value(in: reading, along: [exact], at: x) { _ in 0 }
        }
        guard let upper = family.firstIndex(where: { $0.parameter! > parameter }), upper > 0 else { return .noSuchSeries }
        let a = family[upper - 1], b = family[upper]
        let weight = (parameter - a.parameter!) / (b.parameter! - a.parameter!)
        return value(in: reading, along: [a, b], at: x) { values in values[0] + weight * (values[1] - values[0]) }
    }

    /// `x` interpolated along each of `series`, combined by `combine` (one series: the value itself).
    private static func value(in reading: ChartReading, along series: [ChartReading.Series], at x: Double,
                              combine: ([Double]) -> Double) -> Result {
        guard let xAxis = reading.axis(.x), let range = xAxis.range,
              let yAxis = reading.axis(.y), let step = yAxis.step else { return .noSuchSeries }
        guard x >= range.lowerBound - 1e-9, x <= range.upperBound + 1e-9 else { return .outsideChart(.xOutsideAxis) }
        var values: [Double] = []
        for one in series {
            guard let y = interpolate(one.points, at: x, logX: xAxis.scale == .logarithmic,
                                      logY: yAxis.scale == .logarithmic) else {
                return .outsideChart(.xOutsideSeries)
            }
            values.append(y)
        }
        let raw = series.count == 1 ? values[0] : combine(values)
        let value = ChartValue(rounding: raw, toStep: step, unit: yAxis.unit)
        let band = reading.bands.first { band in
            (band.x.map { $0.contains(x) } ?? true) && (band.y.map { $0.contains(value.about) } ?? true)
                && (band.x != nil || band.y != nil)
        }
        return .value(value, bandNote: band?.note)
    }

    /// Linear interpolation between the two points either side of `x` (in log space on a
    /// logarithmic axis); nil past either end of the points.
    static func interpolate(_ points: [ChartReading.Point], at x: Double, logX: Bool = false, logY: Bool = false) -> Double? {
        let sorted = points.sorted { $0.x < $1.x }
        guard let first = sorted.first, let last = sorted.last, x >= first.x - 1e-9, x <= last.x + 1e-9 else { return nil }
        if let exact = sorted.first(where: { ChartReadingValidator.same($0.x, x) }) { return exact.y }
        guard let upper = sorted.firstIndex(where: { $0.x > x }), upper > 0 else { return nil }
        let a = sorted[upper - 1], b = sorted[upper]
        func fx(_ v: Double) -> Double { logX && v > 0 ? log10(v) : v }
        let t = (fx(x) - fx(a.x)) / (fx(b.x) - fx(a.x))
        if logY, a.y > 0, b.y > 0 { return pow(10, log10(a.y) + t * (log10(b.y) - log10(a.y))) }
        return a.y + t * (b.y - a.y)
    }
}
