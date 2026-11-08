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
/// Where the lens can't show a picture (the Even G2, the web mirror alone, a page with no PDF
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
/// cache keyed by the page's identity and the crop; the opening view and the whole page are drawn
/// as soon as a page is staged, so the press that opens it doesn't wait for PDFKit.
///
/// **Drawings (P1b).** Each page's drawings are found from its ink (`PageFigureLocator`, through
/// `PageFigureAnalysis` and `PageFigureCache`, so a page is analysed once) and one is chosen by
/// what the turn said (`PageFigureAsk`, read from `requestWords` at `stage`; `PageFigureChoice`).
/// A turn that asked for a drawing opens on it ahead of any cited passage. **Next diagram ›** and
/// "next diagram" cycle the page's drawings in reading order; "the bottom one" goes to the one a
/// position names. Both are audited as moves.
///
/// **Reading mode (§1).** A page opened on a cited text passage (`LensPageLayout.reading`) opens on
/// the passage's own words as lens text, paged with the backend's geometry (`readingGeometry`), with
/// **Page** to see the picture (opened on the passage's mark) and, on that picture, **Read it** to
/// come back. While reading mode is up, "next" and "back" page the text and are taken even with
/// nowhere to go, so a task card under the view never takes a step it isn't showing.
///
/// **What is recorded.** Each view, zoom, move, reading page and close goes to the page audit trail
/// (`audit`) as the page reference and the crop (reading mode's lines carry none); the support
/// report counts views, reading views, zooms and moves and times renders and sends. Never the
/// page's text or pixels.
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

    /// Reading mode's geometry for the backend that shows the HUD (the web mirror is the Display's
    /// shape, as for the answer card).
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
    private var layoutTasks: [String: Task<LensPageLayout?, Never>] = [:]
    private var renderTasks: [String: Task<HUDPicture?, Never>] = [:]
    /// Bumped by every open and every press; a frame finished for an older one is not drawn.
    private var generation = 0
    private var timerGeneration = 0
    private var work: [Task<Void, Never>] = []
    private var heldWatch: AnyCancellable?

    init(display: GlassesDisplayService, router: HUDRouter, cache: LensPageRenderCache? = nil) {
        self.display = display
        self.router = router
        self.cache = cache ?? LensPageRenderCache()
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
        record(.cueShown, page: page, state: nil)
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
                                          geometry: self.readingGeometry())
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
            self.stats.update(self.backend()) { entry in
                entry.viewsOpened += 1
                if state.isReading { entry.readingViews += 1 }
            }
            PrivacyLog.device(.hud, .lensPageOpened, state: PrivacyToken(route.rawValue),
                              detail: PrivacyToken(self.backend()))
            self.record(.opened, page: page, state: state)
            self.armTimer(self.viewLifetime)
        }
    }

    // MARK: - Presses

    /// A band press acts on the buttons of the frame last drawn.
    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let item = self?.shownScreen?.items.first(where: { $0.id == id }) else { return }
            item.action()
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
        guard held != nil, let item = shownScreen?.items.first(where: { $0.id == id }) else { return false }
        item.action()
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
        var next = shown
        var event: LensPageAuditLine.Event?
        switch action {
        case .zoomIn:
            next.viewport.zoomIn(); event = .zoomed
        case .zoomOut:
            next.viewport.zoomOut(); event = .zoomed
        case .wholePage:
            next.viewport.showWholePage(); event = .zoomed
        case .backToPart:
            next.viewport.reset(); event = .zoomed
        case .move:
            next.isMoving = true
        case .doneMoving:
            next.isMoving = false
        case .step(let step):
            next.viewport.move(step); event = .moved
        case .nextPage:
            goToNextPage(issuedAgainst: revision)
            return
        case .nextDiagram:
            guard let layout = currentLayout, let target = Self.nextDiagram(after: shown, in: layout),
                  let viewport = layout.viewport(onDrawing: target) else { return }
            next = Self.state(shown, onDrawing: target, viewport: viewport, layout: layout)
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
            guard shown.isReading, let layout = currentLayout else { return }
            next = Self.pictureState(shown, layout: layout)
            event = .picture
        case .readIt:
            guard !shown.isReading, shown.canRead else { return }
            next.isReading = true
            next.isMoving = false
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
            guard shown.viewport.canZoomIn else { return false }
            handle(.zoomIn, issuedAgainst: revision)
        case .zoomOut:
            guard shown.viewport.canZoomOut else { return false }
            handle(.zoomOut, issuedAgainst: revision)
        case .wholePage:
            guard !shown.viewport.isWholePage else { return false }
            handle(.wholePage, issuedAgainst: revision)
        case .move(let step):
            guard shown.viewport.canMove(step) else { return false }
            handle(.step(step), issuedAgainst: revision)
        case .corner(let corner):
            var next = shown
            next.viewport.jump(to: corner)
            next.isFirstFrame = false
            next = next.framed()
            guard next != shown, display.acceptsHeldScreenPress(issuedAgainst: revision) else { return false }
            draw(next, event: .moved, issuedAgainst: revision)
        case .nextPage:
            guard pageIndex + 1 < pages.count else { return false }
            handle(.nextPage, issuedAgainst: revision)
        case .nextDiagram:
            guard shown.hasNextDiagram, !shown.isMoving else { return false }
            handle(.nextDiagram, issuedAgainst: revision)
        case .diagram(let position):
            // "The bottom one": the drawing that position names, when it names one other than
            // the one already shown at its opening.
            guard let layout = currentLayout,
                  let target = PageFigureChoice.index(for: position, in: layout.drawings),
                  let viewport = layout.viewport(onDrawing: target) else { return false }
            var next = Self.state(shown, onDrawing: target, viewport: viewport, layout: layout)
            next.isFirstFrame = false
            next = next.framed()
            guard next != shown, display.acceptsHeldScreenPress(issuedAgainst: revision) else { return false }
            draw(next, event: .moved, issuedAgainst: revision)
        case .back:
            if shown.isMoving {
                handle(.doneMoving, issuedAgainst: revision)
            } else if !shown.viewport.isAtOpening {
                handle(.backToPart, issuedAgainst: revision)
            } else if shown.canRead {
                handle(.readIt, issuedAgainst: revision)     // the picture of a passage: back to its words
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
        }
        return true
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
        case .showPage:
            handle(.showPicture, issuedAgainst: revision)
        case .wholePage:
            guard let layout = currentLayout, display.acceptsHeldScreenPress(issuedAgainst: revision) else { return false }
            var next = Self.pictureState(shown, layout: layout)
            next.viewport.showWholePage()
            next.isFirstFrame = false
            draw(next.framed(), event: .picture, issuedAgainst: revision)
        case .readIt:
            break   // already reading
        case .nextPage:
            guard pageIndex + 1 < pages.count else { return false }
            handle(.nextPage, issuedAgainst: revision)
        case .close:
            close()
        case .zoomIn, .zoomOut, .move, .corner, .nextDiagram, .diagram:
            return false
        }
        return true
    }

    /// The open page's layout, once laid out.
    private var currentLayout: LensPageLayout? { currentPage.flatMap { layouts[$0.layoutKey] } }

    /// The view's first state on a page: its opening viewport, and its drawings for **Next
    /// diagram ›**.
    static func openingState(_ layout: LensPageLayout, page: Page, hasNextPage: Bool,
                             geometry: TeleprompterPaginator.Geometry = .raybanDisplay) -> HUDPageViewState {
        var state = HUDPageViewState(viewport: layout.openingViewport, legibility: layout.legibility,
                                     citation: citation(for: page.staged), hasNextPage: hasNextPage,
                                     diagramCount: layout.drawings.count, diagramIndex: layout.openingDrawing)
        if let reading = layout.reading {
            state.readingPages = reading.pages(geometry: geometry)
            state.isReading = !state.readingPages.isEmpty
        }
        return state.framed()
    }

    /// Reading mode's **Page**: the picture, opened on the mark of the passage the reading page
    /// shows, fitted exactly. **Back to part** returns there.
    static func pictureState(_ shown: HUDPageViewState, layout: LensPageLayout) -> HUDPageViewState {
        var next = shown
        let number = layout.reading?.passageNumber(atPage: shown.readingIndex, of: shown.readingPages)
        next.viewport = layout.viewport(onPassage: number)
        next.legibility = LensLegibility(lineRects: layout.marks?.marks.first { $0.number == number }?.lineRects
                                         ?? layout.marks?.lineRects ?? [])
        next.isReading = false
        next.isMoving = false
        next.isFirstFrame = false
        return next.framed()
    }

    /// **Next diagram ›**: the drawing after the one shown, in reading order, round to the first;
    /// from a view not on a drawing, the one the request chose.
    static func nextDiagram(after shown: HUDPageViewState, in layout: LensPageLayout) -> Int? {
        guard !layout.drawings.isEmpty else { return nil }
        guard let current = shown.diagramIndex else { return layout.figureIndex ?? 0 }
        return (current + 1) % layout.drawings.count
    }

    /// `shown` moved to open on drawing `index`: that drawing is now what **Back to part** returns to.
    static func state(_ shown: HUDPageViewState, onDrawing index: Int, viewport: LensPageViewport,
                      layout: LensPageLayout) -> HUDPageViewState {
        var next = shown
        next.viewport = viewport
        next.legibility = LensPageLayout.legibility(of: layout.drawings[index])
        next.diagramIndex = index
        next.isMoving = false
        return next
    }

    private func draw(_ next: HUDPageViewState, event: LensPageAuditLine.Event?, issuedAgainst revision: UInt64) {
        guard let page = currentPage, let request = page.request, let layout = layouts[page.layoutKey] else { return }
        generation += 1
        let drawing = generation
        armTimer(viewLifetime)
        track { [weak self] in
            guard let self else { return }
            guard let screen = await self.screen(for: next, page: page, layout: layout, request: request),
                  drawing == self.generation else { return }
            // Stale: a notification was enqueued after the press. The view stays as it was.
            guard self.router.updatePage(screen, issuedAgainst: revision, onSelect: self.selectionHandler) else {
                self.stats.update(self.backend()) { $0.stalePressesDropped += 1 }
                return
            }
            self.shownState = next
            self.shownScreen = screen
            switch event {
            case .zoomed?: self.stats.update(self.backend()) { $0.zooms += 1 }
            case .moved?: self.stats.update(self.backend()) { $0.moves += 1 }
            default: break
            }
            switch event {
            case .reading?: self.stats.update(self.backend()) { $0.readingViews += 1 }
            case .readPage?: self.stats.update(self.backend()) { $0.readingPages += 1 }
            default: break
            }
            if let event { self.record(event, page: page, state: next) }
        }
    }

    private func goToNextPage(issuedAgainst revision: UInt64) {
        guard pageIndex + 1 < pages.count else { return }
        let target = pageIndex + 1
        let page = pages[target]
        guard let request = page.request else { return }
        generation += 1
        let drawing = generation
        armTimer(viewLifetime)
        prepare(page)
        track { [weak self] in
            guard let self else { return }
            guard let layout = await self.layout(for: page, request: request) else { return }
            let state = Self.openingState(layout, page: page, hasNextPage: target + 1 < self.pages.count,
                                          geometry: self.readingGeometry())
            guard let screen = await self.screen(for: state, page: page, layout: layout, request: request),
                  drawing == self.generation else { return }
            guard self.router.updatePage(screen, issuedAgainst: revision, onSelect: self.selectionHandler) else {
                self.stats.update(self.backend()) { $0.stalePressesDropped += 1 }
                return
            }
            self.pageIndex = target
            self.shownState = state
            self.shownScreen = screen
            self.stats.update(self.backend()) { entry in
                entry.nextPages += 1
                if state.isReading { entry.readingViews += 1 }
            }
            self.record(.nextPage, page: page, state: state)
        }
    }

    // MARK: - Closing

    /// Close the view (or the cue) and return to what was under it.
    func close() {
        guard let held else { return }
        let page = currentPage
        let state = shownState
        reset()
        router.closePage()
        if held == .view, let page {
            PrivacyLog.device(.hud, .lensPageClosed, state: PrivacyToken(route.rawValue))
            record(.closed, page: page, state: state)
        }
    }

    /// The pages may no longer be shown (the vault locked, access withdrawn, a manual removed):
    /// close the view and forget every page and picture drawn from them.
    func forget() {
        close()
        pages = []
        pageIndex = 0
        layouts = [:]
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

    /// Lay the page out (once) and draw the opening view and the whole page ahead of the press.
    private func prepare(_ page: Page) {
        guard let request = page.request else { return }
        track { [weak self] in
            guard let self, let layout = await self.layout(for: page, request: request) else { return }
            // The pictures the first presses want: the opening view (or, opening on the words, the
            // picture **Page** shows) and the whole page, each in the box its frame leaves.
            let opening = Self.openingState(layout, page: page, hasNextPage: false, geometry: self.readingGeometry())
            var first = opening.isReading ? Self.pictureState(opening, layout: layout) : opening
            var whole = first
            whole.isFirstFrame = false
            whole.viewport.showWholePage()
            whole = whole.framed()
            first = first.framed()
            for state in [first, whole] {
                _ = await self.picture(for: LensPageRenderPlan(layout: layout, viewport: state.viewport),
                                       page: page, request: request)
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
        let key = LensPageRenderCache.key(identity: page.identity, plan: plan)
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
        // Reading mode is text: nothing to draw.
        if state.isReading { return HUDPageScreenBuilder.screen(state, onAction: onAction) }
        guard let picture = await picture(for: LensPageRenderPlan(layout: layout, viewport: state.viewport),
                                          page: page, request: request) else { return nil }
        var screen = HUDPageScreenBuilder.screen(state, onAction: onAction)
        screen.picture = picture
        return screen
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

    /// A picture reached the backend (`GlassesDisplayService.onPictureSent`).
    func notePictureSent(bytes: Int?, milliseconds: Int) {
        stats.update(backend()) { entry in
            if let bytes { entry.sentBytes.append(bytes) }
            entry.sendMs.append(milliseconds)
        }
    }

    /// The support report's **Page on the lens** lines.
    var reportLines: [String] { LensPageReport.lines(for: stats) }

    /// One audit line: the page reference, and for a picture its crop and scale. A reading-mode
    /// line says so and carries neither — and never the words.
    private func record(_ event: LensPageAuditLine.Event, page: Page, state: HUDPageViewState?) {
        let picture = state.flatMap { $0.isReading ? nil : $0.viewport }
        audit?(LensPageAuditLine(event: event, documentTitle: page.staged.documentTitle, page: page.staged.page,
                                 figure: page.staged.figure, crop: picture?.cropRect ?? .zero,
                                 zoom: picture.map { Double($0.scale) } ?? 0,
                                 route: event == .cueShown ? Route.automatic.rawValue : route.rawValue,
                                 backend: backend(),
                                 view: state.map { $0.isReading ? .reading : .picture }))
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
