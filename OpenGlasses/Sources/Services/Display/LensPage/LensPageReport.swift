import CoreGraphics
import Foundation

/// One line for the page audit trail (Plan KV §5): the lens showed a page, or changed what part of
/// it shows. The page reference and the crop only — never the page's text or pixels.
struct LensPageAuditLine: Equatable {
    enum Event: String, Equatable {
        /// The **Show here** cue went up for a page the app put up by itself.
        case cueShown = "cue_shown"
        /// The page view opened.
        case opened
        case zoomed
        case moved
        /// The view went to another cited page.
        case nextPage = "next_page"
        case closed
        /// Reading mode (§1): the view switched to the passage's words (**Read it**)…
        case reading
        /// …turned a page of them…
        case readPage = "read_page"
        /// …or switched to the picture (**Page**).
        case picture
        /// Plan MU §6: the close-up of the highlighted part, or fit width (a pinch on the page).
        case closeUp = "close_up"
        /// Plan MU §6: back to the whole page.
        case whole
        /// Plan MU §6: the page's table as rows.
        case rows
    }

    /// What the lens showed: the page's picture, or a cited passage's words as text (reading mode).
    enum View: String, Equatable {
        case picture
        case reading
        /// Plan MU §6: the page's table as text rows.
        case rows
    }

    let event: Event
    let documentTitle: String
    let page: Int
    let figure: String?
    /// What the lens shows, in top-down page points (zero for a cue and for reading mode).
    let crop: CGRect
    /// The scale (1 = the whole page fitted; 0 for a cue and for reading mode).
    let zoom: Double
    /// Why the page reached the lens: `requested`, `automatic` (opened with **Show here**) or
    /// `answer_card` (its **Page** action).
    let route: String
    /// The display backend's token.
    let backend: String
    /// The picture or the words; nil for a cue.
    var view: View? = nil
    /// Plan MU §6: what the page highlighted and why (`LensPageHighlight.Reason`: cited_mark,
    /// table_row, table, figure, none); nil for a cue.
    var highlight: String? = nil

    init(event: Event, documentTitle: String, page: Int, figure: String?, crop: CGRect, zoom: Double,
         route: String, backend: String, view: View? = nil, highlight: String? = nil) {
        self.event = event
        self.documentTitle = documentTitle
        self.page = page
        self.figure = figure
        self.crop = crop
        self.zoom = zoom
        self.route = route
        self.backend = backend
        self.view = view
        self.highlight = highlight
    }

    /// "x,y,w,h", whole page points.
    var cropText: String {
        let rect = crop.integral
        return "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }
}

/// What the page view did since the app started, by display backend, for the support report's
/// **Page on the lens** section (§5). Counts and timings only, in memory only.
struct LensPageStats: Equatable {
    struct Backend: Equatable {
        var cuesShown = 0
        var showHerePressed = 0
        var viewsOpened = 0
        /// Views shown as a passage's words (reading mode): opened that way, or **Read it**.
        var readingViews = 0
        /// Reading-mode pages turned.
        var readingPages = 0
        var zooms = 0
        var moves = 0
        var nextPages = 0
        var stalePressesDropped = 0
        var refused = 0
        var renderMs: [Int] = []
        var sentBytes: [Int] = []
        var sendMs: [Int] = []
        /// Plan MU §6: every press on the view (the band's, the phone preview's, a page word).
        var presses = 0
        /// Presses from a view's opening to its close, one entry a view.
        var pressesPerView: [Int] = []
        var closeUps = 0
        var fitWidths = 0
        var rowsViews = 0
        var rowsSpoken = 0
        /// Back to the whole page.
        var backs = 0
        /// What each view opened highlighting (`LensPageHighlight.Reason`), counted.
        var highlights: [String: Int] = [:]
        /// Plan MU §0: each picture handed to the lens, at the size it was sent ("576×426").
        var pictureSizes: [String] = []
        /// The picture factor the last pictures went at.
        var pictureFactor: Double = 1
        /// Plan MU §7 (flagged builds only): band swipes acted on, each a send, and which kind.
        var bandSwipes = 0
        var bandHalves = 0
        var bandPages = 0
        /// Left or right with nothing to do in the view, or at an edge.
        var bandNothingToDo = 0
        /// Left or right dropped as part of a burst (a send still in flight, or too soon).
        var bandDropped = 0
        /// Other inputs heard while the view was up (up, down, a pinch's select, drag), never acted on.
        var bandOther = 0
        /// The band's channel became active for a view, or failed.
        var bandListening = 0
        var bandFailures = 0

