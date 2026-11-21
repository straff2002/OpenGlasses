import CoreGraphics
import Foundation
import UIKit

/// How much every picture sent to the Meta Display is shrunk before it goes (Plan MU §0). Pure,
/// apart from the stored readings and the one shrinking step.
///
/// **Why.** `MWDATDisplay.Image` has no size, only `.fill`, and on the simulated Display `.fill`
/// draws one image pixel per lens pixel; every lens picture is drawn on that basis. If a pair of
/// glasses draws pictures larger, a 576 px picture is cut off on the right. The fit check
/// (`LensFitCheck`) measures it: the wearer reads the highest number they can see whole on a ruler
/// numbered 1 to 12 across 576 px. Twelve is the simulator's size; fewer means the glasses scale
/// pictures up by about 12 / reading, and every picture is then shrunk by that factor before it is
/// sent, so it lands on the lens at the size it was drawn for.
///
/// **The table.** reading → factor is 12 / reading: 12 → 1, 9 → 1.33, 8 → 1.5, 6 → 2. A reading
/// under `lowestReading` is taken as `lowestReading` (a factor of 3 at most), since a smaller one
/// would only make every picture unreadably small.
///
/// **Per glasses model, default 1** (decision 10: single pictures already look right on the
/// tester's glasses). A model with no reading, and the Simulator, use 1. At 1 nothing changes: the
/// picture goes as drawn, the very same image (`scaled(_:by:)`).
enum LensPictureScale {

    /// What the fit check's ruler is numbered up to: a reading of all of it is factor 1.
    static let fullReading = 12
    /// The lowest reading taken; anything under it counts as this.
    static let lowestReading = 4

    /// One fit check's answer: the highest number read whole on the ruler, and how many of the
    /// three tiles were seen.
    struct Reading: Equatable {
        let highestNumber: Int
        let tilesSeen: Int

        /// The factor this reading sets.
        var factor: CGFloat { LensPictureScale.factor(reading: highestNumber) }

        /// Twelve and three: the glasses draw pictures as the simulator does.
        var matchesSimulator: Bool { highestNumber >= LensPictureScale.fullReading && tilesSeen >= LensFitCheck.tileCount }
    }

    /// The factor a ruler reading sets: 12 / reading, the reading taken between `lowestReading`
    /// and `fullReading`. Nil (no reading yet) is 1.
    static func factor(reading: Int?) -> CGFloat {
        guard let reading else { return 1 }
        let taken = min(max(reading, lowestReading), fullReading)
        return CGFloat(fullReading) / CGFloat(taken)
    }

    // MARK: - Stored readings, per glasses model

    static let readingsKey = "lensFitCheckReadings"
    static let tilesKey = "lensFitCheckTiles"
    /// The key a reading is kept under when the glasses' model isn't known.
    static let unknownModel = "unknown"

    static func modelKey(_ model: String?) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unknownModel : trimmed
    }

    /// The last fit check's reading for `model`, if one was taken.
    static func reading(for model: String?, in defaults: UserDefaults = .standard) -> Reading? {
        let key = modelKey(model)
        guard let highest = (defaults.dictionary(forKey: readingsKey) as? [String: Int])?[key] else { return nil }
        let tiles = (defaults.dictionary(forKey: tilesKey) as? [String: Int])?[key] ?? LensFitCheck.tileCount
        return Reading(highestNumber: highest, tilesSeen: tiles)
    }

    /// Keep `reading` for `model`, replacing the last one.
    static func store(_ reading: Reading, for model: String?, in defaults: UserDefaults = .standard) {
        let key = modelKey(model)
        var readings = (defaults.dictionary(forKey: readingsKey) as? [String: Int]) ?? [:]
        var tiles = (defaults.dictionary(forKey: tilesKey) as? [String: Int]) ?? [:]
        readings[key] = min(max(reading.highestNumber, 1), fullReading)
        tiles[key] = min(max(reading.tilesSeen, 0), LensFitCheck.tileCount)
        defaults.set(readings, forKey: readingsKey)
        defaults.set(tiles, forKey: tilesKey)
    }

    /// Forget every model's reading (back to factor 1).
    static func forgetAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: readingsKey)
        defaults.removeObject(forKey: tilesKey)
    }

    /// The factor for `model`: its stored reading's, or 1. Always 1 on the Simulator, whose
    /// simulated Display is what every picture size was measured on.
    static func factor(for model: String?, isSimulator: Bool = runsOnSimulator,
                       in defaults: UserDefaults = .standard) -> CGFloat {
        guard !isSimulator else { return 1 }
        return reading(for: model, in: defaults)?.factor ?? 1
    }

    static var runsOnSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The glasses model the Display is on now (AppState: the display service's backend). Nil
    /// when not known.
    @MainActor static var activeModel: @MainActor () -> String? = { nil }

    /// The factor for the glasses the Display is on now.
    @MainActor static func activeFactor() -> CGFloat { factor(for: activeModel()) }

    // MARK: - Shrinking

    /// The size a picture drawn at `size` is sent at under `factor`: divided by it, rounded down,
    /// at least one pixel. At 1 it is `size` itself.
    static func sentSize(_ size: CGSize, factor: CGFloat) -> CGSize {
        guard factor.isFinite, factor > 1 else { return size }
        return CGSize(width: max(1, (size.width / factor).rounded(.down)),
                      height: max(1, (size.height / factor).rounded(.down)))
    }

    /// `image` shrunk by `factor` for the lens. At 1 (or under) it is the very same image, so a
    /// picture at factor 1 is sent byte for byte as it was drawn.
    static func scaled(_ image: UIImage, by factor: CGFloat) -> UIImage {
        guard factor.isFinite, factor > 1 else { return image }
        let source = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let size = sentSize(source, factor: factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// One line for the support report: "576×426 ×3, 576×600 ×2", the most common first.
    static func sizesSummary(_ sizes: [String]) -> String {
        guard !sizes.isEmpty else { return "none" }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for size in sizes {
            if counts[size] == nil { order.append(size) }
            counts[size, default: 0] += 1
        }
        // Most common first; a tie keeps the order they were first sent in.
        return order.enumerated()
            .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
            .map { "\($0.element) ×\(counts[$0.element] ?? 0)" }
            .joined(separator: ", ")
    }

    /// "576×426".
    static func sizeText(_ size: CGSize) -> String { "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))" }

    /// "1", "1.33".
    static func factorText(_ factor: CGFloat) -> String {
        let rounded = (Double(factor) * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }
}
