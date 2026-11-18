#if DAT_MOCK_DISPLAY
import Foundation
import MWDATDisplay
import MWDATMockDevice
import UIKit
import WebKit

/// The tall-views measurement on the simulated Display, development only, on the iOS Simulator.
///
/// It sends views the HUD's SDK-free DSL can't express (columns and grids of `FlexBox`es made
/// tappable with `.onTap`) through the HUD's own lens session
/// (`GlassesDisplayService.simulatedDisplayMetaBackend`, `MetaDisplayBackend.sendMeasurementView`),
/// then moves focus and reads what the preview draws: its scroll offsets, which element has
/// focus, what changed after each move, and the drawn size of every image. Focus is moved with
/// the preview's own input, the arrow keys and Enter its focus engine listens for: the mock's
/// input kit moves and presses nothing on the preview, which the first item records. A press after a move tells which tappable the SDK
/// itself has focused, because only that one's handler fires. Send times are taken around the
/// `send` await, and again until the test server serves the new frame and the preview draws it.
///
/// Five items: a column of 30 tappable rows (plain, on cards, and rows taller than the lens);
/// where focus and scroll land on a send; send time against size; a 3 × 3 grid of tappable image
/// tiles; a stack of image slices up to three lens heights. The results go to Documents/tall-views/ (results.json, tall-views.log, PNG snapshots
/// of the preview) and one line per step to the debug event log. Only invented text and drawn
/// test images are sent; nothing is pressed that sends, saves or asks the model anything.
@MainActor
struct SimulatedDisplayTallViews {
    let appState: AppState
    let lab: SimulatedDisplayLab

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tall-views", isDirectory: true)
    }

    /// The lens is 600 × 600; the column inside the 12 px margins is 576 wide.
    static let lensSide = 600
    static let columnWidth = 576
    /// The longest a measurement send may take before it is recorded as timed out.
    static let sendDeadline: TimeInterval = 20

    private var display: GlassesDisplayService { appState.glassesDisplay }
    private var backend: MetaDisplayBackend { display.simulatedDisplayMetaBackend }

    final class State {
        var lines: [String] = []
        var step = 0
        var results: [String: Any] = [:]
        var frameDumps = 0
    }
    private let state = State()
    private let taps = TapRecorder()

    // MARK: - Run

    func run() async {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.folder)
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        lab.previewVisible = true

        let connected = await wait(seconds: 20) {
            appState.glassesPhase == .connected && display.deviceSupportsDisplay()
        }
        write("connected=\(connected) phase=\(appState.glassesPhase) availability=\(display.displayAvailability.rawValue) "
              + "input=\(lab.inputKit != nil) server=\(lab.serverAddress ?? "none")")
        // Let anything the app draws on connecting settle before the first measurement frame.
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // A first, small send: it starts the lens session and the display (timed apart from the rest).
        let warm = await send(Self.column(title: "Warm-up", rows: rows(3, tag: "W"), recorder: taps), marker: "Warm-up")
        state.results["warmUp"] = warm.json
        write("warm-up: \(warm.summary)")
        await capture("warm-up")

        await columnOfRows()
        await cardRows()
        await rowsTallerThanTheLens()
        await focusOnSend()
        await sendTimes()
        await tileGrid()
        await sliceStacks()

        state.results["notMeasured"] = [
            "dimAndSleep": "The 1.0.1 Mock Device Kit has no dim or sleep control, so what a send does to a dimmed or sleeping lens is the device pass's.",
        ]
        saveResults()
        write("done")
        display.showNotification(title: "Simulated Display", body: "Tall views done", icon: .info, duration: 4)
    }

    // MARK: - 1. A column of 30 tappable rows

    private func columnOfRows() async {
        let view = Self.column(title: "Thirty rows", rows: rows(30, tag: "R"), recorder: taps)
        let sent = await send(view, marker: "Thirty rows")
        write("1 column: \(sent.summary)")
        await dumpFrame("column30")
        await dumpDOM("column30-open")
        let open = await probe(resetDiff: true)
        await capture("1-column-open", note: open.summary)

        // The mock's input kit first: band and touchpad moves and a band press.
        let pressedAtOpen = await kitPress()
        var kitMoves: [[String: Any]] = []
        for (name, source) in [("band", 0), ("touchpad", 1)] {
            for move in 1...3 {
                if source == 0 { lab.inputKit?.navDown(source: .neuralBand) } else { lab.inputKit?.navDown(source: .captouch) }
                try? await Task.sleep(nanoseconds: 450_000_000)
                let after = await probe()
                var entry = after.json
                entry["move"] = "kit \(name) down \(move)"
                entry["pressed"] = await kitPress()
                kitMoves.append(entry)
                write("1 kit \(name) down \(move): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
            }
        }
        await capture("1-column-after-kit-moves")

        // The preview's own input: the arrow keys and Enter its focus engine listens for, sent to
        // the focused element.
        let fresh = Self.column(title: "Thirty rows, keys", rows: rows(30, tag: "K"), recorder: taps)
        _ = await send(fresh, marker: "Thirty rows, keys")
        let keysOpen = await probe(resetDiff: true)
        await capture("1-column-keys-open", note: keysOpen.summary)
        var moves: [[String: Any]] = []
        let checkpoints: Set<Int> = [1, 2, 5, 9, 10, 11, 15, 20, 29, 32]
        for move in 1...32 {
            await key("ArrowDown")
            let after = await probe()
            var entry = after.json
            entry["move"] = "down \(move)"
            if checkpoints.contains(move) {
                entry["pressed"] = await press()
                await capture(String(format: "1-column-key-down-%02d", move), note: after.summary)
            }
            if move == 2 { await dumpDOM("column30-after-2-key-downs") }
            moves.append(entry)
            write("1 key down \(move): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
        }
        for move in 1...12 {
            await key("ArrowUp")
            let after = await probe()
            var entry = after.json
            entry["move"] = "up \(move)"
            if move % 4 == 0 { entry["pressed"] = await press() }
            moves.append(entry)
            write("1 key up \(move): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
        }
        await capture("1-column-after-key-ups")

        // Whether the frame's tappable boxes carry identifiers `sendClick` can press.
        let identifiers = await frameIdentifiers()
        var clicked: String = "no identifiers"
        if let first = identifiers.first(where: { $0.type != "button" }) {
            _ = taps.drain()
            let accepted = lab.sendClick(identifier: first.identifier)
            try? await Task.sleep(nanoseconds: 500_000_000)
            clicked = "sendClick(\(first.type) \(first.identifier)) accepted=\(accepted) fired=\(taps.drain())"
        }
        write("1 identifiers: \(identifiers.prefix(4).map { "\($0.type):\($0.identifier)" }) \(clicked)")

        state.results["1_columnOfRows"] = [
            "send": sent.json,
            "open": open.json,
            "kitPressedAtOpen": pressedAtOpen,
            "kitMoves": kitMoves,
            "keysOpen": keysOpen.json,
            "keyMoves": moves,
            "identifierTypes": Array(Set(identifiers.map(\.type))).sorted(),
            "identifierCount": identifiers.count,
            "sendClickOnTappable": clicked,
        ]
        saveResults()
    }

    // MARK: - 1b. Rows on a card background

    /// The rows again with `.background(.card)`: the preview draws a plain tappable box with no
    /// focus mark, and a card with one.
    private func cardRows() async {
        let view = Self.column(title: "Thirty card rows", rows: rows(30, tag: "C"), card: true, recorder: taps)
        let sent = await send(view, marker: "Thirty card rows")
        await dumpFrame("column30-cards")
        let open = await probe(resetDiff: true)
        await capture("1b-cards-open", note: open.summary)
        await dumpDOM("column30-cards-open")
        var moves: [[String: Any]] = []
        for move in 1...12 {
            await key("ArrowDown")
            let after = await probe()
            var entry = after.json
            entry["move"] = "down \(move)"
            if [1, 8, 9, 12].contains(move) {
                entry["pressed"] = await press()
                await capture(String(format: "1b-cards-down-%02d", move), note: after.summary)
            }
            moves.append(entry)
            write("1b down \(move): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
        }
        state.results["1b_cardRows"] = ["send": sent.json, "open": open.json, "moves": moves]
        saveResults()
    }

    // MARK: - 1c. Rows taller than the lens

    /// Four rows of about 900 characters each, each taller than the lens: whether a move shows the
    /// part of a focused row below the lens's edge, or jumps to the next row.
    private func rowsTallerThanTheLens() async {
        var out: [String: Any] = [:]
        for card in [false, true] {
            let title = card ? "Tall card rows" : "Tall rows"
            let view = Self.column(title: title, rows: Self.longRows(count: 4, total: 3600, tag: card ? "M" : "L"),
                                   card: card, recorder: taps)
            let sent = await send(view, marker: title)
            let open = await probe(resetDiff: true)
            await capture("1c-\(card ? "cards" : "plain")-open", note: open.summary)
            var moves: [[String: Any]] = []
            for move in 1...6 {
                await key("ArrowDown")
                let after = await probe()
                var entry = after.json
                entry["move"] = "down \(move)"
                entry["pressed"] = await press()
                if move <= 2 { await capture("1c-\(card ? "cards" : "plain")-down-\(move)", note: after.summary) }
                moves.append(entry)
                write("1c \(title) down \(move): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
            }
            out[card ? "cards" : "plain"] = ["send": sent.json, "open": open.json, "moves": moves]
        }
        state.results["1c_rowsTallerThanTheLens"] = out
        saveResults()
    }

    // MARK: - 2. Where focus and scroll land on a send

    private func focusOnSend() async {
        var cases: [[String: Any]] = []
        let variants: [(name: String, primaryAt: Int?)] = [
            ("no primary button", nil), ("primary at the top", 0), ("primary in the middle", 15),
            ("primary at the bottom", 30),
        ]
        for variant in variants {
            let title = "Focus: \(variant.name)"
            let view = Self.column(title: title, rows: rows(30, tag: "F"), primaryAt: variant.primaryAt, recorder: taps)
            let sent = await send(view, marker: title)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let open = await probe(resetDiff: true)
            let slug = variant.name.replacingOccurrences(of: " ", with: "-")
            await capture("2-\(slug)", note: open.summary)
            let pressed = await press()
            // One move down from where it opened, to see where focus goes from there.
            await key("ArrowDown")
            let moved = await probe()
            let pressedAfterMove = await press()
            write("2 \(variant.name): open \(open.summary) pressed=\(pressed) | after down: \(moved.summary) pressed=\(pressedAfterMove)")
            cases.append(["variant": variant.name, "send": sent.json, "open": open.json, "pressedAtOpen": pressed,
                          "afterOneDown": moved.json, "pressedAfterOneDown": pressedAfterMove])
        }
        state.results["2_focusOnSend"] = cases
        saveResults()
    }

    // MARK: - 3. Send time against size

    private func sendTimes() async {
        var series: [[String: Any]] = []
        // Rows: 10, 30 and 60 one-line rows. Characters: 1, 3 and 6 thousand in 10 rows.
        let specs: [(name: String, rows: Int, characters: Int?)] = [
            ("10 rows", 10, nil), ("30 rows", 30, nil), ("60 rows", 60, nil),
            ("1k characters", 10, 1000), ("3k characters", 10, 3000), ("6k characters", 10, 6000),
        ]
        for spec in specs {
            var sendOnly: [Double] = []
            var timed: [[String: Any]] = []
            for rep in 1...4 {
                let title = "Size \(spec.name) rep \(rep)"
                let rowTexts = spec.characters.map { Self.longRows(count: spec.rows, total: $0, tag: "S\(rep)") }
                    ?? rows(spec.rows, tag: "S\(rep)")
                let view = Self.column(title: title, rows: rowTexts, recorder: taps)
                // Reps 1–3 time the send alone; rep 4 also polls the server and the preview.
                let result = await send(view, marker: title, follow: rep == 4)
                if let ms = result.sendMs, result.error == nil, rep < 4 { sendOnly.append(ms) }
                if rep == 4 {
                    timed.append(result.json)
                    let layout = await probe(resetDiff: true)
                    timed.append(["layout": layout.json])
                    await capture("3-\(spec.name.replacingOccurrences(of: " ", with: "-"))", note: layout.summary)
                }
                write("3 \(title): \(result.summary)")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            let characters = spec.characters ?? rows(spec.rows, tag: "S1").reduce(0) { $0 + $1.count }
            series.append(["size": spec.name, "rows": spec.rows, "characters": characters,
                           "sendMs": sendOnly, "medianSendMs": Self.median(sendOnly) as Any, "followed": timed])
        }
        state.results["3_sendTimes"] = series
        saveResults()
    }

    // MARK: - 4. A 3 × 3 grid of tappable image tiles

    private func tileGrid() async {
        var result: [String: Any] = [:]
        // Tiles sized to fit three across the column with 8 px gaps: (576 − 16) / 3 = 186.
        let fitting = Self.grid(title: "Grid 3x3", tile: CGSize(width: 186, height: 150), recorder: taps)
        let sent = await send(fitting, marker: "Grid 3x3")
        await dumpFrame("grid")
        let open = await probe(resetDiff: true)
        await capture("4-grid-open", note: open.summary)
        await dumpDOM("grid-open")
        let pressedAtOpen = await press()
        var moves: [[String: Any]] = []
        let path = ["right", "right", "down", "down", "left", "left", "up", "right", "down"]
        for (index, step) in path.enumerated() {
            await key("Arrow" + step.prefix(1).uppercased() + step.dropFirst())
            let after = await probe()
            var entry = after.json
            entry["move"] = step
            entry["pressed"] = await press()
            if index < 4 { await capture("4-grid-\(index + 1)-\(step)", note: after.summary) }
            if index == 0 { await dumpDOM("grid-after-right") }
            moves.append(entry)
            write("4 \(step): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
        }
        result["fitting"] = ["send": sent.json, "open": open.json, "pressedAtOpen": pressedAtOpen, "moves": moves]

        // How `.fill` sizes an image in a row: tiles wider than a third of the column, and one
        // small image alone in a row.
        let oversize = Self.grid(title: "Grid oversize", tile: CGSize(width: 400, height: 300), recorder: taps)
        let oversizeSent = await send(oversize, marker: "Grid oversize")
        let oversizeLayout = await probe(resetDiff: true)
        await capture("4-grid-oversize", note: oversizeLayout.summary)
        result["oversize400x300"] = ["send": oversizeSent.json, "layout": oversizeLayout.json]

        let small = Self.singleImageRows(title: "Fill small", sizes: [CGSize(width: 100, height: 60),
                                                                     CGSize(width: 300, height: 100),
                                                                     CGSize(width: 900, height: 200)],
                                         recorder: taps)
        let smallSent = await send(small, marker: "Fill small")
        let smallLayout = await probe(resetDiff: true)
        await capture("4-fill-single", note: smallLayout.summary)
        result["fillAloneInARow_100x60_300x100_900x200"] = ["send": smallSent.json, "layout": smallLayout.json]

        // The same grid with each tile on a card background (the preview draws a card's focus).
        let cards = Self.grid(title: "Grid 3x3 cards", tile: CGSize(width: 180, height: 140), card: true, recorder: taps)
        let cardsSent = await send(cards, marker: "Grid 3x3 cards")
        let cardsOpen = await probe(resetDiff: true)
        await capture("4-grid-cards-open", note: cardsOpen.summary)
        await dumpDOM("grid-cards-open")
        var cardMoves: [[String: Any]] = []
        for (index, step) in ["right", "down", "left"].enumerated() {
            await key("Arrow" + step.prefix(1).uppercased() + step.dropFirst())
            let after = await probe()
            var entry = after.json
            entry["move"] = step
            entry["pressed"] = await press()
            await capture("4-grid-cards-\(index + 1)-\(step)", note: after.summary)
            cardMoves.append(entry)
            write("4 cards \(step): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
        }
        result["cards"] = ["send": cardsSent.json, "open": cardsOpen.json, "moves": cardMoves]
        state.results["4_tileGrid"] = result
        saveResults()
    }

    // MARK: - 5. A stack of image slices

    private func sliceStacks() async {
        var stacks: [[String: Any]] = []
        // Slices the column's width by 200: three to a lens height.
        for lensHeights in [1, 2, 3] {
            let count = lensHeights * 3
            let title = "Stack \(lensHeights) lens"
            let view = Self.stack(title: title, slices: count, slice: CGSize(width: Self.columnWidth, height: 200),
                                  recorder: taps)
            var times: [Double] = []
            var followed: [String: Any] = [:]
            for rep in 1...3 {
                let repTitle = title + " rep \(rep)"
                let repView = rep == 1 ? view : Self.stack(title: repTitle, slices: count,
                                                           slice: CGSize(width: Self.columnWidth, height: 200),
                                                           recorder: taps, seed: rep)
                let result = await send(repView, marker: rep == 1 ? title : repTitle, follow: rep == 3)
                if let ms = result.sendMs, result.error == nil { times.append(ms) }
                if rep == 3 { followed = result.json }
                write("5 \(repTitle): \(result.summary)")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            let open = await probe(resetDiff: true)
            await capture("5-stack-\(lensHeights)-open", note: open.summary)
            var moves: [[String: Any]] = []
            for move in 1...(count + 1) {
                await key("ArrowDown")
                let after = await probe()
                var entry = after.json
                entry["move"] = "down \(move)"
                entry["pressed"] = await press()
                moves.append(entry)
                if move == count { await capture("5-stack-\(lensHeights)-bottom", note: after.summary) }
                write("5 stack \(lensHeights) down \(move): \(after.summary) pressed=\(entry["pressed"] ?? "-")")
            }
            stacks.append(["lensHeights": lensHeights, "slices": count, "sendMs": times,
                           "medianSendMs": Self.median(times) as Any, "followed": followed,
                           "open": open.json, "moves": moves])
        }
        state.results["5_sliceStacks"] = stacks
        saveResults()
    }

    // MARK: - Sending

    struct SendResult {
        var sendMs: Double?
        var serverMs: Double?
        var drawnMs: Double?
        var payloadBytes: Int?
        var error: String?

        var json: [String: Any] {
            var out: [String: Any] = [:]
            if let sendMs { out["sendMs"] = Self.round(sendMs) }
            if let serverMs { out["serverMs"] = Self.round(serverMs) }
            if let drawnMs { out["drawnMs"] = Self.round(drawnMs) }
            if let payloadBytes { out["payloadBytes"] = payloadBytes }
            if let error { out["error"] = error }
            return out
        }

        var summary: String {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "-" }
            return "send=\(ms(sendMs)) server=\(ms(serverMs)) drawn=\(ms(drawnMs)) payload=\(payloadBytes.map(String.init) ?? "-")"
                + (error.map { " error=\($0)" } ?? "")
        }

        static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    }

    /// Sends `view` through the HUD's lens session. With `follow`, also times until the test
    /// server serves a new frame and until the preview shows `marker`.
    private func send(_ view: FlexBox, marker: String, follow: Bool = true) async -> SendResult {
        _ = taps.drain()
        let before = await lab.lensFrame()?.payload
        let clock = ContinuousClock()
        let start = clock.now
        var result = SendResult()

        let server: Task<(Double?, Int?), Never>? = follow ? Task { @MainActor in
            let deadline = Date().addingTimeInterval(Self.sendDeadline)
            while Date() < deadline {
                if let frame = await lab.lensFrame(), frame.payload != before {
                    return (Self.milliseconds(clock.now - start), frame.payloadBytes)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return (nil, nil)
        } : nil
        let drawn: Task<Double?, Never>? = follow ? Task { @MainActor in
            let deadline = Date().addingTimeInterval(Self.sendDeadline)
            while Date() < deadline {
                if await previewShows(marker) { return Self.milliseconds(clock.now - start) }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        } : nil

        do {
            try await backend.sendMeasurementView(view, deadline: Self.sendDeadline)
            result.sendMs = Self.milliseconds(clock.now - start)
        } catch {
            result.sendMs = Self.milliseconds(clock.now - start)
            result.error = String(describing: error)
        }
        if let server {
            let (ms, bytes) = await server.value
            result.serverMs = ms
            result.payloadBytes = bytes
        } else {
            result.payloadBytes = await lab.lensFrame()?.payloadBytes
        }
        if let drawn { result.drawnMs = await drawn.value }
        // Let the preview finish drawing before anything reads it.
        _ = await wait(seconds: 5, until: { false }, check: { await previewShows(marker) })
        try? await Task.sleep(nanoseconds: 300_000_000)
        return result
    }

    /// The mock input kit's band press: which tappable's handler fired.
    private func kitPress() async -> String {
        _ = taps.drain()
        lab.inputKit?.select(source: .neuralBand)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let fired = taps.drain()
        return fired.isEmpty ? "nothing" : fired.joined(separator: ",")
    }

    /// Enter on the preview's focused element, as its focus engine takes a press: which
    /// tappable's handler fired (the preview reports the press to the mock, which calls it).
    private func press() async -> String {
        _ = taps.drain()
        await key("Enter", settle: 0)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let fired = taps.drain()
            if !fired.isEmpty { return fired.joined(separator: ",") }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return "nothing"
    }

    /// A key down and up on the preview's focused element (the document body when nothing is).
    private func key(_ name: String, settle: UInt64 = 600_000_000) async {
        guard let web = lab.previewPanel.webView as? WKWebView else { return }
        let codes = ["ArrowUp": 38, "ArrowDown": 40, "ArrowLeft": 37, "ArrowRight": 39, "Enter": 13]
        let script = """
        (() => {
          const t = document.activeElement || document.body;
          for (const type of ['keydown', 'keyup']) {
            t.dispatchEvent(new KeyboardEvent(type, { key: '\(name)', code: '\(name)', keyCode: \(codes[name] ?? 0), which: \(codes[name] ?? 0), bubbles: true, cancelable: true }));
          }
          return 'ok';
        })()
        """
        _ = try? await web.evaluateJavaScript(script)
        if settle > 0 { try? await Task.sleep(nanoseconds: settle) }
    }

    // MARK: - Reading the preview

    struct Probe {
        var json: [String: Any]
        var summary: String
    }

    /// What the preview draws now: scroll offsets, the focused element, what changed since the
    /// last probe, which rows are inside the lens, and every image's drawn and natural size.
    private func probe(resetDiff: Bool = false) async -> Probe {
        guard let web = lab.previewPanel.webView as? WKWebView else {
            return Probe(json: ["error": "no web view"], summary: "no web view")
        }
        let script = Self.probeScript(reset: resetDiff)
        guard let text = try? await web.evaluateJavaScript(script) as? String,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Probe(json: ["error": "unread"], summary: "unread")
        }
        let scrolls = (json["scrolls"] as? [[String: Any]]) ?? []
        let scrollText = scrolls.map { "\($0["top"] ?? "?")/\($0["h"] ?? "?")" }.joined(separator: ",")
        let visible = (json["visibleRows"] as? [String]) ?? []
        var active = (json["active"] as? [String: Any])?["text"] as? String ?? "-"
        if let image = json["activeImg"] as? Int, image >= 0 { active = "image \(image + 1)" }
        let focused = ((json["focusLike"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
            .map { String($0.prefix(14)) }
        let changed = ((json["changed"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
            .map { String($0.prefix(14)) }
        let summary = "scroll=[\(scrollText)] window=\(json["windowScroll"] ?? "-") visible=\(visible.first ?? "-")…\(visible.last ?? "-") "
            + "active=\"\(active.prefix(14))\" at=\((json["active"] as? [String: Any])?["rect"] ?? "-") focusLike=\(focused.prefix(3)) changed=\(changed.prefix(4))"
        return Probe(json: json, summary: summary)
    }

    private func previewShows(_ marker: String) async -> Bool {
        guard let web = lab.previewPanel.webView as? WKWebView else { return false }
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [marker]), encoding: .utf8)) ?? "[\"\"]"
        let script = "(() => { const m = \(quoted)[0]; return (document.body && document.body.innerText.indexOf(m) >= 0) ? 'yes' : 'no'; })()"
        return (try? await web.evaluateJavaScript(script) as? String) == "yes"
    }

    static func probeScript(reset: Bool) -> String {
        """
        (() => {
          const r = e => { const b = e.getBoundingClientRect(); return [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)]; };
          const app = document.getElementById('app') || document.body;
          const cs = e => getComputedStyle(e);
          const describe = e => {
            if (!e || !e.getAttribute) return null;
            const s = cs(e);
            const data = {}; for (const a of e.attributes) { if (a.name.startsWith('data-') || a.name.startsWith('aria-') || a.name === 'role' || a.name === 'tabindex') data[a.name] = a.value.slice(0, 40); }
            return { tag: e.tagName, cls: (typeof e.className === 'string' ? e.className : '').slice(0, 80), attrs: data,
                     text: (e.innerText || '').trim().slice(0, 40), rect: r(e), boxShadow: s.boxShadow.slice(0, 80),
                     outline: s.outlineStyle + ' ' + s.outlineWidth + ' ' + s.outlineColor, border: s.borderTopWidth + ' ' + s.borderTopColor,
                     background: s.backgroundColor, transform: s.transform };
          };
          const scrolls = [...document.querySelectorAll('*')].filter(e => e.scrollHeight > e.clientHeight + 1 && ['auto', 'scroll', 'hidden'].includes(cs(e).overflowY))
            .map(e => ({ tag: e.tagName, sv: e.getAttribute('data-scroll-view'), top: Math.round(e.scrollTop), h: e.scrollHeight, ch: e.clientHeight }));
          const rows = []; const walker = document.createTreeWalker(app, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode; const t = node.textContent.trim();
            const m = t.match(/^([A-Z][0-9]?)(\\d{2}) /); if (!m) continue;
            const range = document.createRange(); range.selectNodeContents(node); const b = range.getBoundingClientRect();
            rows.push([m[1] + m[2], Math.round(b.top), Math.round(b.height)]);
          }
          const visibleRows = rows.filter(x => x[1] >= 0 && x[1] + x[2] <= innerHeight).map(x => x[0]);
          const imgEls = [...app.querySelectorAll('img')];
          const imgs = imgEls.map(e => { const b = r(e); return [b[0], b[1], b[2], b[3], e.naturalWidth, e.naturalHeight]; });
          const ae = document.activeElement;
          const activeImg = (ae && ae.querySelector) ? imgEls.indexOf(ae.querySelector('img')) : -1;
          const pseudo = (ae && ae.getAttribute) ? ['::before', '::after'].map(p => { const s = getComputedStyle(ae, p); return p + ' content=' + s.content + ' shadow=' + s.boxShadow.slice(0, 60) + ' outline=' + s.outlineStyle + ' border=' + s.borderTopWidth + ' ' + s.borderTopColor + ' opacity=' + s.opacity; }) : [];
          const rings = [...document.querySelectorAll('[class*=ocus i], [class*=ring i], [class*=glow i], [class*=highlight i]')].map(e => ({ cls: String(e.className).slice(0, 60), rect: r(e) })).slice(0, 6);
          const rootData = Object.assign({}, document.documentElement.dataset, document.body.dataset);
          const focusLike = [...app.querySelectorAll(':focus, :focus-visible, [data-focused], [data-focus], [aria-selected=true], [aria-current], [class*=focus i], [class*=select i], [class*=active i]')].map(describe).slice(0, 6);
          const all = [...app.querySelectorAll('*')];
          const sig = e => { const s = cs(e); return [e.getAttribute('class') || '', e.getAttribute('style') || '', [...e.attributes].filter(a => a.name.startsWith('data-') || a.name.startsWith('aria-')).map(a => a.name + '=' + a.value).join(','), s.boxShadow, s.outlineStyle, s.outlineColor, s.borderTopColor, s.backgroundColor, s.transform].join('|'); };
          const sigs = all.map(sig);
          const prev = \(reset ? "null" : "window.__tallPrev");
          const changed = [];
          if (prev && prev.length === sigs.length) {
            for (let i = 0; i < sigs.length; i++) if (sigs[i] !== prev[i]) changed.push({ i, tag: all[i].tagName, text: (all[i].innerText || '').trim().slice(0, 30), before: prev[i].slice(0, 240), after: sigs[i].slice(0, 240), rect: r(all[i]) });
          }
          window.__tallPrev = sigs;
          return JSON.stringify({ viewport: [innerWidth, innerHeight], windowScroll: Math.round(window.scrollY), docHeight: document.documentElement.scrollHeight,
                                  appRect: r(app), scrolls, rowCount: rows.length, firstRow: rows[0] || null, lastRow: rows[rows.length - 1] || null, visibleRows,
                                  imgs, activeImg, pseudo, rings, rootData, active: describe(document.activeElement), focusLike, changed: changed.slice(0, 8), changedCount: changed.length,
                                  elementCount: all.length, prevLength: prev ? prev.length : -1 });
        })()
        """
    }

    // MARK: - The frame as served

    struct FrameIdentifier { let type: String; let identifier: String }

    private func frameIdentifiers() async -> [FrameIdentifier] {
        guard let frame = await lab.lensFrame()?.frame else { return [] }
        var found: [FrameIdentifier] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let identifier = object["identifier"] as? String {
                    found.append(FrameIdentifier(type: object["type"] as? String ?? "?", identifier: identifier))
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(frame)
        return found
    }

    /// The served frame, long strings cut (an image's data), with the response's other fields.
    private func dumpFrame(_ name: String) async {
        guard let served = await lab.lensFrame() else { write("frame \(name): none served"); return }
        func trim(_ node: Any) -> Any {
            if let text = node as? String { return text.count > 120 ? String(text.prefix(60)) + "…(\(text.count))" : text }
            if let object = node as? [String: Any] { return object.mapValues(trim) }
            if let array = node as? [Any] { return array.count > 6 ? Array(array.prefix(4)).map(trim) + ["…(\(array.count))"] : array.map(trim) }
            return node
        }
        let out: [String: Any] = ["fields": served.fields, "payloadBytes": served.payloadBytes, "frame": trim(served.frame)]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.folder.appendingPathComponent("frame-\(name).json"))
        }
        write("frame \(name): fields=\(served.fields) bytes=\(served.payloadBytes)")
    }

    private func dumpDOM(_ name: String) async {
        guard let web = lab.previewPanel.webView as? WKWebView,
              let html = try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String else { return }
        // Image data cut, so the file stays readable.
        let trimmed = html.replacingOccurrences(of: #"data:image/[^"')]{80,}"#, with: "data:image/…", options: .regularExpression)
        try? trimmed.data(using: .utf8)?.write(to: Self.folder.appendingPathComponent("dom-\(name).html"))
    }

    // MARK: - Views

    private func rows(_ count: Int, tag: String) -> [String] {
        (1...count).map { String(format: "%@%02d ", tag, $0) + "Sample line \($0) for the lens" }
    }

    /// `count` rows sharing `total` characters, each a run of words.
    static func longRows(count: Int, total: Int, tag: String) -> [String] {
        let words = "the nameplate gives the breaker size and the wire gauge for this unit".split(separator: " ")
        let each = max(20, total / count)
        return (1...count).map { index in
            var text = String(format: "%@%02d ", tag, index)
            var word = 0
            while text.count < each {
                text += words[word % words.count] + " "
                word += 1
            }
            return String(text.prefix(each))
        }
    }

    /// A meta title over `rows` tappable one-paragraph rows, with an optional primary button
    /// before row `primaryAt` (`rows.count` puts it after the last).
    static func column(title: String, rows: [String], primaryAt: Int? = nil, card: Bool = false,
                       recorder: TapRecorder) -> FlexBox {
        var components: [any ViewComponent] = [Text(title, style: .meta, color: .secondary)]
        func primary() -> any ViewComponent {
            ButtonGroup(alignment: .center) {
                Button(label: "Primary", style: .primary, onClick: { recorder.record("button") })
                    .actionRole(.primary)
            }
        }
        for (index, text) in rows.enumerated() {
            if primaryAt == index { components.append(primary()) }
            let id = String(text.prefix { $0 != " " })
            let row = FlexBox(direction: .column, spacing: 0, alignment: .start, padding: EdgeInsets(all: 4)) {
                Text(text, style: .body, color: .primary)
            }
            .alignSelf(.stretch)
            components.append((card ? row.background(.card) : row).onTap { recorder.record(id) })
        }
        if primaryAt == rows.count { components.append(primary()) }
        return root(components)
    }

    static func grid(title: String, tile: CGSize, card: Bool = false, recorder: TapRecorder) -> FlexBox {
        var components: [any ViewComponent] = [Text(title, style: .meta, color: .secondary)]
        for row in 0..<3 {
            let tiles: [any ViewComponent] = (0..<3).map { column in
                let id = "G\(row + 1)\(column + 1)"
                let picture = Image(image: tileImage(size: tile, label: id, hue: CGFloat(row * 3 + column) / 9), sizePreset: .fill)
                let box = FlexBox(direction: .column, spacing: 0, alignment: .start) { picture }
                return (card ? box.background(.card) : box).onTap { recorder.record(id) }
            }
            components.append(FlexBox(direction: .row, spacing: 8, alignment: .start) { for t in tiles { t } })
        }
        return root(components)
    }

    static func singleImageRows(title: String, sizes: [CGSize], recorder: TapRecorder) -> FlexBox {
        var components: [any ViewComponent] = [Text(title, style: .meta, color: .secondary)]
        for (index, size) in sizes.enumerated() {
            let id = "I\(index + 1)"
            let picture = Image(image: tileImage(size: size, label: "\(Int(size.width))x\(Int(size.height))",
                                                 hue: CGFloat(index) / 4), sizePreset: .fill)
            components.append(FlexBox(direction: .row, spacing: 0, alignment: .start) {
                FlexBox(direction: .column, spacing: 0, alignment: .start) { picture }.onTap { recorder.record(id) }
            })
        }
        return root(components)
    }

    static func stack(title: String, slices: Int, slice: CGSize, recorder: TapRecorder, seed: Int = 0) -> FlexBox {
        var components: [any ViewComponent] = [Text(title, style: .meta, color: .secondary)]
        for index in 0..<slices {
            let id = String(format: "P%02d", index + 1)
            let picture = Image(image: sliceImage(size: slice, index: index, of: slices, seed: seed), sizePreset: .fill)
            components.append(FlexBox(direction: .column, spacing: 0, alignment: .start) { picture }
                .onTap { recorder.record(id) })
        }
        return root(components)
    }

    private static func root(_ components: [any ViewComponent]) -> FlexBox {
        FlexBox(direction: .column, spacing: 6, alignment: .start,
                padding: EdgeInsets(top: 12, bottom: 20, leading: 12, trailing: 12)) {
            for component in components { component }
        }
    }

    // MARK: - Test images

    /// A tile: a solid colour, a white frame and its label large in the middle.
    static func tileImage(size: CGSize, label: String, hue: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: hue, saturation: 0.7, brightness: 0.6, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setStroke()
            context.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
            draw(label, in: CGRect(origin: .zero, size: size), points: min(size.height * 0.35, 48))
        }
    }

    /// One slice of a tall invented drawing: horizontal rules every 50 px, a gradient by slice, and
    /// the slice's number.
    static func sliceImage(size: CGSize, index: Int, of count: Int, seed: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.1 + 0.5 * CGFloat(index) / CGFloat(max(1, count)), alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: CGFloat((index + seed) % 6) / 6, saturation: 0.6, brightness: 0.9, alpha: 1).setStroke()
            for y in stride(from: 0, to: size.height, by: 50) {
                context.stroke(CGRect(x: 0, y: y, width: size.width, height: 1))
            }
            draw(String(format: "P%02d of %d", index + 1, count), in: CGRect(origin: .zero, size: size), points: 40)
        }
    }

    private static func draw(_ text: String, in rect: CGRect, points: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: points),
                                                         .foregroundColor: UIColor.white]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2),
                                withAttributes: attributes)
    }

    // MARK: - Evidence

    private func capture(_ name: String, note: String = "") async {
        state.step += 1
        let file = String(format: "%02d-%@.png", state.step, name)
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let image = lab.snapshot(), let data = image.pngData() {
            try? data.write(to: Self.folder.appendingPathComponent(file))
            write("snapshot \(file) \(note)")
        } else {
            write("snapshot \(file) (none) \(note)")
        }
    }

    private func saveResults() {
        var results = state.results
        results["measuredAt"] = ISO8601DateFormatter().string(from: Date())
        results["note"] = "The iOS Simulator's simulated Ray-Ban Display (Mock Device Kit 1.0.1), not the glasses."
        guard JSONSerialization.isValidJSONObject(results),
              let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) else {
            write("results not serialisable")
            return
        }
        try? data.write(to: Self.folder.appendingPathComponent("results.json"))
    }

    private func write(_ line: String) {
        state.lines.append(line)
        lab.note(appState, "tall views " + line)
        let text = state.lines.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: Self.folder.appendingPathComponent("tall-views.log"))
    }

    private func wait(seconds: Double, until condition: () -> Bool,
                      check: (() async -> Bool)? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            if let check, await check() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let value = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return (value * 10).rounded() / 10
    }
}

/// Which tappables' handlers fired, in order. The handlers are `@Sendable` and run off the main
/// actor, so the list is behind a lock.
final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: [String] = []

    func record(_ id: String) {
        lock.lock(); fired.append(id); lock.unlock()
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = fired
        fired = []
        return out
    }
}
#endif
