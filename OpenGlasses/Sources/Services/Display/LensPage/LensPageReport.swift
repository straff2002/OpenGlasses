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
    }

    let event: Event
    let documentTitle: String
    let page: Int
    let figure: String?
    /// What the lens shows, in top-down page points (zero for a cue).
    let crop: CGRect
    /// The zoom step (1 = the whole page fitted; 0 for a cue).
    let zoom: Int
    /// Why the page reached the lens: `requested`, `automatic` (opened with **Show here**) or
    /// `answer_card` (its **Page** action).
    let route: String
    /// The display backend's token.
    let backend: String

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
                         + " next pages \(entry.nextPages), refused \(entry.refused),"
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