        var bandUsed: Bool {
            bandSwipes + bandNothingToDo + bandDropped + bandOther + bandListening + bandFailures > 0
        }
    }

    /// Timings kept per backend, newest last.
    static let keep = 50

    private(set) var byBackend: [String: Backend] = [:]

    var isEmpty: Bool { byBackend.isEmpty }

    subscript(backend: String) -> Backend { byBackend[backend] ?? Backend() }

    mutating func update(_ backend: String, _ change: (inout Backend) -> Void) {
        var entry = byBackend[backend] ?? Backend()
        change(&entry)
        entry.renderMs = Array(entry.renderMs.suffix(Self.keep))
        entry.sentBytes = Array(entry.sentBytes.suffix(Self.keep))
        entry.sendMs = Array(entry.sendMs.suffix(Self.keep))
        entry.pressesPerView = Array(entry.pressesPerView.suffix(Self.keep))
        entry.pictureSizes = Array(entry.pictureSizes.suffix(Self.keep))
        byBackend[backend] = entry
    }
}

/// The support report's **Page on the lens** section (Plan KV §5).
enum LensPageReport {
    static func lines(for stats: LensPageStats) -> [String] {
        guard !stats.isEmpty else { return ["Page on the lens: not used since the app started"] }
        var lines = ["Page on the lens (since the app started):"]
        for backend in stats.byBackend.keys.sorted() {
            let entry = stats[backend]
            lines.append("  \(backend): views opened \(entry.viewsOpened), Show here cues \(entry.cuesShown)"
                         + " (pressed \(entry.showHerePressed)), zooms \(entry.zooms), moves \(entry.moves),"
                         + " next pages \(entry.nextPages), reading views \(entry.readingViews)"
                         + " (pages turned \(entry.readingPages)), refused \(entry.refused),"
                         + " stale presses dropped \(entry.stalePressesDropped)")
            lines.append("    Render: " + summary(entry.renderMs, unit: "ms"))
            lines.append("    Sent: " + summary(entry.sentBytes.map { ($0 + 512) / 1024 }, unit: "KB")
                         + "; send time " + summary(entry.sendMs, unit: "ms"))
            // Plan MU: what each view highlighted and why, how many presses getting around took,
            // and the pictures' sizes as sent.
            let highlights = entry.highlights.keys.sorted().map { "\($0) \(entry.highlights[$0] ?? 0)" }
            lines.append("    Highlighted: " + (highlights.isEmpty ? "none" : highlights.joined(separator: ", ")))
            lines.append("    Presses: \(entry.presses) (close-ups \(entry.closeUps), fit width \(entry.fitWidths),"
                         + " back \(entry.backs), rows \(entry.rowsViews), rows spoken \(entry.rowsSpoken));"
                         + " per view " + summary(entry.pressesPerView, unit: "presses"))
            lines.append("    Pictures sent: " + LensPictureScale.sizesSummary(entry.pictureSizes)
                         + "; factor " + LensPictureScale.factorText(CGFloat(entry.pictureFactor)))
            if entry.bandUsed {
                // Plan MU §7: only a flagged (TestFlight-only) build hears the band.
                lines.append("    Band: swipes acted on \(entry.bandSwipes) (halves \(entry.bandHalves),"
                             + " pages \(entry.bandPages)), nothing to do \(entry.bandNothingToDo),"
                             + " dropped in a burst \(entry.bandDropped), other inputs \(entry.bandOther);"
                             + " listening \(entry.bandListening), failed \(entry.bandFailures)")
            }
        }
        return lines
    }

    static func summary(_ values: [Int], unit: String) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return "\(sorted.count), median \(median) \(unit), largest \(sorted[sorted.count - 1]) \(unit)"
    }
}
