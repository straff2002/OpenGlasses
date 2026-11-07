import Foundation

/// When smart camera may take a frame for a turn, beyond what `VisionIntentDetector` reads in its
/// words (Plan JW P0). Pure.
///
/// # "Show me the table"
///
/// `VisionIntentDetector` hears "show me" as a request to look. In a Field Assist session whose last
/// answer cited manual pages it is nothing of the kind: "show me the table", "open the page",
/// "bring up the second source" mean the cited pages, which `show_source` puts on the phone. The
/// partner's trace: every such turn grabbed a frame before the model was called, and with the
/// glasses added but not connected the grab ran three Meta permission attempts (about eight
/// seconds) and was rejected — then the model called `show_source` anyway. So while there are cited
/// pages to show, a turn that asks to show one is not a camera turn: no capture, no live frame, and
/// not the cooldown's follow-up either, so routing (`expectsCameraImage`) and the grab agree.
///
/// # "Read the row on this page" (Plan JW P1a)
///
/// The same holds for reading one: after an answer put a manual page on the phone, the partner said
/// "read the W3 row in the Rating B column on this page", and the model reached for `look_closely`
/// and `vision_assess` — the camera — for a page that was on the phone, not in front of the lens.
/// A turn that reads, looks up or asks the value of a page, table, row, column or cell, while the
/// last answer cited pages or a manual page is open on the phone, is the manual's turn
/// (`table_lookup`, `manual_lookup`): no frame goes with it, and the two camera tools decline it
/// before any capture (`cameraToolReply`). The thing being read decides: "read this nameplate" and
/// "read the label" name no page and stay camera turns, and words that name something physical in
/// front of the wearer ("the nameplate", "the gauge") keep one even beside "row" or "table".
///
/// # "Look on the vault for an E4 error and tell me what that is"
///
/// `VisionIntentDetector` hears "that is" as pointing at something. With manuals to search — a
/// Field Assist vault, or the personal library — "tell me what that is" after a fault code points
/// back at the code, and "look it up" or "look in the manual" mean the manuals. The owner's trace
/// (2026-11-07): "if you can look what that is on the refrigerator" took a glasses frame,
/// so the turn became a photo turn for the Vision model on another provider, and the next turn took
/// the live frame too. So a turn that names a fault code ("E4 error", "error 21", "code F3") or
/// the manuals, with manuals to search, is the manual's turn: no frame of any kind. The camera
/// words, and something physical in front of the wearer ("the code on the display"), keep it a
/// camera turn; "what's this error" names no code and stays one.
///
/// # A link that is down
///
/// Connected means `linkState == .connected` (`CameraService.isGlassesLinkUp`). A glasses capture
/// with the link down cannot succeed, and trying costs the permission attempts above; smart camera
/// sends no picture instead, at once. It never swaps to the phone camera for an automatic capture:
/// a phone in a pocket would answer the question with a picture of the pocket.
enum SmartCameraPolicy {

    /// What smart camera knows about the turn besides its words.
    struct Context: Equatable {
        /// The session's last answer cited manual pages that `show_source` can open.
        var citedManualPagesOpen = false
        /// A manual page sheet is open on the phone (Plan JW P1a) — "this page" is that page.
        var manualPageOnScreen = false
        /// There are manuals to look things up in: the active Field Assist session's vault, or the
        /// personal library.
        var manualsToSearch = false

        /// Whether a manual page is what "the page" or "the table" can mean in this turn.
        var hasManualPages: Bool { citedManualPagesOpen || manualPageOnScreen }
    }

    /// Whether the turn needs the camera.
    static func intent(for query: String, context: Context) -> VisionIntentDetector.CameraIntent {
        isManualTurn(query, context: context) ? .textOnly : VisionIntentDetector.classify(query)
    }

    /// Whether the turn belongs to the manuals and takes no frame of any kind: it asks to see or
    /// read the cited pages, or to look a fault code up in the manuals there are to search.
    static func isManualTurn(_ query: String, context: Context) -> Bool {
        isAboutCitedPages(query, context: context) || asksToLookUpInManuals(query, context: context)
    }

    /// "Look on the vault for an E4 error and tell me what that is", "look it up in the manual":
    /// with manuals to search, a turn naming a fault code or the manuals, and nothing the camera
    /// or the world in front of the wearer.
    static func asksToLookUpInManuals(_ query: String, context: Context) -> Bool {
        guard context.manualsToSearch else { return false }
        let words = query.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
        guard !words.isEmpty else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if cameraWords.contains(where: { padded.contains(" \($0) ") }) { return false }
        if words.contains(where: physicalThings.contains) { return false }
        if words.contains(where: manualNouns.contains) { return true }
        if lookUpPhrases.contains(where: { padded.contains(" \($0) ") }), !padded.contains(" look up at ") {
            return true
        }
        return namesFaultCode(words)
    }

    /// A fault-code word ("error", "fault", "code", "alarm") with a code beside it: a short token of
    /// letters then digits ("e4", "f21", "er10"), or a number straight after the word ("error 21").
    static func namesFaultCode(_ words: [String]) -> Bool {
        guard words.contains(where: faultWords.contains) else { return false }
        for (index, word) in words.enumerated() {
            if isCodeToken(word) { return true }
            if faultWords.contains(word), index + 1 < words.count,
               words[index + 1].allSatisfy(\.isNumber), words[index + 1].count <= 4 {
                return true
            }
        }
        return false
    }

