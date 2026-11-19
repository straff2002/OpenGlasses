@testable import OpenGlasses

extension StockQuantity {
    /// Whole units, for tests written in whole numbers: `.whole(4)` is 4,000 thousandths.
    static func whole(_ units: Int) -> StockQuantity { StockQuantity(whole: units) }
}
