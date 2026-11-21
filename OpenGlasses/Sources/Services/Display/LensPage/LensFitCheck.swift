import Combine
import CoreGraphics
import Foundation
import UIKit

/// The fit check (Plan MU §0): one lens screen that shows whether the glasses draw a picture at the
/// size it was drawn for. Pure: the screen and its two pictures, and the spoken answer.
///
/// The screen is two pictures, one a row (nothing on the Meta Display puts two pictures side by
/// side):
/// - **the ruler**, exactly `rulerWidth` (576 px, the lens column) wide, numbered 1 to 12 across,
///   one number every `numberSpacing` (48 px);
/// - under it, **the tiles**: three numbered `tileWidth` (186 px) boxes, drawn as one picture.
///
/// The wearer says, or picks on the phone, the highest number they read whole and how many tiles
/// they see. Twelve and three means the glasses match the simulator; fewer numbers means they
/// scale pictures up, and `LensPictureScale` shrinks every picture by 12 / reading from then on.
///
/// Its pictures are sent as drawn (`HUDPicture.scalesForLens == false`): the check measures the
/// glasses, not the factor a previous check set.
enum LensFitCheck {
    static let numbers = 12
    static let numberSpacing: CGFloat = 48
    static var rulerWidth: CGFloat { CGFloat(numbers) * numberSpacing }
    static let rulerHeight: CGFloat = 64
    static let tileCount = 3
    static let tileWidth: CGFloat = 186
    static let tilesHeight: CGFloat = 120

    enum ItemID {
        static let close = "mu.fit.close"
        static let ruler = "mu.fit.ruler"
        static let tiles = "mu.fit.tiles"
    }

    /// Where number `n` (1-based) is centred on the ruler, in its pixels.
    static func numberCentre(_ n: Int) -> CGFloat { (CGFloat(n) - 0.5) * numberSpacing }

    /// The tiles' left edges: three boxes with equal gaps filling the ruler's width.
    static var tileOrigins: [CGFloat] {
        let gap = (rulerWidth - CGFloat(tileCount) * tileWidth) / CGFloat(max(1, tileCount - 1))
        return (0..<tileCount).map { CGFloat($0) * (tileWidth + gap) }
    }

    /// The ruler: white numbers on black (clear on the lens), a tick under each, a frame round the
    /// whole width so its right edge shows.
    static func rulerImage() -> UIImage {
        draw(size: CGSize(width: rulerWidth, height: rulerHeight)) { context, size in
            frame(CGRect(origin: .zero, size: size), in: context)
            for n in 1...numbers {
                let centre = numberCentre(n)
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(x: centre - 1, y: size.height - 16, width: 2, height: 10))
                label("\(n)", centredAt: CGPoint(x: centre, y: 24), size: 24, in: context)
            }
        }
    }

    /// The three tiles, as one picture.
    static func tilesImage() -> UIImage {
        draw(size: CGSize(width: rulerWidth, height: tilesHeight)) { context, size in
            for (index, x) in tileOrigins.enumerated() {
                let box = CGRect(x: x, y: 0, width: tileWidth, height: size.height)
                frame(box, in: context)
                label("\(index + 1)", centredAt: CGPoint(x: box.midX, y: box.midY), size: 44, in: context)
            }
        }
    }

    /// The fit-check screen: a short instruction, the ruler, the tiles, and **Close**.
    static func screen(onClose: @escaping () -> Void) -> HUDScreen {
        var screen = HUDScreen(
            title: nil,
            lines: [HUDLine(String(localized: "Fit check", comment: "Glasses: the title of the screen that checks how pictures fit the lens."),
                            emphasis: .meta),
                    HUDLine(String(localized: "Say the highest number you can read whole, and how many boxes you see.",
                                   comment: "Glasses: the fit check's instruction."),
                            emphasis: .secondary)],
            items: [HUDItem(id: ItemID.close, label: String(localized: "Close"), style: .outline, action: onClose)])
        var ruler = HUDPicture(image: rulerImage(), pixelSize: CGSize(width: rulerWidth, height: rulerHeight),
                               contentKey: "mu.fit.ruler.v1")
        ruler.scalesForLens = false
        var tiles = HUDPicture(image: tilesImage(), pixelSize: CGSize(width: rulerWidth, height: tilesHeight),
                               contentKey: "mu.fit.tiles.v1")
        tiles.scalesForLens = false
        screen.flow = [
            .blocks([HUDBlock(id: ItemID.ruler, picture: ruler, style: .plain)]),
            .blocks([HUDBlock(id: ItemID.tiles, picture: tiles, style: .plain)]),
        ]
        return screen
    }

    // MARK: - Drawing

    private static func draw(size: CGSize, _ body: (CGContext, CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.black.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            body(renderer.cgContext, size)
        }
    }

    private static func frame(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
    }

    private static func label(_ text: String, centredAt point: CGPoint, size: CGFloat, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let string = text as NSString
        let measured = string.size(withAttributes: attributes)
        string.draw(at: CGPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2),
                    withAttributes: attributes)
    }
}

