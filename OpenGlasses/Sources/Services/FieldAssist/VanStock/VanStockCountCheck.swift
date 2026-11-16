import Foundation

/// How a stocktake count compares with the figure the log held just before it.
///
/// Nil when there was nothing to compare with: a new line, or one nothing had set yet — that count
/// is the opening figure. Pure, so the read-back and the "Say:" line agree.
enum VanStockCountCheck: Equatable, Sendable {
    case matches(expected: Int)
    case short(expected: Int, by: Int)
    case over(expected: Int, by: Int)
    /// The log's figure was marked unreliable, so it is no yardstick.
    case unreliable

    init?(before: VanStockLevel, counted: Int) {
        guard before.isRecorded else { return nil }
        if before.unreliable {
            self = .unreliable
        } else if counted == before.onHand {
            self = .matches(expected: counted)
        } else if counted < before.onHand {
            self = .short(expected: before.onHand, by: before.onHand - counted)
        } else {
            self = .over(expected: before.onHand, by: counted - before.onHand)
        }
    }

    /// The tail of the "Say:" line: ", 2 short of the 18 expected".
    func said(_ unit: VanStockUnit) -> String {
        switch self {
        case .matches: return ", as expected"
        case .short(let expected, let by): return ", \(unit.amount(by)) short of the \(unit.amount(expected)) expected"
        case .over(let expected, let by): return ", \(unit.amount(by)) over the \(unit.amount(expected)) expected"
        case .unreliable: return ", replacing a figure that could not be trusted"
        }
    }
}

extension VanStockUnit {
    /// A bare quantity in this unit, for comparisons: "2", "10 m", "1 pack".
    func amount(_ quantity: Int) -> String {
        switch self {
        case .each: return "\(quantity)"
        case .pack: return "\(quantity) \(quantity == 1 ? "pack" : "packs")"
        case .m, .ft, .kg, .lb, .l: return "\(quantity) \(rawValue)"
        }
    }
}