    private static func isCodeToken(_ word: String) -> Bool {
        let letters = word.prefix(while: \.isLetter)
        let rest = word.dropFirst(letters.count)
        let digits = rest.prefix(while: \.isNumber)
        let tail = rest.dropFirst(digits.count)
        return (1...3).contains(letters.count) && (1...3).contains(digits.count)
            && tail.count <= 1 && tail.allSatisfy(\.isLetter)
    }

    private static let faultWords: Set<String> = [
        "error", "errors", "fault", "faults", "code", "codes", "alarm", "alarms",
    ]

    private static let manualNouns: Set<String> = [
        "manual", "manuals", "vault", "vaults", "documentation", "datasheet", "datasheets",
    ]

    private static let lookUpPhrases = ["look up", "look it up", "look that up", "look this up", "looks up"]

    /// Whether the turn asks to see, or to read, the cited or open manual pages, so no frame of any
    /// kind goes with it.
    static func isAboutCitedPages(_ query: String, context: Context) -> Bool {
        context.hasManualPages && (asksToShowSource(query) || asksToReadManualPage(query))
    }

    /// What `look_closely` and `vision_assess` return instead of taking a picture when the turn is
    /// about a manual page (Plan JW P1a), or nil when they go ahead. The wearer's own words decide
    /// when the turn has them (`TurnUtteranceScope`); a live session gives the tool none, so the
    /// reason the model passed stands in for them there. Without either, the tool goes ahead.
    static func cameraToolReply(utterance: String?, toolReason: String?, context: Context) -> String? {
        guard context.hasManualPages else { return nil }
        let said = utterance?.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = (said?.isEmpty == false ? said : toolReason) ?? ""
        guard !words.isEmpty, isAboutCitedPages(words, context: context) else { return nil }
        return manualPageReply
    }

    /// The camera tools' reply for a manual page. No picture was taken; the model is pointed at the
    /// tools that read the page's own text.
    static let manualPageReply = "No photo was taken: the page the technician means is a manual page the app "
        + "has open on the phone, not something in front of the camera. Read it from the manual: table_lookup "
        + "with the table, the row and the column for a value in a table, or manual_lookup for the text; "
        + "show_source puts the cited page back on screen."

    /// Whether the glasses camera may be started for an automatic capture: only with the link up.
    static func mayStartGlassesCapture(linkUp: Bool) -> Bool { linkUp }

    // MARK: - The words

    /// "Show me the table", "open the page", "bring up the second source", "show me" on its own:
    /// a verb that puts something on screen, and after it a page, table, figure, row, source,
    /// passage or diagram — or a bare "show me (that)". Words that name the camera or the world in
    /// front of the wearer keep it a camera turn ("show me what's in front of me").
    static func asksToShowSource(_ query: String) -> Bool {
        let words = query.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
        guard !words.isEmpty else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if cameraWords.contains(where: { padded.contains(" \($0) ") }) { return false }
        if words.count <= 4, words.first == "show", words.allSatisfy(bareShowWords.contains) { return true }
        if padded.contains(" where does it say ") { return true }
        for verb in showVerbs {
            guard let range = padded.range(of: " \(verb) ") else { continue }
            let rest = padded[range.upperBound...].split(separator: " ").map(String.init)
            if rest.contains(where: sourceNouns.contains) { return true }
        }
        return false
    }

    /// "Read the row in the Rating B column on this page", "what does the table say", "look up the value in
    /// row 7": a word that reads or asks for a value, and a word for a page, table, row, column or
    /// cell. Words that name the camera, or something physical in front of the wearer, keep it a
    /// camera turn ("read the table on this nameplate", "what does the gauge read").
    static func asksToReadManualPage(_ query: String) -> Bool {
        let words = query.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
        guard !words.isEmpty else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if cameraWords.contains(where: { padded.contains(" \($0) ") }) { return false }
        if words.contains(where: physicalThings.contains) { return false }
        guard words.contains(where: pageNouns.contains) else { return false }
        return readWords.contains { padded.contains(" \($0) ") }
    }

    private static let pageNouns: Set<String> = [
        "page", "pages", "table", "tables", "row", "rows", "column", "columns", "cell", "cells",
    ]

    private static let readWords = ["read", "reads", "say", "says", "said", "look up", "lookup", "value", "values",
                                    "what", "what's", "which", "find", "tell me", "give me", "check", "number"]

    /// Things in front of the wearer that are read with the camera even when a row or table is
    /// mentioned beside them.
    private static let physicalThings: Set<String> = [
        "nameplate", "nameplates", "label", "labels", "sticker", "gauge", "gauges", "meter", "screen",
        "dial", "thermostat", "tag", "plate", "sign", "receipt", "display",
    ]

    private static let showVerbs = ["show", "open", "bring up", "bring back", "pull up", "put up", "display",
                                    "highlight", "go to", "go back to", "let me see"]

    private static let sourceNouns: Set<String> = [
        "page", "pages", "table", "tables", "figure", "figures", "row", "rows", "source", "sources",
        "passage", "passages", "diagram", "diagrams", "clause", "clauses", "section", "drawing",
    ]

    /// A short "show me (that) (again)", which with pages cited means the first of them.
    private static let bareShowWords: Set<String> = ["show", "me", "it", "that", "this", "them", "those", "again",
                                                     "please"]

    private static let cameraWords = ["camera", "glasses", "in front of me", "what you see", "what do you see",
                                      "can you see", "do you see", "look at", "take a photo", "take a picture"]
}
