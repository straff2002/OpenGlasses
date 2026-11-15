import Foundation

/// Builds the interactive `HUDScreen` for the teleprompter from a paginated window plus
/// the live pacing state. Pure and `static` (like `HUDRouter.taskCard`) so the exact
/// layout — status line, emphasized active line, control buttons — is unit-testable
/// without a display. The control closures are supplied by `TeleprompterService`; both
/// the on-phone preview (button tap) and the Neural Band (`onSelect` → `id`) invoke them.
enum TeleprompterScreen {
    /// The four live controls surfaced as band-selectable buttons. Defaults are no-ops so
    /// tests can build a screen and assert on its shape without wiring a service.
    struct Controls {
        var togglePause: () -> Void = {}
        var slower: () -> Void = {}
        var faster: () -> Void = {}
        var stop: () -> Void = {}
    }

    /// Stable item ids so the band's `onSelect(id:)` routes back to the right control.
    enum ItemID {
        static let pause = "tp.pause"
        static let slower = "tp.slower"
        static let faster = "tp.faster"
        static let stop = "tp.stop"
    }

    /// - Parameters:
    ///   - title: the script title (shown as the card heading).
    ///   - window: the visible lines; `activeLineIndex` is emphasized as the line being spoken.
    ///   - progress: 0…1 through the *whole* script (from the real cursor, not the lead-shifted one).
    ///   - wpm: current pace, shown in the status line.
    ///   - isPaused: flips the first button between "Pause" and "Resume", and annotates the status.
    static func build(title: String,
                      window: TeleprompterWindow,
                      progress: Double,
                      wpm: Int,
                      isPaused: Bool,
                      controls: Controls = .init()) -> HUDScreen {
        let pct = Int((min(max(progress, 0), 1) * 100).rounded())
        var status = String(localized: "\(pct)% · \(wpm) wpm")
        if isPaused { status += String(localized: " · paused") }

        var lines: [HUDLine] = [HUDLine(status, emphasis: .meta)]
        if window.lines.isEmpty {
            lines.append(HUDLine(String(localized: "— end —"), emphasis: .secondary))
        } else {
            for (i, line) in window.lines.enumerated() {
                lines.append(HUDLine(line, emphasis: i == window.activeLineIndex ? .primary : .secondary))
            }
        }

        let items: [HUDItem] = [
            HUDItem(id: ItemID.pause,
                    label: isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                    icon: isPaused ? .success : .none,
                    style: .primary) { controls.togglePause() },
            HUDItem(id: ItemID.slower, label: String(localized: "Slower"), style: .secondary) { controls.slower() },
            HUDItem(id: ItemID.faster, label: String(localized: "Faster"), style: .secondary) { controls.faster() },
            HUDItem(id: ItemID.stop, label: String(localized: "Stop"), style: .outline) { controls.stop() },
        ]

        return HUDScreen(title: title, lines: lines, items: items)
    }
}
