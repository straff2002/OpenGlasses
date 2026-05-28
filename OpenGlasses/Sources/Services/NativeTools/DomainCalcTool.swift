import Foundation

/// Refrigeration domain math: PT-chart lookup, superheat, and subcooling.
///
/// The PT anchor points are kept identical to the vault's `pt_charts.md` so the tool never
/// contradicts the grounded reference material. Values are linearly interpolated between anchors;
/// pressures outside the tabulated range return a referral to the chart rather than an extrapolated
/// (fabricated) figure.
@MainActor
final class DomainCalcTool: NativeTool {
    let name = "domain_calc"
    let description = """
    Refrigeration calculations grounded in the vault PT charts. Operations: 'pt_lookup' (saturation \
    temperature for a refrigerant at a gauge pressure), 'superheat' (suction line temp minus saturation \
    temp at suction pressure), 'subcool' (saturation temp at liquid pressure minus liquid line temp). \
    Temperatures in °F, pressures in PSIG.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "operation": [
                "type": "string",
                "description": "'pt_lookup', 'superheat', or 'subcool'."
            ],
            "refrigerant": [
                "type": "string",
                "description": "Refrigerant designation: 'R-410A', 'R-32', 'R-454B', or 'R-22'."
            ],
            "pressure_psig": [
                "type": "number",
                "description": "For 'pt_lookup': the gauge pressure to look up (PSIG)."
            ],
            "suction_pressure_psig": [
                "type": "number",
                "description": "For 'superheat': suction-side gauge pressure (PSIG)."
            ],
            "suction_line_temp_f": [
                "type": "number",
                "description": "For 'superheat': measured suction line temperature (°F)."
            ],
            "liquid_pressure_psig": [
                "type": "number",
                "description": "For 'subcool': liquid-side gauge pressure (PSIG)."
            ],
            "liquid_line_temp_f": [
                "type": "number",
                "description": "For 'subcool': measured liquid line temperature (°F)."
            ]
        ],
        "required": ["operation", "refrigerant"]
    ]

    // PT anchor points (pressure PSIG → saturation temp °F), matching pt_charts.md exactly.
    private static let ptTables: [String: [(psig: Double, tempF: Double)]] = [
        "R-410A": [(50, 8), (75, 23), (100, 31), (125, 44), (135, 47), (150, 54),
                   (175, 63), (200, 70), (250, 84), (300, 96), (400, 119), (450, 129)],
        "R-32":   [(50, 12), (100, 38), (135, 52), (150, 58), (200, 75), (250, 89),
                   (300, 102), (400, 124)],
        "R-454B": [(50, 9), (100, 35), (135, 49), (150, 55), (200, 73), (250, 87),
                   (300, 100), (400, 124)],
        "R-22":   [(50, 25), (75, 44), (100, 59), (125, 72), (150, 83), (200, 102),
                   (250, 117), (300, 130)]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let operation = (args["operation"] as? String)?.lowercased() else {
            return "Specify 'operation': 'pt_lookup', 'superheat', or 'subcool'."
        }
        guard let refrigerant = (args["refrigerant"] as? String).map(Self.normalize) else {
            return "Specify 'refrigerant' (e.g. 'R-410A')."
        }
        guard let table = Self.ptTables[refrigerant] else {
            return "No PT data for '\(refrigerant)'. Supported: \(Self.ptTables.keys.sorted().joined(separator: ", ")). Consult pt_charts.md."
        }

        switch operation {
        case "pt_lookup":
            guard let pressure = number(args["pressure_psig"]) else {
                return "Specify 'pressure_psig' for pt_lookup."
            }
            guard let temp = Self.saturationTemp(psig: pressure, table: table) else {
                return outOfRange(refrigerant, table: table)
            }
            return "\(refrigerant) saturation temperature at \(fmt(pressure)) PSIG ≈ \(fmt(temp))°F. (Source: pt_charts.md)"

        case "superheat":
            guard let pressure = number(args["suction_pressure_psig"]),
                  let lineTemp = number(args["suction_line_temp_f"]) else {
                return "Specify 'suction_pressure_psig' and 'suction_line_temp_f' for superheat."
            }
            guard let satTemp = Self.saturationTemp(psig: pressure, table: table) else {
                return outOfRange(refrigerant, table: table)
            }
            let superheat = lineTemp - satTemp
            return "Superheat ≈ \(fmt(superheat))°F (suction line \(fmt(lineTemp))°F − saturation \(fmt(satTemp))°F at \(fmt(pressure)) PSIG, \(refrigerant)). " +
                   "\(superheat < 0 ? "Negative superheat suggests liquid floodback — recheck readings. " : "")(Source: pt_charts.md, superheat_subcool.md)"

        case "subcool", "subcooling":
            guard let pressure = number(args["liquid_pressure_psig"]),
                  let lineTemp = number(args["liquid_line_temp_f"]) else {
                return "Specify 'liquid_pressure_psig' and 'liquid_line_temp_f' for subcool."
            }
            guard let satTemp = Self.saturationTemp(psig: pressure, table: table) else {
                return outOfRange(refrigerant, table: table)
            }
            let subcool = satTemp - lineTemp
            return "Subcooling ≈ \(fmt(subcool))°F (saturation \(fmt(satTemp))°F at \(fmt(pressure)) PSIG − liquid line \(fmt(lineTemp))°F, \(refrigerant)). " +
                   "\(subcool < 0 ? "Negative subcool suggests undercharge or flash gas — recheck. " : "")(Source: pt_charts.md, superheat_subcool.md)"

        default:
            return "Unknown operation '\(operation)'. Use 'pt_lookup', 'superheat', or 'subcool'."
        }
    }

    // MARK: - Interpolation

    /// Linearly interpolate saturation temp for a gauge pressure. Returns nil outside the table range.
    static func saturationTemp(psig: Double, table: [(psig: Double, tempF: Double)]) -> Double? {
        guard let first = table.first, let last = table.last else { return nil }
        if psig < first.psig || psig > last.psig { return nil }
        for i in 0..<(table.count - 1) {
            let lo = table[i], hi = table[i + 1]
            if psig >= lo.psig && psig <= hi.psig {
                if hi.psig == lo.psig { return lo.tempF }
                let fraction = (psig - lo.psig) / (hi.psig - lo.psig)
                return lo.tempF + fraction * (hi.tempF - lo.tempF)
            }
        }
        return nil
    }

    /// Normalize "410a", "R410A", "r-410a" → "R-410A".
    static func normalize(_ raw: String) -> String {
        let upper = raw.uppercased().replacingOccurrences(of: " ", with: "")
        let digits = upper.replacingOccurrences(of: "R", with: "").replacingOccurrences(of: "-", with: "")
        return "R-\(digits)"
    }

    // MARK: - Helpers

    private func outOfRange(_ refrigerant: String, table: [(psig: Double, tempF: Double)]) -> String {
        guard let lo = table.first, let hi = table.last else { return "Pressure out of range." }
        return "Pressure is outside the tabulated \(refrigerant) range (\(fmt(lo.psig))–\(fmt(hi.psig)) PSIG). Consult a calibrated PT chart (pt_charts.md)."
    }

    private func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func fmt(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
