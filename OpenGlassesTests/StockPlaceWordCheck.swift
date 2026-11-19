import Foundation
@testable import OpenGlasses

/// The words a place must never say about itself (Plan MK Tests): a store says none of a
/// vehicle's, a van none of a building's, and the neutral `stock` no place noun at all.
enum StockPlaceWordCheck {

    static func forbidden(for kind: StockPlace.Kind) -> [String] {
        switch kind {
        case .van, .truck: return ["store", "warehouse", "par"]
        case .store, .warehouse: return ["van", "truck", "base", "load", "loaded", "loads", "standard load", "on board"]
        case .stock: return ["van", "truck", "base", "load", "loaded", "loads", "standard load", "on board",
                             "store", "warehouse"]
        }
    }

    /// The forbidden words `text` says as whole words, ignoring case. A quoted contract value
    /// ('load', 'send_to_base') is an identifier the model passes back, not a word it says, so it
    /// is left out; so is a snake_case name such as `van_stock`.
    static func violations(_ text: String, kind: StockPlace.Kind) -> [String] {
        let unquoted = text.replacingOccurrences(of: "'[a-z_]+'", with: " ", options: .regularExpression)
        return forbidden(for: kind).filter { word in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            return unquoted.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
