import Foundation

/// Deterministic plausibility bands for instrument readings (W08.4).
///
/// A model that misreads a display rarely says so: it returns a number, with a confidence, in the
/// right unit, and everything downstream treats it as a reading. The confidence floor catches the
/// case where the model doubts itself; nothing caught the case where it was confidently wrong by an
/// order of magnitude. A clinical thermometer reporting 250 °C is not a low-confidence reading, it
/// is an impossible one, and the app used to speak it.
///
/// The bands are deliberately wide. This is not a diagnostic range check and must never be read as
/// one — a value inside the band is not thereby correct, and the app says nothing about it. The band
/// only asks whether the instrument this reading claims to come from can produce that number at all.
/// Where the quantity is not recognised the answer is "no opinion", not "plausible".
///
/// Pure and headless, applied through `AssessmentSchema.applyingReadingPolicy` — the same helper
/// that already turns a low-confidence reading into a re-capture — so a vertical picks it up by
/// calling the shared policy rather than by knowing this type exists.
enum InstrumentPlausibility {

    /// The inclusive band for a quantity, in the unit named alongside it. `nil` means the quantity
    /// is not one this table has an opinion about.
    struct Band {
        let low: Double
        let high: Double
        /// The canonical unit the band is expressed in, or `nil` when the band applies to the value
        /// exactly as displayed (percentages, rates — quantities `UnitNormalizer` does not convert).
        let canonicalUnit: String?
    }

    /// Matched as substrings of the lowercased `quantity`, most specific first — "body temperature"
    /// has to win over "temperature".
    private static let bands: [(match: String, band: Band)] = [
        ("body temperature", Band(low: 15, high: 45, canonicalUnit: "°C")),
        ("patient temperature", Band(low: 15, high: 45, canonicalUnit: "°C")),
        ("spo2", Band(low: 40, high: 100, canonicalUnit: nil)),
        ("oxygen saturation", Band(low: 40, high: 100, canonicalUnit: nil)),
        ("heart rate", Band(low: 10, high: 300, canonicalUnit: nil)),
        ("pulse", Band(low: 10, high: 300, canonicalUnit: nil)),
        ("respiratory rate", Band(low: 2, high: 80, canonicalUnit: nil)),
        ("blood pressure", Band(low: 20, high: 320, canonicalUnit: nil)),
        ("humidity", Band(low: 0, high: 100, canonicalUnit: nil)),
        ("brix", Band(low: 0, high: 95, canonicalUnit: "°Bx")),
        // Physical floors and ceilings, not instrument specifications: below absolute zero, a
        // negative absolute pressure or a negative mass are readings no instrument can produce.
        ("temperature", Band(low: -273.15, high: 3000, canonicalUnit: "°C")),
        ("pressure", Band(low: -101.4, high: 200_000, canonicalUnit: "kPa")),
        ("weight", Band(low: 0, high: 200_000, canonicalUnit: "kg")),
        ("mass", Band(low: 0, high: 200_000, canonicalUnit: "kg")),
    ]

    static func band(forQuantity quantity: String) -> Band? {
        let q = quantity.lowercased()
        return bands.first { q.contains($0.match) }?.band
    }

    /// True when the table has an opinion about this reading and the reading is outside it.
    /// An unrecognised quantity, or one whose unit will not convert into the band's, is `false`:
    /// no opinion is not the same as an objection.
    static func isImplausible(_ reading: InstrumentReading) -> Bool {
        guard let band = band(forQuantity: reading.quantity) else { return false }
        let value: Double
        if let canonicalUnit = band.canonicalUnit {
            guard let converted = UnitNormalizer.convert(reading.value, from: reading.unit, to: canonicalUnit)
                    ?? (reading.canonicalUnit == canonicalUnit ? reading.canonical : nil) else { return false }
            value = converted
        } else {
            value = reading.value
        }
        return value < band.low || value > band.high
    }

    /// The re-capture line for an implausible reading. Says what is wrong with it — a wearer told
    /// only "re-capture" will re-capture the same misread display the same way.
    static func recaptureLine(for reading: InstrumentReading) -> String {
        "Re-capture the \(reading.quantity) display — \(Self.format(reading.value)) \(reading.unit) is outside what that instrument can read."
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