/// The fit check's spoken answer (Plan MU §0): "twelve and three", "I can read 9, two boxes".
/// The first number is the highest read whole, the second how many tiles were seen. Pure.
enum LensFitCheckAnswer {
    private static let words: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]
    /// Words that count only as the second number ("twelve and no boxes", "nine and a box").
    private static let tileWords: [String: Int] = ["a": 1, "an": 1, "no": 0, "none": 0, "zero": 0]
    /// The only other words an answer is made of ("I can read nine, and two boxes"). Anything else
    /// ("what is on page four") is not an answer and goes on to the page view or the model, even
    /// though it holds a number.
    private static let fillerWords: Set<String> = [
        "i", "m", "can", "could", "read", "see", "saw", "seeing", "it", "s", "is", "its", "that",
        "the", "up", "to", "and", "of", "them", "all", "only", "just", "whole", "highest", "number",
        "numbers", "box", "boxes", "tile", "tiles", "with", "plus", "there", "are", "um", "uh",
        "ok", "okay", "so", "about",
    ]

    /// The numbers in `text`, in order; nil unless the first is a ruler number (1–12) and every
    /// other word is one an answer is made of. A missing second number is nil.
    static func parse(_ text: String) -> (highest: Int, tiles: Int?)? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var numbers: [Int] = []
        for token in tokens {
            if let value = Int(token) ?? words[token] {
                numbers.append(value)
            } else if numbers.count == 1, let value = tileWords[token] {
                numbers.append(value)
            } else if !fillerWords.contains(token), tileWords[token] == nil {
                return nil
            }
        }
        guard let first = numbers.first, (1...LensFitCheck.numbers).contains(first) else { return nil }
        let tiles = numbers.dropFirst().first.map { min(max($0, 0), LensFitCheck.tileCount) }
        return (first, tiles)
    }
}

/// Runs the fit check on the glasses (Plan MU §0): puts its screen up, takes the answer from the
/// phone or the voice, keeps it per glasses model (`LensPictureScale`), and ends.
@MainActor
final class LensFitCheckSession: ObservableObject {

    private let display: GlassesDisplayService
    private let defaults: UserDefaults
    weak var router: HUDRouter?
    /// The glasses model the reading is kept for (AppState: the display's backend).
    var model: @MainActor () -> String? = { LensPictureScale.activeModel() }

    @Published private(set) var isRunning = false
    @Published private(set) var refusal: BandPracticeRefusal?
    /// The last reading for the glasses now on, from the store.
    @Published private(set) var lastReading: LensPictureScale.Reading?

    private var shownScreen: HUDScreen?

    init(display: GlassesDisplayService, defaults: UserDefaults = .standard) {
        self.display = display
        self.defaults = defaults
        lastReading = LensPictureScale.reading(for: nil, in: defaults)
    }

    /// Whether the fit check's screen is the one held on the lens.
    var ownsLens: Bool {
        guard let shownScreen, display.isInteractive else { return false }
        return display.heldScreenRenderKey == shownScreen.renderKey
    }

    /// Re-read the stored reading for the glasses now on.
    func refresh() {
        lastReading = LensPictureScale.reading(for: model(), in: defaults)
    }

    @discardableResult
    func start() -> BandPracticeRefusal? {
        refresh()
        if let reason = startRefusal() {
            refusal = reason
            return reason
        }
        refusal = nil
        if router?.isPresentingMenu == true { router?.dismiss() }
        let screen = LensFitCheck.screen { [weak self] in self?.stop() }
        shownScreen = screen
        isRunning = true
        display.present(screen: screen) { [weak self] id in
            guard let self, id == LensFitCheck.ItemID.close else { return }
            self.stop()
        }
        return nil
    }

    private func startRefusal() -> BandPracticeRefusal? {
        guard Config.glassesDisplayEnabled else { return .hudOff }
        if router?.isPresentingTask == true { return .taskRunning }
        switch display.practiceAvailability {
        case .ours: return nil
        case .inUse: return .displayInUse
        case .off: return .displayOff
        }
    }

    /// End the check: its screen comes off the lens, if it is still the one held.
    func stop() {
        guard isRunning else { return }
        let wasOnLens = ownsLens
        isRunning = false
        shownScreen = nil
        if wasOnLens { display.endInteractive() }
    }

    /// Keep the wearer's answer for the glasses now on, and end the check.
    func record(highest: Int, tiles: Int) {
        let reading = LensPictureScale.Reading(highestNumber: highest, tilesSeen: tiles)
        LensPictureScale.store(reading, for: model(), in: defaults)
        refresh()
        stop()
    }

    /// The spoken answer, while the check is on the lens. True when it was taken.
    func handleVoice(_ text: String) -> Bool {
        guard isRunning, ownsLens, let answer = LensFitCheckAnswer.parse(text) else { return false }
        record(highest: answer.highest, tiles: answer.tiles ?? LensFitCheck.tileCount)
        return true
    }

    /// The support report's line: the reading for the glasses on now and the factor it sets.
    var reportLines: [String] { Self.reportLines(model: model(), reading: LensPictureScale.reading(for: model(), in: defaults)) }

    nonisolated static func reportLines(model: String?, reading: LensPictureScale.Reading?) -> [String] {
        let name = LensPictureScale.modelKey(model)
        guard let reading else {
            return ["Lens fit check (\(name)): not run; pictures sent at factor 1"]
        }
        return ["Lens fit check (\(name)): read \(reading.highestNumber) of \(LensPictureScale.fullReading),"
                + " tiles seen \(reading.tilesSeen) of \(LensFitCheck.tileCount);"
                + " pictures sent at factor \(LensPictureScale.factorText(reading.factor))"]
    }
}
