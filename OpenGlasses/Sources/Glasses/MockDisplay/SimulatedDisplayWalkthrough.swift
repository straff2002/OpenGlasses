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
///
/// Plan MU: the whole page opens with its part highlighted; a press on the picture opens the
/// close-up (or fit width), Back returns. Then the reading view: two answers, a press on an earlier
/// one and ‹ Latest. A press on a tappable box goes through the mock by the identifier the SDK gave
/// it, as a button's.
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
        await fitWidthWalk()
        await answerCardWalk()
        await readingViewWalk()
        write("done")
    }

    // MARK: - The page view

    private func pageViewWalk() async {
        // "Show me the diagram on page 2": the page with two drawings and no captions. It opens on
        // the whole page, the chosen drawing highlighted; a press on the picture opens its
        // close-up, and Back returns to the whole page (Plan MU §6).
        await stage(SimulatedDisplayTestManual.staged(page: 2), words: "show me the diagram on page 2")
        await capture("page2-opening")
        dumpPreview()
        await pressPageBlock(HUDPageScreenBuilder.ItemID.wholePicture, "page2-close-up")
        await pressPage(HUDPageScreenBuilder.ItemID.back, "page2-back")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "close")
    }

    private func otherPages() async {
        // "Show me the page": nothing highlighted; a press on the picture opens it at fit width.
        await stage(SimulatedDisplayTestManual.staged(page: 1, figure: "Figure 1"), words: "show me the page")
        await capture("page1-whole")
        await pressPageBlock(HUDPageScreenBuilder.ItemID.wholePicture, "page1-fit-width")
        await pressPage(HUDPageScreenBuilder.ItemID.back, "page1-back")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page1-close")
        // A cited passage on the text page: the whole page, the passage highlighted and its first
        // sentence under it. A first press from the lens on Read it reads the page closely
        // (`LensOpeningPress`, build 770); after Back, Read it pages its words, and Page goes back
        // to the picture.
        await stage(SimulatedDisplayTestManual.staged(page: 4, cited: true), words: "how do I clear a latched fault")
        await capture("page4-whole")
        await pressPage(HUDPageScreenBuilder.ItemID.readIt, "page4-first-press-close-up")
        await pressPage(HUDPageScreenBuilder.ItemID.back, "page4-first-press-back")
        await pressPage(HUDPageScreenBuilder.ItemID.readIt, "page4-read-it")
        await pressPage(HUDPageScreenBuilder.ItemID.nextText, "page4-reading-next")
        await pressPage(HUDPageScreenBuilder.ItemID.showPicture, "page4-picture")
        await pressPageBlock(HUDPageScreenBuilder.ItemID.wholePicture, "page4-close-up")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page4-close")
        // Two cited passages on the page: both outlined, numbered.
        await stage(SimulatedDisplayTestManual.staged(page: 4, citedTwice: true), words: "how do I clear a latched fault")
        await capture("page4-two-passages")
        await pressPage(HUDPageScreenBuilder.ItemID.readIt, "page4-two-first-press-close-up")
        await pressPage(HUDPageScreenBuilder.ItemID.back, "page4-two-first-press-back")
        await pressPage(HUDPageScreenBuilder.ItemID.readIt, "page4-two-read-it")
        while offered(HUDPageScreenBuilder.ItemID.nextText) {
            await pressPage(HUDPageScreenBuilder.ItemID.nextText, "page4-two-next-\(lensPage.shownState?.readingIndex ?? 0)")
        }
        await pressPage(HUDPageScreenBuilder.ItemID.showPicture, "page4-two-picture")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page4-two-close")
        // The table, outlined as a pictured table: highlighted on the whole page; its close-up is
        // cut into halves when it is wider than the lens.
        await stage(SimulatedDisplayTestManual.staged(page: 3, figure: "Table 1", pictured: true), words: "show me table 1")
        await capture("page3-table")
        await pressPageBlock(HUDPageScreenBuilder.ItemID.wholePicture, "page3-close-up")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "page3-close")
    }

    /// A press whose frame is overtaken by a notification: the notification must stay on the lens.
    private func staleFrameCheck() async {
        await stage(SimulatedDisplayTestManual.staged(page: 2), words: "show me the diagram on page 2")
        await capture("stale-opening")
        if let picture = lensPage.shownScreen?.block(id: HUDPageScreenBuilder.ItemID.wholePicture) {
            picture.action?()
            display.showNotification(title: "Invented alert", body: "Filter check due", icon: .warning, duration: 6)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await capture("stale-notification-wins", note: "pressed the page (direct) then a notification")
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await capture("stale-after-notification")
        if lensPage.held != nil { await pressPage(HUDPageScreenBuilder.ItemID.close, "stale-close") }
    }

    // MARK: - The answer card

    /// Plan MU §6: a page by number at fit width, then "go to the bottom" and Back.
    private func fitWidthWalk() async {
        await stage(SimulatedDisplayTestManual.staged(page: 1, figure: "Figure 1"), words: "show me the page")
        await capture("fit-whole-page", note: "blocks=\(lensPage.shownScreen?.allBlocks.count ?? 0)")
        await pressPageBlock(HUDPageScreenBuilder.ItemID.wholePicture, "fit-width")
        _ = lensPage.handle(.bottom)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await capture("fit-bottom", note: pageState())
        await pressPage(HUDPageScreenBuilder.ItemID.back, "fit-back")
        await pressPage(HUDPageScreenBuilder.ItemID.close, "fit-close")
    }

    /// A press on the page view's block `id` (the whole page's picture) through the mock.
    private func pressPageBlock(_ id: String, _ name: String) async {
        await pressBlock(id, name, screen: { lensPage.shownScreen }, state: { pageState() })
    }

    /// Plan MG §2: two answers as the reading view; a press on the earlier one opens it at the top,
    /// and ‹ Latest goes back.
    private func readingViewWalk() async {
        let style = Config.lensAnswerStyle
        Config.lensAnswerStyle = .scroll
        card.beginTurn(question: "what is the factory charge on the Q-7")
        card.finishTurn(reply: "The Q-7 holds 2.4 kg of R-32 from the factory.\nAdd 15 g a metre past 7.5 m of line set.")
        card.endTurn()
        _ = await wait(seconds: 5) { card.isShowing }
        let reply = [
            "Start with the cover off and the board powered.",
            "Measure TP1 at the intake filter first; it should read between 0.4 and 0.9 volts.",
            "Then measure TP2 at the gain stage, which should sit between 2.1 and 2.6 volts.",
            "If TP1 is low, check the intake filter's fuse and the ribbon cable to the sensor head.",
            "If TP2 is high while TP1 reads normally, the gain stage is the fault: reseat its jumper.",
            "Next, measure TP3 at the output buffer, which should read within a tenth of a volt of TP2.",
            "Record each reading on the job sheet before you replace any part on the board.",
        ]
        card.beginTurn(question: "how do I find a fault on the Q-7 board")
        card.finishTurn(reply: [reply[0], reply[1] + " " + reply[2], reply[3] + " " + reply[4], reply[5], reply[6]]
            .joined(separator: "\n"))
        card.endTurn()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await capture("reading-view", note: "rows=\(card.screenOnLens?.flow.flatMap(\.blocks).count ?? 0) "
                      + "earlier=\(card.screenOnLens?.trailingFlow.flatMap(\.blocks).count ?? 0) reading=\(card.isReadingView)")
        if let earlier = card.screenOnLens?.trailingFlow.flatMap(\.blocks).first {
            await pressBlock(earlier.id, "reading-earlier-opened", screen: { card.screenOnLens }, state: { readingState() })
        }
        await pressCard(HUDReadingViewBuilder.ItemID.latest, "reading-latest")
        await pressCard(HUDAnswerCardBuilder.ItemID.actions, "reading-actions")
        await pressCard(HUDAnswerCardBuilder.ItemID.answer, "reading-back-to-view")
        await pressCard(HUDAnswerCardBuilder.ItemID.close, "reading-close")
        Config.lensAnswerStyle = style
    }

    private func readingState() -> String {
        "reading=\(card.isReadingView) opened=\(card.openedTurnID.map(String.init) ?? "-") "
            + "rows=\(card.screenOnLens?.flow.flatMap(\.blocks).count ?? 0) buttons=\(labels(card.screenOnLens))"
    }

    /// Presses the tappable box `id` through the mock, by the identifier the SDK gave it on the frame
    /// the lens holds (the boxes in tree order are the screen's blocks in column order); without
    /// the test server, or when the lens shows another frame, the block's action directly.
    private func pressBlock(_ id: String, _ name: String, screen: () -> HUDScreen?, state: () -> String) async {
        guard let shown = screen(), let index = shown.allBlocks.firstIndex(where: { $0.id == id }) else {
            write("\(name): block \(id) not on the lens")
            return
        }
        let before = shown.renderKey
        var via = "direct press (the lens never showed this screen's boxes)"
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let boxes = await lensBoxes()
            if boxes.count == shown.allBlocks.count {
                lab.sendClick(identifier: boxes[index])
                via = "sendClick(\"\(boxes[index])\")"
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if via.hasPrefix("direct") {
            write("\(name): the lens frame's boxes: \(await lensBoxShapes()); blocks=\(shown.allBlocks.count)")
            shown.allBlocks[index].action?()
        }
        _ = await wait(seconds: 8) { screen()?.renderKey != before }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await capture(name, note: "pressed block \(id) via \(via); \(state())")
    }

    /// What the frame's identified nodes are (type and keys), to see how a tappable box is marked.
    private func lensBoxShapes() async -> String {
        guard let frame = await lab.lensFrame()?.frame else { return "no frame" }
        var shapes: [String] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if object["identifier"] != nil {
                    shapes.append("\(object["type"] ?? "?"):\(object.keys.sorted().joined(separator: ","))")
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(frame)
        return "\(shapes.count) [" + Set(shapes).sorted().joined(separator: " | ") + "]"
    }

    /// The identifiers the SDK gave the lens frame's tappable boxes, in tree order (a card's own
    /// content is walked after it, so the order is the column's).
    private func lensBoxes() async -> [String] {
        guard let frame = await lab.lensFrame()?.frame else { return [] }
        var found: [String] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                // A box on a card is served as a "card"; a plain tappable box as a "flexBox".
                if ["card", "flexBox"].contains(object["type"] as? String ?? ""),
                   let identifier = object["identifier"] as? String {
                    found.append(identifier)
                }
                if let children = object["children"] { walk(children) }
                for (key, value) in object where key != "children" { walk(value) }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(frame)
        return found
    }

    private func answerCardWalk() async {
        // The paged card (Display & HUD › Answers on the lens › Pages).
        let style = Config.lensAnswerStyle
        Config.lensAnswerStyle = .pages
        defer { Config.lensAnswerStyle = style }
        // About three pages on the lens (about 600 characters at the card's 10 × 32).
        let reply = [
            "Start with the cover off and the board powered.",
            "Measure TP1 at the intake filter first; it should read between 0.4 and 0.9 volts.",
            "Then measure TP2 at the gain stage, which should sit between 2.1 and 2.6 volts.",
            "If TP1 is low, check the intake filter's fuse and the ribbon cable to the sensor head.",
            "If TP2 is high while TP1 reads normally, the gain stage is the fault: reseat its jumper.",
            "Next, measure TP3 at the output buffer, which should read within a tenth of a volt of TP2.",
            "Record each reading on the job sheet before you replace any part on the board.",
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
        let pictures = lensPage.shownScreen?.allBlocks.compactMap(\.picture) ?? []
        let size = pictures.isEmpty ? "none"
            : pictures.map { "\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" }.joined(separator: "+")
        let mode = state.isReading
            ? "reading=\(state.readingIndex + 1)/\(state.readingPages.count)"
            : String(format: "scale=%.2f px/pt=%.2f", Double(viewport.scale), Double(viewport.pixelsPerPoint))
                + " crop=\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width))x\(Int(crop.height))"
        return "held=\(String(describing: lensPage.held)) \(mode) "
            + "whole=\(viewport.isWholePage) diagram=\(state.diagramIndex.map { "\($0 + 1)" } ?? "-")/\(state.diagramCount) "
            + "view=\(state.view) highlight=\(state.highlight.reason.rawValue) halves=\(state.closeUp?.hasHalves ?? false) "
            + "buttons=\(labels(lensPage.shownScreen)) picture=\(size)"
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
