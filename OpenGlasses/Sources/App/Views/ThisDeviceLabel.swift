import UIKit

/// The name and symbol of the device the app runs on, for the cards that say which device is in
/// use: "This iPad" on an iPad, "This iPhone" otherwise.
enum ThisDeviceLabel {
    static func title(isPad: Bool) -> String {
        isPad ? String(localized: "This iPad") : String(localized: "This iPhone")
    }

    static func symbol(isPad: Bool) -> String {
        isPad ? "ipad" : "iphone"
    }

    @MainActor static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor static var title: String { title(isPad: isPad) }
    @MainActor static var symbol: String { symbol(isPad: isPad) }
}
