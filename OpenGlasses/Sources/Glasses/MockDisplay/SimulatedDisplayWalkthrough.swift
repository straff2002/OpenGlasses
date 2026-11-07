#if DAT_MOCK_DISPLAY
import Foundation
import UIKit
import WebKit

/// The scripted page walkthrough on the simulated Display (Plan KV P4).
///
/// Stages pages of the invented manual the way a request does, then presses the page view's
/// buttons in order through the mock (`MockDisplayKit.sendClick(identifier:)`), so each press
/// travels the band's path: the DAT button's handler, `MetaDisplayBackend.onItemSelected`, the
/// HUD's selection handler, `LensPageSession`. It then walks a three-page answer card and its
/// Actions. After each step the preview's render is saved as a PNG in Documents/kv-walkthrough/
/// with one line per step in walkthrough.log there. Only invented pages are drawn; nothing is
/// pressed that sends, saves or asks the model anything.
@MainActor
struct SimulatedDisplayWalkthrough {
    let appState: AppState
    let lab: SimulatedDisplayLab

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kv-walkthrough", isDirectory: true)
    }

    private var lensPage: LensPageSession { appState.lensPage }
    private var display: GlassesDisplayService { appState.glassesDisplay }
    private var card: HUDAnswerCard { appState.hudAnswerCard }

    final class Log {
        var lines: [String] = []
        var step = 0
    }
    private let log = Log()

    // MARK: - Run

    func run() async {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.folder)
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        lab.previewVisible = true

        write("start: phase=\(appState.glassesPhase) display=\(display.deviceSupportsDisplay()) "
              + "availability=\(display.displayAvailability.rawValue) hud=\(Config.glassesDisplayEnabled)")
        let connected = await wait(seconds: 20) {
            appState.glassesPhase == .connected && display.deviceSupportsDisplay()
        }
        write("connected=\(connected): phase=\(appState.glassesPhase) "
              + "availability=\(display.displayAvailability.rawValue) worn=\(String(describing: appState.glassesService.isWorn))")
        // A first frame, so the session starts and the preview has something to draw.
        display.showNotification(title: "Simulated Display", body: "Walkthrough starting", icon: .info, duration: 3)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await capture("ready")

        await pageViewWalk()
        await otherPages()
        await staleFrameCheck()
        await answerCardWalk()
        write("done")
    }

    // MARK: - The page view

    private func pageViewWalk() async {
        // "Show me the diagram on page 2": the page with two drawings and no captions.
        await stage(SimulatedDisplayTestManual.staged(page: 2), words: "show me the diagram on page 2")
        await capture("page2-opening")
        dumpPreview()
        await pressPage(HUDPageScreenBuilder.ItemID.zoomIn, "zoom-in-1")
        await pressPage(HUDPageScreenBuilder.ItemID.zoomIn, "zoom-in-2")
        await pressPage(HUDPageScreenBuilder.ItemID.move, "move")
        await pressPage(HUDPageScreenBuilder.ItemID.right, "move-right")
        await pressPage(HUDPageScreenBuilder.ItemID.done, "move-done")
        // Whole page is offered short of the deepest zoom; from the deepest, zoom out to it.
        var outs = 0
        while !offered(HUDPageScreenBuilder.ItemID.wholePage), offered(HUDPageScreenBuilder.ItemID.zoomOut), outs < 3 {
            outs += 1
            await pressPage(HUDPageScreenBuilder.ItemID.zoomOut, "zoom-out-\(outs)")
        }
        await pressPage(HUDPageScreenBuilder.ItemID.wholePage, "whole-page")
        await pressPage(HUDPageScreenBuilder.ItemID.nextDiagram, "next-diagram")
        await pressPage(HUDPageScreenBuilder.ItemID.nextDiagram, "next-diagram-again")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "close")
    }

    private func otherPages() async {
        // "Show me the page": the block diagram's page opens whole; Next diagram focuses it.
        await stage(SimulatedDisplayTestManual.staged(page: 1, figure: "Figure 1"), words: "show me the page")
        await capture("page1-whole")
        await pressPage(HUDPageScreenBuilder.ItemID.nextDiagram, "page1-next-diagram")
        await pressPage(HUDPageScreenBuilder.ItemID.zoomIn, "page1-zoom-in")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page1-close")
        // A cited passage on the text page: the view opens on its words (reading mode), pages them,
        // shows the picture on its mark, and reads them again.
        await stage(SimulatedDisplayTestManual.staged(page: 4, cited: true), words: "how do I clear a latched fault")
        await capture("page4-reading")
        await pressPage(HUDPageScreenBuilder.ItemID.nextText, "page4-reading-next")
        await pressPage(HUDPageScreenBuilder.ItemID.showPicture, "page4-picture")
        await pressPage(HUDPageScreenBuilder.ItemID.zoomIn, "page4-picture-zoom-in")
        await pressPage(HUDPageScreenBuilder.ItemID.readIt, "page4-read-it")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page4-close")
        // Two cited passages on the page: numbered, one after the other.
        await stage(SimulatedDisplayTestManual.staged(page: 4, citedTwice: true), words: "how do I clear a latched fault")
        await capture("page4-two-passages")
        while offered(HUDPageScreenBuilder.ItemID.nextText) {
            await pressPage(HUDPageScreenBuilder.ItemID.nextText, "page4-two-next-\(lensPage.shownState?.readingIndex ?? 0)")
        }
        await pressPage(HUDPageScreenBuilder.ItemID.showPicture, "page4-two-picture")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page4-two-close")
        // The table, outlined as a pictured table: it keeps the picture and fills the width.
        await stage(SimulatedDisplayTestManual.staged(page: 3, figure: "Table 1", pictured: true), words: "show me table 1")
        await capture("page3-table")
        await pressPage(HUDPageScreenBuilder.ItemID.zoomIn, "page3-zoom-in")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page3-close")
    }

    /// A press whose frame is overtaken by a notification: the notification must stay on the lens.
    private func staleFrameCheck() async {
        await stage(SimulatedDisplayTestManual.staged(page: 2), words: "show me the diagram on page 2")
        await capture("stale-opening")
        let item = lensPage.shownScreen?.items.first { $0.id == HUDPageScreenBuilder.ItemID.zoomIn }
        if let item {
            let via = await click(item, on: lensPage.shownScreen)
            display.showNotification(title: "Invented alert", body: "Filter check due", icon: .warning, duration: 6)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await capture("stale-notification-wins", note: "pressed Zoom in (\(via)) then a notification")
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await capture("stale-after-notification")
        if lensPage.held != nil { await pressPage(HUDPageScreenBuilder.ItemID.close, "stale-close") }
    }

    // MARK: - The answer card

    private func answerCardWalk() async {
        // About three pages on the lens.
        let reply = [
            "Start with the cover off and the board powered.",
            "Measure TP1 at the intake filter first; it should read between 0.4 and 0.9 volts.",
            "Then measure TP2 at the gain stage, which should sit between 2.1 and 2.6 volts.",
        ].joined(separator: " ")
        card.beginTurn(question: "how do I find a fault on the Q-7 board")
        card.finishTurn(reply: reply)
        card.endTurn()
        _ = await wait(seconds: 5) { card.isShowing }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await capture("card-page1", note: "pages=\(card.pages.count)")
        await pressCard(HUDAnswerCardBuilder.ItemID.next, "card-page2")
        await pressCard(HUDAnswerCardBuilder.ItemID.next, "card-page3")
        await pressCard(HUDAnswerCardBuilder.ItemID.actions, "card-actions")
        await pressCard(HUDAnswerCardBuilder.ItemID.answer, "card-back-to-answer")
        await pressCard(HUDAnswerCardBuilder.ItemID.back, "card-back")
        await pressCard(HUDAnswerCardBuilder.ItemID.actions, "card-actions-again")
        await pressCard(HUDAnswerCardBuilder.ItemID.close, "card-close")
    }

    // MARK: - Steps

    private func stage(_ staged: FieldSessionService.StagedFigure, words: String) async {
        let original = lensPage.requestWords
        lensPage.requestWords = { words }
        let before = lensPage.shownScreen?.renderKey
        appState.presentOnLens([staged], opening: 0)
        lensPage.requestWords = original
        let opened = await wait(seconds: 10) {
            lensPage.isViewOnLens && lensPage.shownScreen?.renderKey != before
        }
        write("stage p.\(staged.page) \"\(words)\": opened=\(opened) \(pageState())")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private func offered(_ id: String) -> Bool {
        lensPage.shownScreen?.items.contains { $0.id == id } ?? false
    }

    private func pressPage(_ id: String, _ name: String) async {
        await press(id, name, screen: { lensPage.shownScreen }, state: { pageState() })
    }

    private func pressCard(_ id: String, _ name: String) async {
        await press(id, name, screen: { card.screenOnLens }, state: {
            "card page=\(card.pageIndex + 1)/\(card.pages.count) actions=\(card.isOnActions) showing=\(card.isShowing)"
        })
    }

    private func press(_ id: String, _ name: String, screen: () -> HUDScreen?, state: () -> String) async {
        guard let item = screen()?.items.first(where: { $0.id == id }) else {
            write("\(name): \(id) not offered; buttons=\(labels(screen()))")
            return
        }
        let before = screen()?.renderKey
        let revision = display.heldScreenRevision
        let via = await click(item, on: screen())
        _ = await wait(seconds: 8) { screen()?.renderKey != before || display.heldScreenRevision != revision }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await capture(name, note: "pressed \(item.label) via \(via); \(state())")
    }

    /// Presses `item` through the mock, by the identifier the SDK gave its button on the frame the
    /// lens holds (`SimulatedDisplayLab.lensButtons()`): it waits for the lens to show this
    /// screen's buttons, so the press is made on the frame the app last drew. Without the test
    /// server, or when the lens never shows them, the item is pressed directly instead
    /// (`LensPageSession.press(itemID:)` is the same call) and the log says so.
    private func click(_ item: HUDItem, on screen: HUDScreen?) async -> String {
        let title = HUDTextShaper.condense(item.label, max: HUDTextShaper.maxTitleLength)
        let expected = screen?.items.map { HUDTextShaper.condense($0.label, max: HUDTextShaper.maxTitleLength) } ?? [title]
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let buttons = await lab.lensButtons(), buttons.map(\.title) == expected,
               let button = buttons.first(where: { $0.title == title }) {
                lab.sendClick(identifier: button.identifier)
                return "sendClick(\"\(button.identifier)\")"
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        item.action()
        return "direct press (the lens never showed this screen's buttons)"
    }

    private func pageState() -> String {
        guard let state = lensPage.shownState else { return "held=\(String(describing: lensPage.held))" }
        let viewport = state.viewport
        let crop = viewport.cropRect.integral
        let size = lensPage.shownScreen?.picture.map { "\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" } ?? "none"
        let mode = state.isReading
            ? "reading=\(state.readingIndex + 1)/\(state.readingPages.count)"
            : String(format: "scale=%.2f px/pt=%.2f", Double(viewport.scale), Double(viewport.pixelsPerPoint))
                + " crop=\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width))x\(Int(crop.height))"
        return "held=\(String(describing: lensPage.held)) \(mode) "
            + "whole=\(viewport.isWholePage) diagram=\(state.diagramIndex.map { "\($0 + 1)" } ?? "-")/\(state.diagramCount) "
            + "moving=\(state.isMoving) buttons=\(labels(lensPage.shownScreen)) picture=\(size)"
    }

    private func labels(_ screen: HUDScreen?) -> String {
        "[" + (screen?.items.map(\.label).joined(separator: " | ") ?? "") + "]"
    }

    // MARK: - Evidence

    private func capture(_ name: String, note: String = "") async {
        log.step += 1
        let file = String(format: "%02d-%@.png", log.step, name)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let layout = await measure()
        if let image = lab.snapshot(), let data = image.pngData() {
            try? data.write(to: Self.folder.appendingPathComponent(file))
            write("\(file) \(note) | \(layout)")
        } else {
            write("\(file) (no snapshot) \(note) | \(layout)")
        }
    }

    /// How the frame lays out on the simulated lens, in lens pixels (the preview page is 600 CSS px
    /// wide): whether it fits without scrolling, and where the picture, the text and the buttons are.
    private func measure() async -> String {
        guard let web = lab.previewPanel.webView as? WKWebView else { return "layout: no web view" }
        let script = """
        (() => {
          const r = e => { const b = e.getBoundingClientRect(); return [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)]; };
          const scroll = [...document.querySelectorAll('[data-scroll-view=true]')].filter(e => e.scrollHeight > e.clientHeight).map(e => [e.scrollHeight, e.clientHeight, Math.round(e.scrollTop)]);
          const app = document.getElementById('app');
          const img = [...app.querySelectorAll('img')].map(r);
          const buttons = [...app.querySelectorAll('[role=button]')].map(r);
          const texts = [];
          const walker = document.createTreeWalker(app, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.textContent.trim() || node.parentElement.closest('[role=button]')) continue;
            const range = document.createRange(); range.selectNodeContents(node);
            const b = range.getBoundingClientRect();
            texts.push([Math.round(b.top), Math.round(b.height)]);
          }
          return JSON.stringify({scroll, img, buttons, texts, viewport: [innerWidth, innerHeight]});
        })()
        """
        guard let json = try? await web.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let layout = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "layout: unread" }
        let scroll = (layout["scroll"] as? [[Int]]) ?? []
        let buttons = (layout["buttons"] as? [[Int]]) ?? []
        let images = (layout["img"] as? [[Int]]) ?? []
        let texts = (layout["texts"] as? [[Int]]) ?? []
        // Everything drawn inside the 600 × 600 lens: nothing scrolled off or past an edge. `scroll`
        // lists only the scroll views whose content is taller than they are: empty when nothing scrolls.
        let boxesInside = (buttons + images).allSatisfy {
            $0.count == 4 && $0[0] >= 0 && $0[1] >= 0 && $0[0] + $0[2] <= 600 && $0[1] + $0[3] <= 600
        }
        let textInside = texts.allSatisfy { $0.count == 2 && $0[0] >= 0 && $0[0] + $0[1] <= 600 }
        return "layout: fits=\(boxesInside && textInside) scroll=\(scroll) img=\(images) text(top,h)=\(texts) "
            + "buttons=\(buttons.map { "\($0)" }.joined())"
    }

    private func dumpPreview() {
        let tree = lab.previewPanel.describeTree()
        write("preview tree:\n" + tree.joined(separator: "\n"))
        if let web = lab.previewPanel.webView as? WKWebView {
            web.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                guard let html = value as? String else { return }
                try? html.data(using: .utf8)?.write(to: Self.folder.appendingPathComponent("preview-dom.html"))
            }
        }
    }

    private func write(_ line: String) {
        log.lines.append(line)
        lab.note(appState, "walkthrough " + (line.split(separator: "\n").first.map(String.init) ?? line))
        let text = log.lines.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: Self.folder.appendingPathComponent("walkthrough.log"))
    }

    private func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }
}
#endif
