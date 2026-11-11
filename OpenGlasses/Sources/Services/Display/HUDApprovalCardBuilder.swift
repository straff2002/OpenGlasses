import Foundation

/// What a press on an approval card asks for (Plan LC §3). The builder only reports the press;
/// `HUDApprovalCard` decides what each one does.
enum HUDApprovalAction: Equatable {
    case approve
    case deny
    /// Open the card's Details screen: the whole ask, as far as the lens can hold it.
    case details
    /// From Details, back to the card.
    case back
}

/// Builds the approval card's `HUDScreen`s from what the shared consent surface asks (Plan LC §3).
/// Pure: the ask is the `PendingToolConfirmation`'s summary and source, and presses are reported
/// through the injected `onAction`.
///
/// | Screen | Heading | Lines | Buttons |
/// |---|---|---|---|
/// | the card | the action as a question ("Send a message to Sam?") | ⚠ who asks (meta) · one preview line | **Approve** (primary, focused) · Deny · Details (only when the lens cannot hold the whole ask) |
/// | Details | the same | ⚠ who asks (meta) · the ask, up to `maxDetailLines` lines · "The rest is on your phone" when even that is cut | Approve · Deny · ‹ Back (focused) |
///
/// **The heading and the preview.** Summaries are written action-first ("Send a message to Sam:
/// “meet at 8”", "Call Sam", "Remember this face as Sam? They won't be told."): the heading is
/// the part before the first ": " (or the first sentence), made a question, and the preview is the
/// rest. A first part too long for a heading gives the generic "Approve?" and the whole ask as the
/// preview, so nothing is ever cut out of the middle of a heading.
///
/// **Who asks.** Every ask carries its source (BN P1: "the HUD card and the spoken prompt always
/// carry the attribution"), so the first line is "The assistant asks", "The gateway asks", or an
/// ops peer's label, behind the warning icon.
///
/// **Details** is offered only when there is more than the card shows; the phone's consent card
/// always shows the whole ask.
///
/// Approve and Deny both stay on Details, so reading more never takes the wearer further from an
/// answer; Deny ends in `.deny`, so `HUDExit` counts it as the card's way out.
enum HUDApprovalCardBuilder {

    /// Stable item ids, so a band press routes back by id.
    enum ItemID {
        static let approve = "lc.approval.approve"
        static let deny = "lc.approval.deny"
        static let details = "lc.approval.details"
        static let back = "lc.approval.back"
    }

    /// Body lines the Details screen gives the ask.
    static let maxDetailLines = 4

    /// The ask split for the card.
    struct Parts: Equatable {
        /// The action as a question, at most `HUDTextShaper.maxTitleLength` characters.
        let heading: String
        /// The rest of the ask, condensed to one body line. Nil when the heading is the whole ask.
        let preview: String?
        /// The card does not show the whole ask: Details is offered.
        let hasMore: Bool
    }

    /// The generic heading, for an ask whose first part is too long to be one.
    static var genericHeading: String {
        String(localized: "Approve?", comment: "Glasses: heading of an approval card whose action is too long to be the heading.")
    }

    /// Split `summary` into the card's heading and preview line.
    static func parts(of summary: String) -> Parts {
        let ask = HUDTextShaper.condense(summary, max: Int.max)
        guard !ask.isEmpty else { return Parts(heading: genericHeading, preview: nil, hasMore: false) }
        let (first, rest) = split(ask)
        // A heading is a question one line long; one that would not fit is never cut mid-heading.
        guard let head = first, head.count < HUDTextShaper.maxTitleLength else {
            return preview(heading: genericHeading, rest: ask)
        }
        return preview(heading: question(head), rest: rest)
    }

    private static func preview(heading: String, rest: String?) -> Parts {
        guard let rest, !rest.isEmpty else { return Parts(heading: heading, preview: nil, hasMore: false) }
        // `rest` is already condensed, so it is cut exactly when it is longer than a body line.
        return Parts(heading: heading, preview: HUDTextShaper.condense(rest, max: HUDTextShaper.maxBodyLength),
                     hasMore: rest.count > HUDTextShaper.maxBodyLength)
    }

