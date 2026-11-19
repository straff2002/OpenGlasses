import Foundation

/// How a stocktake count compares with the figure the log held just before it.
///
/// Nil when there was nothing to compare with: a new line, or one nothing had set yet — that count
/// is the opening figure. Pure, so the read-back and the "Say:" line agree.
enum VanStockCountCheck: Equatable, Sendable {
    case matches(expected: StockQuantity)
    case short(expected: StockQuantity, by: StockQuantity)
    case over(expected: StockQuantity, by: StockQuantity)
    /// The log's figure was marked unreliable, so it is no yardstick.
    case unreliable

    init?(before: VanStockLevel, counted: StockQuantity) {
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

    /// The tail of the "Say:" line: ", 2 short of the 18 expected", ", 0.25 litres short of the 4.5
    /// litres expected".
    func said(_ unit: VanStockUnit) -> String {
        switch self {
        case .matches: return ", as expected"
        case .short(let expected, let by): return ", \(unit.spoken(by)) short of the \(unit.spoken(expected)) expected"
        case .over(let expected, let by): return ", \(unit.spoken(by)) over the \(unit.spoken(expected)) expected"
        case .unreliable: return ", replacing a figure that could not be trusted"
        }
    }
}
