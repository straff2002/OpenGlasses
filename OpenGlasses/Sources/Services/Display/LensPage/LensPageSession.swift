import Combine
import CryptoKit
import Foundation
import UIKit

/// The manual page on the glasses (Plan KV §4): owns the staged pages, the viewport, the cue for a
/// page the app put up by itself, and the view's frames on the lens.
///
/// **Routes.** `stage` takes the pages a turn staged:
/// - a page the technician asked for (`origin == .requested`; `show_source`'s pages are) opens the
///   view at once, with the phone sheet opening as it always has;
/// - a page the app put up by itself gets the **Show here** cue — a card with one button, which an
///   answer replaces as it would a card — and the lens shows the page only after the press;
/// - the answer card's **Page** action (`openStaged`) opens the turn's page;
/// - with the phone locked the view opens anyway: nothing here waits for the app to be in front.
/// Where the lens can't show a picture (the Even G2, a page with no PDF
/// behind it, the HUD off) the old one-line cue (`ManualFigureCue.show`) is all the lens gets.
/// While another app has the Display (KP §8) nothing opens and nothing is taken back.
///
/// **Frames.** The view is pushed through `HUDRouter` over whatever the HUD holds, and closing it
/// returns there. Every press is issued against the revision of the frame it was made on
/// (`GlassesDisplayService.heldScreenRevision`): a press made under a notification is dropped, and
/// a frame rendered for a press is drawn only if nothing was enqueued in between, so a notification
/// that lands between "zoom in" and its render wins and the view stays as it was. A newer press
/// supersedes a render still in flight.
///
/// **Drawing.** Each frame's picture comes from `LensPageRenderer` off the main actor, through a
/// cache keyed by the page's identity and the crop; the opening view, the whole page and the part
/// **Back to part** goes to are drawn as soon as a page is staged, so the press that opens it (and
/// the first press on it) doesn't wait for PDFKit.
///
/// **Where it opens** (Plan MU §6, decision 7): always on the whole page, one picture fitted to
/// the lens, the part the turn was about — the cited passages' marks (a table row), the chosen
/// drawing, the pictured table's area — outlined in the highlight colour and the rest of the page
/// at about half brightness (`LensPageHighlight`). Under the picture, the part's own words: the
/// table row (`LensPageRows`) or the passage's first sentence. Focus opens on the picture, so one
/// pinch opens the part's **close-up** (`LensPageCloseUp`): both halves of a wide part stacked in
/// one strip the lens scrolls, then on down the page; a page with nothing highlighted opens at fit
/// width. **Back** returns to the whole page. With the page's table in the vault, **Rows** shows it
/// one row a card, the cited row first, and a press says a row aloud. Reading mode is one press
/// away (**Read it**) on a page with a cited text passage.
///
/// **Drawings (P1b).** Each page's drawings are found from its ink (`PageFigureLocator`, through
/// `PageFigureAnalysis` and `PageFigureCache`, so a page is analysed once) and one is chosen by
/// what the turn said (`PageFigureAsk`, read from `requestWords` at `stage`; `PageFigureChoice`).
/// A turn that asked for a drawing makes it the highlight, ahead of any cited passage. "Next
/// diagram" and "the bottom one" (by voice) open the close-up of that drawing and highlight it.
///
/// **Reading mode (§1).** A page with a cited text passage (`LensPageLayout.reading`) offers **Read
/// it**: the passage's own words as lens text, paged with the backend's geometry
/// (`readingGeometry`), with **Page** back to the whole page. While reading mode is up, "next" and
/// "back" page the text and are taken even with nowhere to go, so a task card under the view never
/// takes a step it isn't showing.
///
/// **What is recorded.** Each view, close-up, zoom, move, rows view, reading page and close goes to
/// the page audit trail (`audit`) as the page reference, the crop and what was highlighted and why
/// (reading mode's and the rows' lines carry no crop); the support report counts views, presses
/// (per view), close-ups, rows, zooms and moves, what was highlighted, the size of every picture
/// sent and the picture factor, and times renders and sends. Never the page's text or pixels.
@MainActor
final class LensPageSession: ObservableObject {

    /// Why a page reached the lens, for the audit trail.
    enum Route: String, Equatable {
        case requested
        /// The app put it up; the technician pressed **Show here**.
        case automatic
        /// The answer card's **Page** action.
        case answerCard = "answer_card"
    }

    /// One staged page and where its PDF is.
    struct Page: Equatable {
        let staged: FieldSessionService.StagedFigure
        let source: URL?
        /// The figure's identity: what the cache and the render queue key the page by. A hash, so
        /// it names no document.
        let identity: String
        /// What the turn said about the drawing it wants (Plan KV P1b).
        var ask: PageFigureAsk = .none

        /// What its layout is kept by: the page, and the ask that chose its drawing.
        var layoutKey: String { identity + "\u{1F}" + ask.key }

        var request: LensPageRequest? {
            source.map { LensPageRequest(staged: staged, source: $0, ask: ask) }
        }
    }

    /// A page view with no press for this long closes, as Close would.
    static let defaultViewLifetime: TimeInterval = 180
    /// A **Show here** cue with no press for this long goes.
    static let defaultCueLifetime: TimeInterval = 20

    private let display: GlassesDisplayService
    private let router: HUDRouter

    // MARK: Wiring and seams

    /// The PDF a staged page comes from (AppState: the session's or the personal library's).
    var sourceURL: (FieldSessionService.StagedFigure) -> URL? = { _ in nil }
    /// The technician's words for the turn that staged the pages: what a drawing request is read
    /// from (`PageFigureAsk.parse`). Nil outside a spoken or typed turn.
    var requestWords: @MainActor () -> String? = { TechnicianWords.current() }
    /// Lays out a page (PDFKit, off the main actor). A seam so tests can hold or fail it.
    var layoutPage: (LensPageRequest) async -> LensPageLayout? = { await LensPageRenderer.layout($0) }
    /// How reading mode lays text out: the lens frame's lines and characters on the Display
    /// (`LensPageFrame.readingGeometry`), the Even panel's own on Even.
    var readingGeometry: () -> TeleprompterPaginator.Geometry = { LensPageSession.activeReadingGeometry() }

