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
    }

    /// What the lens showed: the page's picture, or a cited passage's words as text (reading mode).
    enum View: String, Equatable {
        case picture
        case reading
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

    init(event: Event, documentTitle: String, page: Int, figure: String?, crop: CGRect, zoom: Double,
         route: String, backend: String, view: View? = nil) {
        self.event = event
        self.documentTitle = documentTitle
        self.page = page
        self.figure = figure
        self.crop = crop
        self.zoom = zoom
        self.route = route
        self.backend = backend
        self.view = view
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
