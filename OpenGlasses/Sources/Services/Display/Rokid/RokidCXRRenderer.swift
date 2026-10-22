import Foundation

/// Maps this app's HUD model onto the display primitive the CXR-M SDK actually documents.
///
/// The decompiled `client-m` 1.0.8 reference exposes **no** custom-HUD, item or button API.
/// The only text surface is the `Sys/WordTips_*` overlay (`WordTips_SetTvConfig` to configure
/// it, `WordTips_AiContent` to push text), with `Trans/Trans_Result` as a structured-result
/// channel. So a `HUDScreen` is flattened to one caption and its interactive items are
/// serialised into that caption rather than being selectable — a limit of the SDK, not of the
/// app, and the honest counterpart to `GlassesDisplayBackend.onItemSelected`.
///
/// This is the CXR-facing sibling of `RokidScreenRenderer`, which still emits the legacy
/// vocabulary until the transport can carry Caps frames.
enum RokidCXRRenderer {

    /// Keep in step with the EVEN and legacy-Rokid budgets for cross-device legibility.
    static let charBudget = 44
    static let maxLines = 8

    // MARK: - Content

    static func renderContent(title: String?, body: String, icon: HUDIcon) -> [RokidCXRCommand] {
        [.wordTipsContent(asr: caption(title: title, body: body))]
    }

    // MARK: - Interactive screens

    static func renderScreen(_ screen: HUDScreen) -> [RokidCXRCommand] {
        [.wordTipsContent(asr: caption(screen: screen))]
    }

    /// Clearing the overlay means pushing an empty caption: the SDK has no explicit clear.
    static func clearCommands() -> [RokidCXRCommand] {
        [.wordTipsContent(asr: "")]
    }

    // MARK: - Caption composition

    /// Title first (if any), then the body, each wrapped to `charBudget` and capped at
    /// `maxLines`. Empty input yields an empty caption so the caller can clear the overlay.
    static func caption(title: String?, body: String) -> String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append(contentsOf: wrap(title))
        }
        if !body.isEmpty {
            lines.append(contentsOf: wrap(body))
        }
        return Array(lines.prefix(maxLines)).joined(separator: "\n")
    }

    /// A screen flattened to one caption: title, content lines, then numbered items. Items
    /// carry their number so the wearer can still see the ordering, even though the SDK gives
    /// no way to select one from the display.
    static func caption(screen: HUDScreen) -> String {
        var lines: [String] = []
        if let title = screen.title, !title.isEmpty {
            lines.append(contentsOf: wrap(title))
        }
        for line in screen.lines {
            lines.append(contentsOf: wrap(line.text))
        }
        for (index, item) in screen.items.enumerated() {
            lines.append(contentsOf: wrap("\(index + 1). \(item.label)"))
        }
        return Array(lines.prefix(maxLines)).joined(separator: "\n")
    }

    // MARK: - Wrapping

    /// Greedy word wrap to `charBudget`, breaking over-long words rather than dropping them.
    static func wrap(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return text.isEmpty ? [] : [text] }

        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= charBudget {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
            while current.count > charBudget {
                let cut = current.index(current.startIndex, offsetBy: charBudget)
                lines.append(String(current[current.startIndex..<cut]))
                current = String(current[cut...])
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