    /// The first part of the ask and the rest: at the first ": ", else after a first sentence that
    /// is already a question ("Remember this face as Sam? They won't be told."). Not at a full
    /// stop: "Send a message to Dr. Smith" is one action. With neither, the whole ask is the head.
    private static func split(_ ask: String) -> (head: String?, rest: String?) {
        if let colon = ask.range(of: ": ") {
            let head = String(ask[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(ask[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, !rest.isEmpty { return (head, rest) }
        }
        if let end = ask.range(of: "? ") {
            let head = String(ask[..<end.lowerBound]) + "?"
            let rest = String(ask[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            if head.count > 1, !rest.isEmpty { return (head, rest) }
        }
        return (ask, nil)
    }

    /// The action as a question: trailing punctuation becomes "?".
    static func question(_ head: String) -> String {
        var text = head.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ".!:;,".contains(last) { text.removeLast() }
        return text.hasSuffix("?") ? text : text + "?"
    }

    /// The meta line naming who asks.
    static func sourceLine(_ source: RemoteActionSource) -> String {
        let who = HUDTextShaper.condense(source.line, max: HUDTextShaper.maxTitleLength)
        return String(localized: "\(who) asks",
                      comment: "Glasses: who is asking for an approval, e.g. 'The assistant asks' or 'The gateway asks'.")
    }

    /// The card: the action as the heading, who asks, one preview line, and Approve · Deny ·
    /// Details (only when there is more).
    static func card(summary: String, source: RemoteActionSource,
                     onAction: @escaping (HUDApprovalAction) -> Void) -> HUDScreen {
        let parts = parts(of: summary)
        var lines = [HUDLine(sourceLine(source), icon: .warning, emphasis: .meta)]
        if let preview = parts.preview { lines.append(HUDLine(preview, emphasis: .primary)) }
        var items = [approveItem(onAction), denyItem(onAction)]
        if parts.hasMore {
            items.append(HUDItem(id: ItemID.details,
                                 label: String(localized: "Details",
                                               comment: "Glasses: approval card button that shows the whole request."),
                                 style: .secondary) { onAction(.details) })
        }
        return HUDScreen(title: parts.heading, lines: lines, items: items, focusItemID: ItemID.approve)
    }

    /// Details: the whole ask over up to `maxDetailLines` body lines, then Approve · Deny · ‹ Back,
    /// with focus on ‹ Back (reading on is not a reason to approve).
    static func details(summary: String, source: RemoteActionSource,
                        onAction: @escaping (HUDApprovalAction) -> Void) -> HUDScreen {
        let parts = parts(of: summary)
        let ask = HUDTextShaper.condense(summary, max: Int.max)
        let chunks = wrap(ask, width: HUDTextShaper.maxBodyLength, maxLines: maxDetailLines)
        var lines = [HUDLine(sourceLine(source), icon: .warning, emphasis: .meta)]
        lines += chunks.lines.map { HUDLine($0, emphasis: .primary) }
        if chunks.cut {
            lines.append(HUDLine(String(localized: "The rest is on your phone",
                                        comment: "Glasses: an approval request too long for the lens; the phone shows all of it."),
                                 emphasis: .meta))
        }
        let back = HUDItem(id: ItemID.back,
                           label: String(localized: "‹ Back", comment: "Glasses: approval Details button back to the card."),
                           style: .outline) { onAction(.back) }
        return HUDScreen(title: parts.heading, lines: lines,
                         items: [approveItem(onAction), denyItem(onAction), back],
                         focusItemID: ItemID.back)
    }

    private static func approveItem(_ onAction: @escaping (HUDApprovalAction) -> Void) -> HUDItem {
        HUDItem(id: ItemID.approve,
                label: String(localized: "Approve", comment: "Glasses: approval card button that allows the action."),
                icon: .success, style: .primary) { onAction(.approve) }
    }

    private static func denyItem(_ onAction: @escaping (HUDApprovalAction) -> Void) -> HUDItem {
        HUDItem(id: ItemID.deny,
                label: String(localized: "Deny", comment: "Glasses: approval card button that refuses the action."),
                style: .outline) { onAction(.deny) }
    }

    /// Head-first word wrap into at most `maxLines` lines of `width` characters; `cut` when the
    /// text did not all fit (Details then says the rest is on the phone).
    static func wrap(_ text: String, width: Int, maxLines: Int) -> (lines: [String], cut: Bool) {
        guard width > 0, maxLines > 0 else { return ([], !text.isEmpty) }
        var lines: [String] = []
        var current = ""
        var words = text.split(separator: " ").map(String.init)[...]
        while let word = words.first {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= width {
                current = candidate
                words = words.dropFirst()
                continue
            }
            if current.isEmpty {
                // One word longer than a line: it is cut to the line.
                current = String(word.prefix(width))
                words = words.dropFirst()
            }
            lines.append(current)
            current = ""
            if lines.count == maxLines { break }
        }
        if !current.isEmpty, lines.count < maxLines {
            lines.append(current)
            current = ""
        }
        return (lines, !words.isEmpty || !current.isEmpty)
    }
}