    /// Reading mode's geometry for the backend that shows the HUD, as for the answer card.
    static func activeReadingGeometry() -> TeleprompterPaginator.Geometry {
        #if !AVENKIN_PHONE_ONLY
        return LensPageFrame.readingGeometry(for: Config.displayBackend == .evenG2 ? .evenG2 : .metaDisplay)
        #else
        return LensPageFrame.readingGeometry(for: .metaDisplay)
        #endif
    }
    /// Draws one picture (PDFKit and Core Graphics, off the main actor). A seam so tests can hold
    /// a render until a notification has landed.
    var renderPicture: (LensPageRequest, LensPageRenderPlan) async -> UIImage? = {
        await LensPageRenderer.render($0, plan: $1)
    }
    /// The page audit trail (AppState: `FieldSessionService.logPageOnGlasses`).
    var audit: ((LensPageAuditLine) -> Void)?
    /// The one-line cue, where the page view can't open.
    lazy var showCueLine: (FieldSessionService.StagedFigure) -> Void = { [weak self] staged in
        guard let self else { return }
        ManualFigureCue.show(staged, on: self.display)
    }
    var backend: () -> String = BandPracticeSession.activeBackendToken
    /// The colour the marks are drawn in (Display & HUD › Highlight colour). A seam for tests.
    var highlight: () -> LensHighlightColour = { Config.lensHighlightColour }
    var viewLifetime: TimeInterval = LensPageSession.defaultViewLifetime
    var cueLifetime: TimeInterval = LensPageSession.defaultCueLifetime
    var scheduleTimer: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }
    /// Test seam: what "now" is for the render timings.
    var clock: () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// Plan MU §6: the tables printed in a staged page's document, as `table_lookup` reads them
    /// (AppState: `FieldSessionService.lensPageTables`), for **Rows** and the row's words.
    var pageTables: (FieldSessionService.StagedFigure) -> [ManualTable] = { _ in [] }
    /// Plan MU §6: says a pressed row aloud (AppState: the answer card's Repeat path).
    var speak: ((String) -> Void)?
    /// Plan MU §0: the picture factor the Meta backend shrinks pictures by, for the report's sizes.
    var pictureFactor: @MainActor () -> CGFloat = { LensPictureScale.activeFactor() }

    // MARK: State

    /// The pages the last staging put up, and which one is open.
    private(set) var pages: [Page] = []
    private(set) var pageIndex = 0
    /// What the lens holds for this session: the view, the cue, or nothing.
    @Published private(set) var held: GlassesDisplayService.HeldPage?
    /// The view's state as last drawn on the lens.
    private(set) var shownState: HUDPageViewState?
    /// The screen last handed to the lens: what a band press acts on.
    private(set) var shownScreen: HUDScreen?
    private var route: Route = .requested
    @Published private(set) var stats = LensPageStats()

    let cache: LensPageRenderCache
    private var layouts: [String: LensPageLayout] = [:]
    /// Plan MU §6: each laid-out page's table rows (nil: none), read once per page.
    private var rowsByPage: [String: LensPageRows?] = [:]
    /// Plan MU §6: presses on the open view, for the report's presses per view.
    private var viewPresses = 0
    private var layoutTasks: [String: Task<LensPageLayout?, Never>] = [:]
    private var renderTasks: [String: Task<HUDPicture?, Never>] = [:]
    /// Bumped by every open and every press; a frame finished for an older one is not drawn.
    private var generation = 0
    private var timerGeneration = 0
    private var work: [Task<Void, Never>] = []
    private var heldWatch: AnyCancellable?
    /// Audit lines waiting for their frame to reach the glasses, by the frame's render key. The
    /// trail says "shown on the glasses", so a line is written only once the glasses took the
    /// frame (`GlassesDisplayService.onScreenDelivered`). Build 705 wrote it at the hand-off, and a
    /// Ray-Ban Display report showed pages "shown" while every send to the lens failed.
    private var awaitingDelivery: [String: (event: LensPageAuditLine.Event, page: Page, state: HUDPageViewState?)] = [:]
    /// Whether any frame of the open view reached the glasses, so a close is recorded only for a
    /// view that was on the lens.
    private var viewReachedLens = false
    /// Plan MU §7: one band send in flight at a time, and the frame it is waiting on.
    private var bandGate = LensBandNavGate()
    private var bandPendingKey: String?

    init(display: GlassesDisplayService, router: HUDRouter, cache: LensPageRenderCache? = nil) {
        self.display = display
        self.router = router
        self.cache = cache ?? LensPageRenderCache()
        display.onScreenDelivered = { [weak self] renderKey, delivered in
            self?.frameDelivered(renderKey: renderKey, delivered: delivered)
        }
        heldWatch = display.$heldPage.sink { [weak self] page in
            // Something else took the lens (a task card, a menu, an answer replacing the cue).
            guard let self, page == nil, self.held != nil else { return }
            self.lensTaken()
        }
    }

    /// The page view itself (not the cue) is the frame on the glasses, and the lens is ours.
    var isViewOnLens: Bool {
        held == .view && display.heldPage == .view && display.displayAvailability != .inUse
    }

    /// Whether a staged page can open on the lens now: the HUD on, a display that draws pictures,
    /// the Display ours, and a PDF behind the page.
    func canOpenOnLens(_ page: Page? = nil) -> Bool {
        guard Config.glassesDisplayEnabled, display.drawsPictures, display.deviceSupportsDisplay(),
              display.displayAvailability != .inUse else { return false }
        guard let page = page ?? currentPage else { return false }
        return page.source != nil && page.staged.page >= 1
    }

    /// The turn's page can be opened from the answer card's **Page** action.
    var canOpenStaged: Bool { held != .view && canOpenOnLens() }

    private var currentPage: Page? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    /// The identity a staged page is cached and de-duplicated by: the document, its revision and
    /// file, the page and what the page marks (`marksKey` names chunks, never text), hashed.
    nonisolated static func identity(of staged: FieldSessionService.StagedFigure) -> String {
        let raw = [staged.documentId, staged.sourceRevision ?? "", staged.sourceFile ?? "",
                   "\(staged.page)", staged.marksKey].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "Figure 12 · p. 30" — the citation line over the view's first frame (§5).
    nonisolated static func citation(for staged: FieldSessionService.StagedFigure) -> String {
        let page = String(localized: "p. \(staged.page)", comment: "Glasses: a manual page's number, e.g. 'p. 30'.")
        guard let figure = staged.figure?.trimmingCharacters(in: .whitespaces), !figure.isEmpty else { return page }
        return "\(figure) · \(page)"
    }

    // MARK: - Staging (the routes of §4)

    /// The pages a turn staged, opening on `opening`. A requested page opens the view; one the app
    /// put up by itself gets the **Show here** cue; where the lens can't draw it, the one-line cue.
    func stage(_ staged: [FieldSessionService.StagedFigure], opening: Int = 0) {
        guard staged.indices.contains(opening) else { return }
        // Plan KV P1b: whether the turn asked for a drawing, and which, decides where the view
        // opens on each page (`PageFigureAsk`).
        let said = requestWords()
        let next = staged.map {
            Page(staged: $0, source: sourceURL($0), identity: Self.identity(of: $0),
                 ask: PageFigureAsk.parse(said: said, caption: $0.figure, origin: $0.origin))
        }
        let opened = next[opening]
        // The same page already in the view: a follow-up about it, or "show that again".
        if held == .view, let current = currentPage, current.identity == opened.identity {
            // The view keeps the ask it opened with, so its layout (and its drawings) stay found.
            var kept = next
            kept[opening] = current
            pages = kept
            pageIndex = opening
            return
        }
        guard canOpenOnLens(opened) else {
            if display.displayAvailability == .inUse, Config.glassesDisplayEnabled, display.drawsPictures {
                refuse("inUse")
            }
            showCueLine(opened.staged)
            return
        }
        // A page the app put up by itself never replaces a view the technician is using: the line
        // says where it is, and the view keeps its pages.
        if held == .view, opened.staged.origin != .requested {
            showCueLine(opened.staged)
            return
        }
        pages = next
        pageIndex = opening
        prepare(opened)
        if opened.staged.origin == .requested {
            openView(route: .requested)
        } else {
            showCue()
        }
    }

    /// The answer card's **Page**: open the turn's page.
    func openStaged() {
        guard canOpenStaged else { return }
        openView(route: .answerCard)
    }

    // MARK: - The cue

    private func showCue() {
        guard let page = currentPage else { return }
        // A cue gives way to an answer like a card does, so it goes up only where a card could:
        // over nothing or an answer card. Over a task card or a menu it is the one-line cue.
        guard !display.isInteractive || display.showsAnswerCard || display.heldPage == .cue else {
            showCueLine(page.staged)
            return
        }
        generation += 1
        let screen = HUDPageScreenBuilder.cue(ManualFigureCue.line(for: page.staged), onAction: onAction)
        guard router.presentPage(screen, kind: .cue, onSelect: selectionHandler) else {
            refuse("lens")
            return
        }
        held = .cue
        shownScreen = screen
        shownState = nil
        stats.update(backend()) { $0.cuesShown += 1 }
        recordWhenDelivered(.cueShown, screen: screen, page: page, state: nil)
        armTimer(cueLifetime)
    }

    // MARK: - Opening the view

    private func openView(route: Route) {
        guard let page = currentPage, let request = page.request else { return }
        self.route = route
        generation += 1
        let opening = generation
        track { [weak self] in
            guard let self else { return }
            guard let layout = await self.layout(for: page, request: request) else {
                guard opening == self.generation else { return }
                self.renderFailed(page)
                return
            }
            let state = Self.openingState(layout, page: page, hasNextPage: self.pageIndex + 1 < self.pages.count,
                                          geometry: self.readingGeometry(), rows: self.rows(for: page))
            guard let screen = await self.screen(for: state, page: page, layout: layout, request: request) else {
                guard opening == self.generation else { return }
                self.renderFailed(page)
                return
            }
            guard opening == self.generation else { return }
            guard self.router.presentPage(screen, kind: .view, onSelect: self.selectionHandler) else {
                self.refuse("lens")
                return
            }
            self.held = .view
            self.shownState = state
            self.shownScreen = screen
            self.viewPresses = 0
            self.stats.update(self.backend()) { entry in
                entry.viewsOpened += 1
                if state.isReading { entry.readingViews += 1 }
                entry.highlights[state.highlight.reason.rawValue, default: 0] += 1
            }
            self.noteSent(screen)
            PrivacyLog.device(.hud, .lensPageOpened, state: PrivacyToken(route.rawValue),
                              detail: PrivacyToken(self.backend()))
            self.recordWhenDelivered(.opened, screen: screen, page: page, state: state)
            self.armTimer(self.viewLifetime)
            self.renderAhead(state, page: page, layout: layout, request: request)
        }
    }

    // MARK: - Presses

    /// A band press acts on the buttons of the frame last drawn.
    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let shown = self?.shownScreen else { return }
            if let item = shown.items.first(where: { $0.id == id }) {
                item.action()
            } else {
                shown.block(id: id)?.action?()   // Plan MU §6: the whole page's picture, a row
            }
        }
    }

    private var onAction: (HUDPageAction) -> Void {
        { [weak self] action in
            guard let self else { return }
            self.handle(action, issuedAgainst: self.display.heldScreenRevision)
        }
    }

    /// A press on the phone preview's copy of the frame (Plan KV P3, `HUDRouter.pressFromPreview`):
    /// the button `id` of the frame last drawn, run exactly as a band press on it is. False when
    /// nothing is held or the frame has no such button.
    @discardableResult
    func press(itemID id: String) -> Bool {
        guard held != nil, let shown = shownScreen else { return false }
        if let item = shown.items.first(where: { $0.id == id }) {
            item.action()
            return true
        }
        guard let action = shown.block(id: id)?.action else { return false }
        action()
        return true
    }

    /// A press issued against `revision`: dropped when another frame has been enqueued since.
    func handle(_ action: HUDPageAction, issuedAgainst revision: UInt64) {
        guard let held, display.heldPage == held else { return }
        guard display.acceptsHeldScreenPress(issuedAgainst: revision) else {
            stats.update(backend()) { $0.stalePressesDropped += 1 }
            return
        }
        if held == .cue {
            guard action == .showHere else { return }
            stats.update(backend()) { $0.showHerePressed += 1 }
            openView(route: .automatic)
            return
        }
        guard let shown = shownState else { return }
        viewPresses += 1
        stats.update(backend()) { $0.presses += 1 }
        var next = shown
        var event: LensPageAuditLine.Event?
        switch action {
        case .closeUp:
            guard shown.view == .whole else { return }
            next = Self.closeUpState(shown)
            event = .closeUp
        case .back:
            guard shown.view != .whole, shown.view != .reading else { return }
            next = Self.wholeState(shown)
            event = .whole
        case .rows:
            guard shown.rows != nil, shown.view != .rows else { return }
            next.showsRows = true
            next.closeUp = nil
            next.isReading = false
            event = .rows
        case .speakRow(let index):
            guard shown.view == .rows, let rows = shown.rows, rows.rows.indices.contains(index) else { return }
            speak?(rows.rows[index].spoken)
            stats.update(backend()) { $0.rowsSpoken += 1 }
            return
        case .zoomIn:
            next = Self.leavingCloseUp(shown)
            next.viewport.zoomIn(); event = .zoomed
        case .zoomOut:
            next = Self.leavingCloseUp(shown)
            next.viewport.zoomOut(); event = .zoomed
        case .wholePage:
            next = Self.wholeState(shown); event = .whole
        case .step(let step):
            next = Self.leavingCloseUp(shown)
            next.viewport.move(step); event = .moved
        case .nextPage:
            goToPage(pageIndex + 1, issuedAgainst: revision)
            return
        case .nextDiagram:
            guard let layout = currentLayout, let target = Self.nextDiagram(after: shown, in: layout) else { return }
            next = Self.state(shown, onDrawing: target, layout: layout)
            event = .moved
        case .close:
            close()
            return
        case .showHere:
            return
        case .nextText:
            guard shown.isReading, shown.readingIndex + 1 < shown.readingPages.count else { return }
            next.readingIndex += 1; event = .readPage
        case .previousText:
            guard shown.isReading, shown.readingIndex > 0 else { return }
            next.readingIndex -= 1; event = .readPage
        case .showPicture:
            guard shown.isReading else { return }
            next = Self.pictureState(shown)
            event = .picture
        case .readIt:
            guard !shown.isReading, shown.canRead else { return }
            next.isReading = true
            next.showsRows = false
            next.closeUp = nil
            event = .reading
        }
        next.isFirstFrame = false
        next = next.framed()
        guard next != shown else { return }     // a move against an edge does nothing
        draw(next, event: event, issuedAgainst: revision)
    }

    /// A spoken page word (`HUDPageCommand`). True when it did something; one with nothing to do
    /// ("next page" on the last one, "zoom in" at the deepest step) is left for the caller.
    @discardableResult
    func handle(_ command: HUDPageCommand) -> Bool {
        guard isViewOnLens, let shown = shownState else { return false }
        let revision = display.heldScreenRevision
        if shown.isReading { return handleWhileReading(command, shown: shown, revision: revision) }
        switch command {
        case .zoomIn:
            let from = Self.leavingCloseUp(shown)
            guard from.viewport.canZoomIn else { return false }
            handle(.zoomIn, issuedAgainst: revision)
        case .zoomOut:
            let from = Self.leavingCloseUp(shown)
            guard from.viewport.canZoomOut else { return false }
            handle(.zoomOut, issuedAgainst: revision)
        case .wholePage:
            guard shown.view != .whole else { return false }
            handle(.wholePage, issuedAgainst: revision)
        case .move(let step):
            guard Self.leavingCloseUp(shown).viewport.canMove(step) else { return false }
            handle(.step(step), issuedAgainst: revision)
        case .corner(let corner):
            var next = Self.leavingCloseUp(shown)
            next.viewport.jump(to: corner)
            return drawSpoken(next, from: shown, event: .moved, revision: revision)
        case .nextPage:
            guard pageIndex + 1 < pages.count else { return false }
            handle(.nextPage, issuedAgainst: revision)
        case .nextDiagram:
            guard shown.hasNextDiagram else { return false }
            handle(.nextDiagram, issuedAgainst: revision)
        case .diagram(let position):
            // "The bottom one": the drawing that position names, when it names one other than
            // the one already shown.
            guard let layout = currentLayout,
                  let target = PageFigureChoice.index(for: position, in: layout.drawings),
                  layout.drawings.indices.contains(target) else { return false }
            return drawSpoken(Self.state(shown, onDrawing: target, layout: layout), from: shown,
                              event: .moved, revision: revision)
        case .back:
            if shown.view != .whole {
                handle(.back, issuedAgainst: revision)     // to the whole page
            } else if shown.canRead {
                handle(.readIt, issuedAgainst: revision)   // the whole page of a passage: its words
            } else {
                return false
            }
        case .close:
            close()
        case .readIt:
            guard shown.canRead else { return false }
            handle(.readIt, issuedAgainst: revision)
        case .next, .showPage:
            // Picture words only in reading mode: "next" here is left to whatever is under the view.
            return false
        case .zoomInto(let area):
            var next = Self.leavingCloseUp(shown)
            next.viewport.zoom(into: area)
            return drawSpoken(next, from: shown, event: .zoomed, revision: revision)
        case .zoomIntoTable:
            guard let layout = currentLayout, let viewport = layout.viewportOnTable() else { return false }
            var next = Self.leavingCloseUp(shown)
            next.viewport = viewport
            return drawSpoken(next, from: shown, event: .zoomed, revision: revision)
        case .zoomIntoDiagram:
            guard let layout = currentLayout,
                  let target = layout.figureIndex ?? (layout.drawings.isEmpty ? nil : 0) else { return false }
            return drawSpoken(Self.state(shown, onDrawing: target, layout: layout), from: shown,
                              event: .zoomed, revision: revision)
        case .closeUp:
            return drawSpoken(Self.closeUpState(Self.wholeState(shown)), from: shown, event: .closeUp, revision: revision)
        case .half(let half):
            var next = shown.view == .closeUp ? shown : Self.closeUpState(Self.wholeState(shown))
            guard next.closeUp?.hasHalves == true else { return false }
            next.closeUp?.only = half
            return drawSpoken(next, from: shown, event: .closeUp, revision: revision)
        case .bottom:
            var next = Self.wholeState(shown)
            next.closeUp = .fitWidth(pageSize: shown.viewport.pageSize, fromBottom: true)
            return drawSpoken(next, from: shown, event: .closeUp, revision: revision)
        case .rows:
            guard shown.rows != nil, shown.view != .rows else { return false }
            handle(.rows, issuedAgainst: revision)
        case .showRow(let name):
            guard let rows = shown.rows, let index = rows.index(matching: name) else { return false }
            var next = shown
            next.rows = LensPageRows(title: rows.title, rows: rows.rows, highlighted: index)
            next.showsRows = true
            next.closeUp = nil
            return drawSpoken(next, from: shown, event: .rows, revision: revision)
        }
        return true
    }

    /// A spoken word's view, drawn as a press would be: counted as one, never the first frame.
    private func drawSpoken(_ state: HUDPageViewState, from shown: HUDPageViewState,
                            event: LensPageAuditLine.Event, revision: UInt64) -> Bool {
        var next = state
        next.isFirstFrame = false
        next = next.framed()
        guard next != shown, display.acceptsHeldScreenPress(issuedAgainst: revision) else { return false }
        viewPresses += 1
        stats.update(backend()) { $0.presses += 1 }
        draw(next, event: event, issuedAgainst: revision)
        return true
    }

    /// Plan MU §7 (P6): one input from the band, heard only in a flagged (TestFlight-only) build,
    /// whose Inputs wiring calls this. Left and right move a close-up between its halves, and fit
    /// width to the page before or after (`LensBandNavMap`), one send each; up and down stay the
    /// lens's own scroll and nothing else is mapped. One send at a time (`LensBandNavGate`): a burst
    /// is dropped, never queued. A swipe is counted on its own, not as a press.
    @discardableResult
    func handleBand(_ input: GlassesInputKind) -> LensBandOutcome {
        guard isViewOnLens, let shown = shownState else { return .notOnLens }
        guard let nav = LensBandNav(input) else {
            stats.update(backend()) { $0.bandOther += 1 }
            return .notMapped
        }
        let context = LensBandNavMap.Context(shown, pageIndex: pageIndex, pageCount: pages.count)
        guard let action = LensBandNavMap.action(for: nav, in: context) else {
            stats.update(backend()) { $0.bandNothingToDo += 1 }
            return .nothingToDo
        }
        guard bandGate.admit(at: clock()) else {
            stats.update(backend()) { $0.bandDropped += 1 }
            return .dropped
        }
        let revision = display.heldScreenRevision
        switch action {
        case .rightHalf, .leftHalf:
            var next = shown
            next.closeUp?.only = action == .rightHalf ? .right : nil
            next.isFirstFrame = false
            next = next.framed()
            guard next != shown else {
                bandGate.finished()
                stats.update(backend()) { $0.bandNothingToDo += 1 }
                return .nothingToDo
            }
            stats.update(backend()) { $0.bandSwipes += 1; $0.bandHalves += 1 }
            draw(next, event: .closeUp, issuedAgainst: revision, band: true)
        case .previousPage, .nextPage:
            stats.update(backend()) { $0.bandSwipes += 1; $0.bandPages += 1 }
            goToPage(pageIndex + (action == .nextPage ? 1 : -1), atFitWidth: true,
                     issuedAgainst: revision, band: true)
        }
        return .sent(action)
    }

    /// Plan MU §7: the band's channel became active for the open view, or failed (for the report).
    func noteBandListening() { stats.update(backend()) { $0.bandListening += 1 } }
    func noteBandFailed() { stats.update(backend()) { $0.bandFailures += 1 } }

    /// A band send was drawn and handed over, or will never be: the next swipe may go.
    private func bandSendEnded() {
        bandPendingKey = nil
        bandGate.finished()
    }

    /// The words while reading mode is up. "Next" and "back" page the text, and are taken even with
    /// nowhere to go, so a task card under the view never takes a step it isn't showing; "show the
    /// page" (or "whole page") goes to the picture; the picture's own words wait for it.
    private func handleWhileReading(_ command: HUDPageCommand, shown: HUDPageViewState, revision: UInt64) -> Bool {
        switch command {
        case .next:
            handle(.nextText, issuedAgainst: revision)
        case .back:
            handle(.previousText, issuedAgainst: revision)
        case .showPage, .wholePage:
            handle(.showPicture, issuedAgainst: revision)
        case .readIt:
            break   // already reading
        case .nextPage:
            guard pageIndex + 1 < pages.count else { return false }
            handle(.nextPage, issuedAgainst: revision)
        case .close:
            close()
        case .zoomIn, .zoomOut, .move, .corner, .nextDiagram, .diagram, .zoomInto, .zoomIntoTable, .zoomIntoDiagram,
             .closeUp, .half, .bottom, .rows, .showRow:
            return false
        }
        return true
    }

    /// The open page's layout, once laid out.
    private var currentLayout: LensPageLayout? { currentPage.flatMap { layouts[$0.layoutKey] } }

    /// Plan MU §6: the page's table as rows, read once per page from the vault's tables.
    private func rows(for page: Page) -> LensPageRows? {
        if let known = rowsByPage[page.layoutKey] { return known }
        let rows = LensPageRows.make(tables: pageTables(page.staged), page: page.staged.page,
                                     cited: page.staged.citedPassages, figure: page.staged.figure)
        rowsByPage[page.layoutKey] = .some(rows)
        return rows
    }

    /// The view's first state on a page (Plan MU §6): the whole page, the part the turn was about
    /// highlighted and its words under the picture, the passage's words one press away (**Read
    /// it**), the page's table rows one press away (**Rows**), and its drawings for "next diagram".
    static func openingState(_ layout: LensPageLayout, page: Page, hasNextPage: Bool,
                             geometry: TeleprompterPaginator.Geometry = .raybanDisplay,
                             rows: LensPageRows? = nil) -> HUDPageViewState {
        var state = HUDPageViewState(viewport: layout.openingViewport, legibility: layout.legibility,
                                     citation: citation(for: page.staged), hasNextPage: hasNextPage,
                                     diagramCount: layout.drawings.count, diagramIndex: layout.partDrawing)
        state.rows = rows
        state.highlight = LensPageHighlight.of(layout, cited: page.staged.citedPassages, page: page.staged.page,
                                               rows: rows)
        if let reading = layout.reading {
            state.readingPages = reading.pages(geometry: geometry)
        }
        return state.framed()
    }

    /// The whole page from any view: the highlight kept, nothing over it but its words.
    static func wholeState(_ shown: HUDPageViewState) -> HUDPageViewState {
        var next = shown
        next.closeUp = nil
        next.showsRows = false
        next.isReading = false
        next.viewport.showWholePage()
        return next
    }

    /// A pinch on the whole page: the highlighted part's close-up, or with no highlight the page at
    /// fit width from its top.
    static func closeUpState(_ shown: HUDPageViewState) -> HUDPageViewState {
        var next = shown
        next.showsRows = false
        next.isReading = false
        let pageSize = shown.viewport.pageSize
        if let part = shown.highlight.part {
            // The whole page's zoom in a frame with nothing over the picture, so the close-up is the
            // same whichever frame it was opened from.
            next.closeUp = .of(part: part, pageSize: pageSize, legibility: shown.highlight.legibility,
                               wholePagePixelsPerPoint: LensPageViewport.fitPixelsPerPoint(
                                   pageSize: pageSize, box: LensPageViewport.plainBox))
        } else {
            next.closeUp = .fitWidth(pageSize: pageSize)
        }
        return next
    }

    /// A spoken zoom word from a close-up carries on at the close-up's zoom, as a viewport; from
    /// the rows, from the whole page.
    static func leavingCloseUp(_ shown: HUDPageViewState) -> HUDPageViewState {
        var next = shown
        if let closeUp = shown.closeUp {
            next.viewport = closeUp.viewport(box: shown.viewport.box)
        }
        next.closeUp = nil
        next.showsRows = false
        return next
    }

    /// Reading mode's **Page**: the whole page, the passage highlighted.
    static func pictureState(_ shown: HUDPageViewState) -> HUDPageViewState {
        var next = wholeState(shown)
        next.isFirstFrame = false
        return next.framed()
    }

    /// **Next diagram**: the drawing after the one highlighted, in reading order, round to the
    /// first; from a view not on a drawing, the one the request chose.
    static func nextDiagram(after shown: HUDPageViewState, in layout: LensPageLayout) -> Int? {
        guard !layout.drawings.isEmpty else { return nil }
        guard let current = shown.diagramIndex else { return layout.figureIndex ?? 0 }
        return (current + 1) % layout.drawings.count
    }

    /// `shown` on drawing `index`: it is highlighted now, and its close-up is up.
    static func state(_ shown: HUDPageViewState, onDrawing index: Int, layout: LensPageLayout) -> HUDPageViewState {
        var next = wholeState(shown)
        next.highlight = .figure(layout.drawings[index], pageSize: layout.pageSize)
        next.legibility = LensPageLayout.legibility(of: layout.drawings[index])
        next.diagramIndex = index
        return closeUpState(next)
    }

    private func draw(_ next: HUDPageViewState, event: LensPageAuditLine.Event?, issuedAgainst revision: UInt64,
                      band: Bool = false) {
        guard let page = currentPage, let request = page.request, let layout = layouts[page.layoutKey] else {
            if band { bandSendEnded() }
            return
        }
        generation += 1
        let drawing = generation
        armTimer(viewLifetime)
        track { [weak self] in
            guard let self else { return }
            guard let screen = await self.screen(for: next, page: page, layout: layout, request: request),
                  drawing == self.generation else {
                if band { self.bandSendEnded() }
                return
            }
            // Stale: a notification was enqueued after the press. The view stays as it was.
            guard self.router.updatePage(screen, issuedAgainst: revision, onSelect: self.selectionHandler) else {
                self.stats.update(self.backend()) { $0.stalePressesDropped += 1 }
                if band { self.bandSendEnded() }
                return
            }
            if band { self.bandPendingKey = screen.renderKey }
            self.shownState = next
            self.shownScreen = screen
            self.noteSent(screen)
            self.stats.update(self.backend()) { entry in
                switch event {
                case .zoomed?: entry.zooms += 1
                case .moved?: entry.moves += 1
                case .closeUp?:
                    if next.closeUp?.kind == .fitWidth { entry.fitWidths += 1 } else { entry.closeUps += 1 }
                case .rows?: entry.rowsViews += 1
                case .whole?: entry.backs += 1
                case .reading?: entry.readingViews += 1
                case .readPage?: entry.readingPages += 1
                default: break
                }
            }
            if let event { self.recordWhenDelivered(event, screen: screen, page: page, state: next) }
            self.renderAhead(next, page: page, layout: layout, request: request)
        }
    }

    /// The pictures a frame's one press goes to, drawn while the wearer looks, so the press only
    /// sends: from the whole page, its close-up (or fit width); from anywhere else, the whole page.
    private func renderAhead(_ state: HUDPageViewState, page: Page, layout: LensPageLayout,
                             request: LensPageRequest) {
        guard state.view != .reading else { return }
        var ahead = state.view == .whole ? Self.closeUpState(state) : Self.wholeState(state)
        ahead.isFirstFrame = false
        let plans = Self.renderPlans(ahead.framed(), layout: layout)
        track { [weak self] in
            guard let self else { return }
            for plan in plans {
                _ = await self.picture(for: plan, page: page, request: request)
            }
        }
    }

    /// The pictures a state draws from, in column order: the whole page at its box (the highlight
    /// outlined and kept bright, the rest dimmed); each close-up column; or for a spoken zoom, the
    /// crop's column of the page from its top down (`LensPageStrip`). None for text views.
    static func renderPlans(_ state: HUDPageViewState, layout: LensPageLayout) -> [LensPageRenderPlan] {
        switch state.view {
        case .reading, .rows:
            return []
        case .whole:
            let highlight = state.highlight.isNone ? nil : state.highlight.rects
            return [LensPageRenderPlan(layout: layout, viewport: state.viewport, highlight: highlight)]
        case .closeUp:
            guard let closeUp = state.closeUp else { return [] }
            let outlined = state.highlight.isNone ? nil : state.highlight.rects
            return closeUp.shownColumns.map { column in
                LensPageRenderPlan(pageSize: layout.pageSize, crop: column.rect, tone: layout.tone,
                                   passageMarks: layout.marks,
                                   pictureAreas: layout.pictureAreas + (state.highlight.reason == .figure ? outlined ?? [] : []),
                                   showsPosition: false, outputSize: closeUp.outputSize(of: column.rect))
            }
        case .zoomed:
            let strip = LensPageStrip(viewport: state.viewport)
            return [LensPageRenderPlan(pageSize: layout.pageSize, crop: strip.rect, tone: layout.tone,
                                       passageMarks: layout.marks, pictureAreas: layout.pictureAreas,
                                       showsPosition: false, outputSize: strip.outputSize)]
        }
    }

    /// Another staged page: as it opens (**Next page ›**, "next page"), or at fit width from its
    /// top (Plan MU §7: a band swipe at fit width).
    private func goToPage(_ target: Int, atFitWidth: Bool = false, issuedAgainst revision: UInt64,
                          band: Bool = false) {
        guard target != pageIndex, pages.indices.contains(target), let request = pages[target].request else {
            if band { bandSendEnded() }
            return
        }
        let page = pages[target]
        let forward = target > pageIndex
        generation += 1
        let drawing = generation
        armTimer(viewLifetime)
        prepare(page)
        track { [weak self] in
            guard let self else { return }
            guard let layout = await self.layout(for: page, request: request) else {
                if band { self.bandSendEnded() }
                return
            }
            var state = Self.openingState(layout, page: page, hasNextPage: target + 1 < self.pages.count,
                                          geometry: self.readingGeometry(), rows: self.rows(for: page))
            if atFitWidth {
                state.closeUp = .fitWidth(pageSize: state.viewport.pageSize)
                state.isFirstFrame = false
                state = state.framed()
            }
            guard let screen = await self.screen(for: state, page: page, layout: layout, request: request),
                  drawing == self.generation else {
                if band { self.bandSendEnded() }
                return
            }
            guard self.router.updatePage(screen, issuedAgainst: revision, onSelect: self.selectionHandler) else {
                self.stats.update(self.backend()) { $0.stalePressesDropped += 1 }
                if band { self.bandSendEnded() }
                return
            }
            if band { self.bandPendingKey = screen.renderKey }
            self.pageIndex = target
            self.shownState = state
            self.shownScreen = screen
            self.stats.update(self.backend()) { entry in
                if forward { entry.nextPages += 1 }
                if atFitWidth { entry.fitWidths += 1 }
                if state.isReading { entry.readingViews += 1 }
                entry.highlights[state.highlight.reason.rawValue, default: 0] += 1
            }
            self.noteSent(screen)
            self.recordWhenDelivered(.nextPage, screen: screen, page: page, state: state)
        }
    }

    // MARK: - Closing

    /// Close the view (or the cue) and return to what was under it.
    func close() {
        guard let held else { return }
        let page = currentPage
        let state = shownState
        let wasOnLens = viewReachedLens
        reset()
        router.closePage()
        if held == .view, let page, wasOnLens {
            PrivacyLog.device(.hud, .lensPageClosed, state: PrivacyToken(route.rawValue))
            record(.closed, page: page, state: state)
            let presses = viewPresses
            stats.update(backend()) { $0.pressesPerView.append(presses) }
        }
    }

    /// The pages may no longer be shown (the vault locked, access withdrawn, a manual removed):
    /// close the view and forget every page and picture drawn from them.
    func forget() {
        close()
        pages = []
        pageIndex = 0
        layouts = [:]
        rowsByPage = [:]
        layoutTasks = [:]
        renderTasks = [:]
        cache.removeAll()
        PageFigureCache.shared.removeAll()
    }

    /// Something else took the lens. Nothing is redrawn; whatever replaced the view owns it.
    private func lensTaken() {
        reset()
        router.pageLost()
    }

    private func reset() {
        held = nil
        shownState = nil
        shownScreen = nil
        bandSendEnded()
        awaitingDelivery = [:]
        viewReachedLens = false
        generation += 1
        timerGeneration += 1
    }

    private func armTimer(_ delay: TimeInterval) {
        timerGeneration += 1
        let armed = timerGeneration
        scheduleTimer(delay) { [weak self] in
            guard let self, armed == self.timerGeneration, self.held != nil else { return }
            self.close()
        }
    }

    // MARK: - Drawing

    /// Lay the page out (once) and draw ahead of the first press: the opening whole page (under the
    /// citation), the whole page on a later frame (what **Back** shows), and what the first pinch
    /// opens (the close-up, or fit width).
    private func prepare(_ page: Page) {
        guard let request = page.request else { return }
        track { [weak self] in
            guard let self, let layout = await self.layout(for: page, request: request) else { return }
            let first = Self.openingState(layout, page: page, hasNextPage: false, geometry: self.readingGeometry(),
                                          rows: self.rows(for: page))
            var whole = first
            whole.isFirstFrame = false
            var closeUp = Self.closeUpState(first)
            closeUp.isFirstFrame = false
            var plans: [LensPageRenderPlan] = []
            for state in [first, whole.framed(), closeUp.framed()] {
                for plan in Self.renderPlans(state, layout: layout) where !plans.contains(plan) {
                    plans.append(plan)
                }
            }
            for plan in plans {
                _ = await self.picture(for: plan, page: page, request: request)
            }
        }
    }

    private func layout(for page: Page, request: LensPageRequest) async -> LensPageLayout? {
        let key = page.layoutKey
        if let known = layouts[key] { return known }
        if let running = layoutTasks[key] { return await running.value }
        let laying = layoutPage
        let task = Task { @MainActor in await laying(request) }
        layoutTasks[key] = task
        let layout = await task.value
        layoutTasks[key] = nil
        if let layout { layouts[key] = layout }
        return layout
    }

    private func picture(for plan: LensPageRenderPlan, page: Page, request: LensPageRequest) async -> HUDPicture? {
        var drawn = request
        drawn.highlight = highlight()
        let request = drawn
        let key = LensPageRenderCache.key(identity: page.identity, plan: plan) + request.highlight.keySuffix
        if let cached = cache.picture(for: key) { return cached }
        if let running = renderTasks[key] { return await running.value }
        let rendering = renderPicture
        let started = clock()
        let backendToken = backend()
        let task = Task { @MainActor [weak self] () -> HUDPicture? in
            guard let image = await rendering(request, plan) else { return nil }
            let picture = HUDPicture(image: image, pixelSize: plan.outputSize, contentKey: key)
            guard let self else { return picture }
            let elapsed = self.clock() - started
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            self.stats.update(backendToken) { $0.renderMs.append(ms) }
            self.cache.store(picture, for: key)
            return picture
        }
        renderTasks[key] = task
        let picture = await task.value
        renderTasks[key] = nil
        return picture
    }

    private func screen(for state: HUDPageViewState, page: Page, layout: LensPageLayout,
                        request: LensPageRequest) async -> HUDScreen? {
        var screen = HUDPageScreenBuilder.screen(state, onAction: onAction)
        let plans = Self.renderPlans(state, layout: layout)
        switch state.view {
        case .reading, .rows:
            // Text: nothing to draw. The rows view opens on its first card, the highlighted row.
            return screen
        case .whole:
            // Plan MU §6: one picture of the whole page, a card the lens opens focused on, so one
            // pinch reads the highlight closely; its words under it.
            guard let plan = plans.first, let picture = await picture(for: plan, page: page, request: request) else { return nil }
            screen.flow = HUDPageScreenBuilder.wholePageFlow(state, picture: picture, onAction: onAction)
            screen.focusesFirstBlock = true
            return screen
        case .closeUp, .zoomed:
            // Each column of the page in slices under the row (Plan MG §4's strip): a close-up's
            // halves one after the other, the right half under its marker.
            let rightHalves = state.closeUp?.shownColumns.map { $0.isRightHalf } ?? [false]
            var columns: [(pictures: [HUDPicture], isRightHalf: Bool)] = []
            for (index, plan) in plans.enumerated() {
                guard let picture = await picture(for: plan, page: page, request: request) else { return nil }
                let slices = LensPageStrip.slices(of: plan.outputSize)
                let images = await Self.slice(picture.image, plannedSize: plan.outputSize,
                                              pieces: slices.map { (source: $0, size: $0.size) })
                guard images.count == slices.count else { return nil }
                let pictures = zip(slices, images).enumerated().map { offset, pair in
                    HUDPicture(image: pair.1, pixelSize: pair.0.size, contentKey: picture.contentKey + "#s\(offset)")
                }
                columns.append((pictures, index < rightHalves.count && rightHalves[index]))
            }
            screen.trailingFlow = HUDPageScreenBuilder.stripSlices(columns)
            return screen
        }
    }

    /// Cut a drawn picture into pieces, off the main actor.
    private static func slice(_ image: UIImage, plannedSize: CGSize,
                              pieces: [(source: CGRect, size: CGSize)]) async -> [UIImage] {
        await Task.detached(priority: .userInitiated) {
            LensPageSlicer.slice(image, plannedSize: plannedSize, pieces: pieces)
        }.value
    }

    private func renderFailed(_ page: Page) {
        PrivacyLog.device(.hud, .lensPageRefused, reason: PrivacyToken("render"))
        stats.update(backend()) { $0.refused += 1 }
        showCueLine(page.staged)
    }

    private func refuse(_ reason: String) {
        PrivacyLog.device(.hud, .lensPageRefused, reason: PrivacyToken(reason))
        stats.update(backend()) { $0.refused += 1 }
    }

    // MARK: - Records

    /// Plan MU §0: every picture a frame hands the lens, at the size it goes at (its drawn size
    /// shrunk by the picture factor), for the report.
    private func noteSent(_ screen: HUDScreen) {
        let factor = pictureFactor()
        let pictures = ([screen.picture].compactMap { $0 }) + screen.allBlocks.compactMap(\.picture)
        guard !pictures.isEmpty else { return }
        stats.update(backend()) { entry in
            entry.pictureFactor = Double(factor)
            entry.pictureSizes += pictures.map {
                LensPictureScale.sizeText($0.scalesForLens ? LensPictureScale.sentSize($0.pixelSize, factor: factor) : $0.pixelSize)
            }
        }
    }

    /// A picture reached the backend (`GlassesDisplayService.onPictureSent`).
    func notePictureSent(bytes: Int?, milliseconds: Int) {
        stats.update(backend()) { entry in
            if let bytes { entry.sentBytes.append(bytes) }
            entry.sendMs.append(milliseconds)
        }
    }

    private func recordWhenDelivered(_ event: LensPageAuditLine.Event, screen: HUDScreen, page: Page,
                                     state: HUDPageViewState?) {
        awaitingDelivery[screen.renderKey] = (event, page, state)
    }

    /// The display service's word on a frame. Taken: the audit line is written. Not taken: no
    /// line, and the support report counts it as refused (`lensPageRefused reason=send`).
    func frameDelivered(renderKey: String, delivered: Bool) {
        if let pending = bandPendingKey, pending == renderKey { bandSendEnded() }
        guard let waiting = awaitingDelivery.removeValue(forKey: renderKey) else { return }
        guard delivered else {
            refuse("send")
            return
        }
        if waiting.event != .cueShown { viewReachedLens = true }
        record(waiting.event, page: waiting.page, state: waiting.state)
    }

    /// The support report's **Page on the lens** lines.
    var reportLines: [String] { LensPageReport.lines(for: stats) }

    /// One audit line: the page reference, and for a picture its crop and scale. A reading-mode
    /// line says so and carries neither — and never the words.
    private func record(_ event: LensPageAuditLine.Event, page: Page, state: HUDPageViewState?) {
        let view: LensPageAuditLine.View? = state.map { state in
            switch state.view {
            case .reading: return .reading
            case .rows: return .rows
            case .whole, .closeUp, .zoomed: return .picture
            }
        }
        let shown = state.flatMap { Self.shownCrop($0) }
        audit?(LensPageAuditLine(event: event, documentTitle: page.staged.documentTitle, page: page.staged.page,
                                 figure: page.staged.figure, crop: shown?.crop ?? .zero,
                                 zoom: shown?.zoom ?? 0,
                                 route: event == .cueShown ? Route.automatic.rawValue : route.rawValue,
                                 backend: backend(), view: view,
                                 highlight: state.map { $0.highlight.reason.rawValue }))
    }

    /// What a picture view shows of the page, for the audit: the crop (a close-up's columns
    /// united) and the zoom relative to the whole page. Nil for a text view.
    static func shownCrop(_ state: HUDPageViewState) -> (crop: CGRect, zoom: Double)? {
        switch state.view {
        case .reading, .rows:
            return nil
        case .closeUp:
            guard let closeUp = state.closeUp, let first = closeUp.shownColumns.first?.rect else { return nil }
            let crop = closeUp.shownColumns.dropFirst().reduce(first) { $0.union($1.rect) }
            let whole = LensPageViewport.fitPixelsPerPoint(pageSize: closeUp.pageSize, box: state.viewport.box)
            return (crop, Double(closeUp.pixelsPerPoint / max(whole, 1e-9)))
        case .whole, .zoomed:
            return (state.viewport.cropRect, Double(state.viewport.scale))
        }
    }

    // MARK: - Tests

    private func track(_ body: @escaping @MainActor () async -> Void) {
        work.removeAll { $0.isCancelled }
        work.append(Task { @MainActor in await body() })
    }

    /// Test seam: wait for every open, press and pre-draw in flight to finish.
    func settle() async {
        while !work.isEmpty {
            let pending = work
            work = []
            for task in pending { await task.value }
        }
    }
}
