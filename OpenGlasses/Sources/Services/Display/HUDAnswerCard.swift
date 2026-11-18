import Foundation

/// The answer card on the glasses (Plan KP P1): one turn's answer, a page at a time, with the
/// actions under it.
///
/// **What becomes a card.** Only the assistant's answers: lines spoken as `SpeechSource.reply` or
/// `.phoneAnswer` (`takesAnswers(from:)`), which `TextToSpeechService` hands to `absorb` instead
/// of mirroring them a sentence at a time. Alerts, confirmations, notices, captions, agent
/// narration, translations and fingerspelling keep today's `showText` path. Within a turn the
/// Direct-mode loop opened (`beginTurn` / `finishTurn` / `endTurn`), streamed sentences collect into
/// one card; a whole answer spoken outside a turn (a photo answer, a tier-0 answer, an agent's
/// result) is a card of its own. A *streamed* line outside a turn (the gateway's partial results)
/// keeps today's sentence-at-a-time line, because nothing says where that answer ends.
///
/// **When it shows.** Page 1 once it is settled (`HUDAnswerPager.settledPageCount > 0`) or the reply
/// is final, whichever comes first. Later pages fill in behind it and only the footer's count
/// grows; the wearer can turn only to settled pages, so the page being read never changes under
/// them. A new answer replaces the card.
///
/// **Coexistence.** The card is an interactive screen, so ambient producers (captions) are
/// suppressed while it is up and resume when it clears. Over a task card, a menu or a choice
/// list an answer is not made a card: it flashes for five seconds, as before
/// (`GlassesDisplayService.acceptsAnswerCard`). Notifications flash over the card and it comes
/// back. Guidance and hazard lines are never paged, and take the HUD from a card.
///
/// **Follow-ups (P2).** The open turn's suggested follow-ups (`offerFollowUps`, from the reply's
/// tail, which never reaches anything else) go on its card: two on the last page, a third on the
/// Actions screen (`HUDAnswerCardBuilder`); with a page to show, **Page** takes the second's place
/// on the last page and the second moves to the Actions screen. Only a reply that came back whole
/// carries them: a turn cut short (an error, a barge-in) shows none, and a new answer's card starts
/// with none.
///
/// **The question (Plan KV §7).** A turn opened with the technician's words (`beginTurn(question:)`)
/// shows what the app heard over its first page, "You: …", in the meta style and cut to one line;
/// the pager gives that page one line fewer (`firstPageReservedLines`). A card for an answer outside
/// such a turn (a proactive alert, a watcher, a photo answer) has none.
///
/// **Page size (Plan MG §1).** On the Meta Display and the web mirror the pages take the lens's
/// measured budget (`LensPageFrame.answerGeometry`, 10 × 32): 9 lines of text and the footer, 8
/// under the question. Even keeps its own 3 × 40.
///
/// **Lifetime.** Until Close, a new answer, or `idleLifetime` (60 s) with no press and no change to
/// the answer — so a long answer still being spoken never clears under the wearer. In memory only.
///
/// **Stale presses.** Every press — band, voice or temple tap — is issued against the revision at
/// which the card was last drawn (`GlassesDisplayService.heldScreenRevision`). A notification
/// enqueued over the card since makes it stale, so the press is dropped rather than drawn over the
/// notification (§2).
///
/// **While another app has the Display (§8, P1b).** Nothing reaches the lens, but the card is still
/// held: a new answer replaces it and its lifetime runs as usual. When the Display is ours again the
/// card shows if it is still inside `idleLifetime` counted from when the answer was made (its last
/// change), and is dropped otherwise (`displayReturned`). The paging words are left to the model
/// meanwhile ("next" may mean the next track), and "repeat", "tell me more", "save that" and "send
/// that" reach everything the card offers as ordinary requests.
///
/// **Live modes (Plan LC §5).** Gemini Live, OpenAI Realtime, Qwen and Doubao speak with the
/// model's own voice, so nothing they say reaches `absorb`. `LiveAnswerCardFeed` collects each
/// model turn's transcript and, at the turn's end, hands it to `presentLiveAnswer` — one card per
/// turn, never word by word, with what the wearer said as its question line and no follow-ups (a
/// live model is never asked for the tail). Such an answer reopens a lens the wearer dismissed only
/// when the wearer spoke (or pressed) that turn (`GlassesDisplayService.presentAnswerCard(wearerLed:)`).
///
/// **The picture behind a vision answer (Plan LC §5).** A turn that sent the model a camera frame
/// stages the frame's thumbnail (`expectPicture` / `stagePicture`); the next new card takes it onto
/// its first page (`HUDAnswerCardBuilder.page(picture:)`) when the backend draws pictures, and that
/// page gives the picture's lines up from the card's first layout (`firstPageReservedLines`). A staged
/// picture belongs to the next answer only: the turn's end, a whole answer spoken outside a turn,
/// or `stagedPictureLifetime` drops one no card took.
///
/// **The reading view (Plan MG §2).** On the Meta Display, unless Display & HUD › Answers on the
/// lens is **Pages** (`usesReadingView`), the answer is one view the band steps through and the
/// lens scrolls (`HUDReadingViewBuilder`): its rows, its buttons, and this conversation's earlier
/// answers under them (`LensConversationLog`, in memory only). It is sent at settle points while
/// the answer streams and once it is complete (`ReadingRedrawPolicy`), then only on a press, a new
/// answer or the lens coming back, and it lasts `readingIdleLifetime` (3 minutes) without a press
/// (decision 4). A press on a row says the answer again from there (decision 3); a press on an
/// earlier answer opens it at the top, with **‹ Latest**. The paged card and its Actions screen are
/// unchanged, and Even keeps them; "previous answer" by voice opens an earlier answer as pages there.
@MainActor
final class HUDAnswerCard {
    /// Plan KP §3: a card with no press for this long clears.
    static let defaultIdleLifetime: TimeInterval = 60
    /// Plan LC §5: a staged thumbnail no card has taken after this long belongs to no answer.
    static let stagedPictureLifetime: TimeInterval = 90
    /// Plan MG decision 4: the reading view with no press for this long clears. The app can't see
    /// the wearer scroll, so KP's 60 s would clear a view still being read.
    static let defaultReadingIdleLifetime: TimeInterval = 180

    private let display: GlassesDisplayService

    /// Test seam: the idle lifetime.
    var idleLifetime: TimeInterval = HUDAnswerCard.defaultIdleLifetime
    /// Test seam: the reading view's idle lifetime.
    var readingIdleLifetime: TimeInterval = HUDAnswerCard.defaultReadingIdleLifetime
    /// Plan MG §2: whether a new answer is shown as the reading view. AppState wires
    /// `activeUsesReadingView` (the Meta Display, unless Display & HUD says Pages); nothing else
    /// gets the reading view, so a card left unwired keeps its pages.
    var usesReadingView: () -> Bool = { false }
    /// Test seam: run `fire` after `delay`. Production sleeps on the main actor; a test can
    /// capture the timers and fire them in any order, so the lifetime rule is checked without
    /// racing the clock.
    var scheduleIdleTimer: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }
    /// The page shape, from the active backend.
    var geometry: () -> TeleprompterPaginator.Geometry = HUDAnswerCard.activeGeometry
    /// Test seam: the clock that says when the answer was made.
    var now: () -> Date = Date.init

    // MARK: Wiring (AppState)

    /// Submit text as the wearer's next turn, through the same entry point a typed request uses.
    var submitTurn: ((String) -> Void)?
    /// Say the answer again, in the voice and route the app uses, without mirroring it.
    var speakAgain: ((String) -> Void)?
    /// Run `save_note` with a title and the answer through the tool router (and so the
    /// authorization policy). True when it saved.
    var saveNote: ((_ title: String, _ content: String) async -> Bool)?
    /// Plan KV §4: whether the page the turn staged can open on the lens now (a backend that draws
    /// pictures, the HUD on), and opening it.
    var pageCanOpen: () -> Bool = { false }
    var openPage: (() -> Void)?

    // MARK: State

    /// The turn collecting now, if one is open.
    private var turn: HUDAnswerTurn?
    /// The open turn's card has been shown (it replaced whatever card was up).
    private var turnHasCard = false
    /// The open turn's suggested follow-ups, from its reply's tail (Plan KP P2).
    private var turnFollowUps: [String] = []
    /// The open turn staged a manual page (Plan KV §4).
    private var turnStagedPage = false
    /// Plan KZ: how many web sources the open turn's reply has, and whether it has Google's
    /// Search Suggestions; both are on the phone, and the card says so in one line.
    private var turnWebSourceCount = 0
    private var turnHasSearchSuggestions = false
    /// The card's turn staged a page: its Actions offer **Page** while the lens can show it.
    private(set) var hasPage = false
    /// Plan LC §5: whether the open turn's answer is the wearer's (they spoke or pressed). Only a
    /// live turn can say no; every Direct-mode answer is.
    private var turnWearerLed = true
    /// Plan LC §5: the thumbnail waiting for the next new card, when it was staged, and the ticket
    /// that names the frame it was staged for (`expectPicture`).
    private var stagedPicture: (picture: HUDPicture, at: Date)?
    private var pictureTicket = 0
    /// The card's first-page picture: the frame its vision answer analysed.
    private(set) var picture: HUDPicture?

    /// The card's answer, pages and position.
    private(set) var answer = ""
    private(set) var pages: [HUDAnswerPage] = []
    private(set) var pageIndex = 0
    private(set) var isOnActions = false
    /// The card's suggested follow-ups (Plan KP P2): its turn's, and none for any other card.
    private(set) var followUps: [String] = []
    /// What the app heard the card's turn ask (Plan KV §7); nil for a turn the app started.
    private(set) var question: String?
    /// The answer is final: every page may be read.
    private var answerIsComplete = false
    /// The screen last handed to the display, for routing a band press back by id.
    private var shownScreen: HUDScreen?
    private var idleGeneration = 0
    /// Counts cards shown, so the web mirror can tell a new answer from more of the same one.
    private var cardSerial = 0
    /// When the card's answer last changed: the start of the lifetime a card held while another
    /// app had the Display is judged by (§8 rule 4).
    private(set) var answerMadeAt: Date?

    // MARK: The reading view (Plan MG §2)

    /// What the lens remembers of this conversation: its last finished answers.
    private(set) var log = LensConversationLog()
    /// The card is shown as the reading view (decided when it went up, and again when it is
    /// brought back).
    private(set) var isReadingView = false
    /// The card's turn, as the log knows it: the same through a reopen.
    private(set) var turnID = 0
    /// An earlier turn opened at the top of the reading view; nil for the newest.
    private(set) var openedTurnID: Int?
    /// What the card lays out: the answer, and once final the web-sources line under it.
    private var shownText = ""
    private var redraw = ReadingRedrawPolicy()
    private var linkGeneration = 0
    /// Counts and sizes for the support report (never text).
    private(set) var readingStats = LensReadingStats()

    init(display: GlassesDisplayService) {
        self.display = display
        display.onLensReturnedToAnswerCard = { [weak self] in self?.displayReturned() }
        display.onAnswerCardReturnedFromPage = { [weak self] in self?.returnedFromPage() }
        display.onGlassesLinkChanged = { [weak self] connected in self?.glassesLinkChanged(connected) }
        display.onHUDTurnedOff = { [weak self] in self?.hudTurnedOff() }
    }

    /// The card is on the glasses (or held under a notification).
    var isShowing: Bool { display.showsAnswerCard }
    /// The card is on the glasses, or held under a notification or the page view (Plan KV).
    var isHeld: Bool { isShowing || display.holdsAnswerCardUnderPage }
    /// The screen last handed to the display, buttons and all: what a band press acts on. Read
    /// by tests, which check a card's buttons without waiting on the render queue.
    var screenOnLens: HUDScreen? { shownScreen }
    var isTurnOpen: Bool { turn != nil }

    /// Pages the wearer may turn to: all of a final answer, the settled ones of a streaming one.
    var visiblePageCount: Int {
        answerIsComplete ? pages.count : HUDAnswerPager.settledPageCount(pages)
    }

    /// The speech sources that are answers.
    static func takesAnswers(from source: SpeechSource) -> Bool {
        source == .reply || source == .phoneAnswer
    }

    /// The answer card's pager geometry for the backend that shows the HUD: the lens's measured
    /// budget on the Meta Display (`LensPageFrame.answerGeometry`, 10 × 32), Even's own 3 × 40. The
    /// web mirror is the Meta Display's 600 × 600 shape, so mirror-only uses the Meta geometry.
    static func activeGeometry() -> TeleprompterPaginator.Geometry {
        #if !AVENKIN_PHONE_ONLY
        return Config.displayBackend == .evenG2 ? .evenG2 : LensPageFrame.answerGeometry
        #else
        return LensPageFrame.answerGeometry
        #endif
    }

    /// Plan MG §2: the reading view on the Meta Display, unless Display & HUD › Answers on the lens
    /// is **Pages**. Even and the phone-only build (the web mirror) keep pages.
    static func activeUsesReadingView() -> Bool {
        #if !AVENKIN_PHONE_ONLY
        return Config.displayBackend == .metaRayBan && Config.lensAnswerStyle == .scroll
        #else
        return false
        #endif
    }

    /// The teleprompter's geometry for the backend that shows the HUD: 4 × 32 on the Meta Display
    /// (and the web mirror), Even's 3 × 40. What the screens that are not the answer card lay out
    /// on — the prepared-card stack and glance, and the Thinking card's question line — until their
    /// own budgets are checked against `LensPageFrame`.
    static func activeTeleprompterGeometry() -> TeleprompterPaginator.Geometry {
        #if !AVENKIN_PHONE_ONLY
        return Config.displayBackend == .evenG2 ? .evenG2 : .raybanDisplay
        #else
        return .raybanDisplay
        #endif
    }

    /// How many lines the first page gives up (`HUDAnswerPager.pages(firstPageReservedLines:)`):
    /// one for the question line, and the lines the card's picture takes from the lens's budget
    /// (`HUDAnswerThumbnail.firstPageLines(of:)`) beyond the room `geometry` already leaves it — the
    /// teleprompter's 4 lines left the strip room of its own, the lens's 10 do not. Nothing for a
    /// picture so tall it would leave no line of text beside the question and the footer: `fits`
    /// leaves that picture off, so the page keeps its text.
    static func firstPageReservedLines(hasQuestion: Bool, picture: HUDPicture?,
                                       geometry: TeleprompterPaginator.Geometry) -> Int {
        let questionLines = hasQuestion ? 1 : 0
        guard let picture else { return questionLines }
        let spare = max(0, LensPageFrame.answerGeometry.maxLines - geometry.maxLines)
        let pictureLines = max(0, HUDAnswerThumbnail.firstPageLines(of: picture) - spare)
        // The footer and at least one line of text stay on the page.
        guard questionLines + pictureLines + 2 <= geometry.maxLines else { return questionLines }
        return questionLines + pictureLines
    }

    /// What More sends as the next turn.
    static var moreRequest: String { String(localized: "Tell me more about that") }
    /// What Send sends as the next turn. The assistant asks who to send it to, and `send_via`'s
    /// bound approval holds the send until the wearer confirms: the press itself sends nothing.
    static var sendRequest: String { String(localized: "Send your last answer to someone") }

    /// Save's note title: the answer's first line, cut to a heading's length.
    static func noteTitle(for answer: String) -> String {
        let first = answer.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return HUDTextShaper.condense(first, max: HUDTextShaper.maxTitleLength)
    }

    // MARK: - The answer turn

    /// A Direct-mode reply is starting. Nothing changes on the HUD until its card can show.
    /// `question` is what the app heard the technician ask (Plan KV §7): the card shows it over
    /// the first page. Nil for a turn the app started.
    func beginTurn(question: String? = nil) {
        turn = HUDAnswerTurn(question: question)
        turnHasCard = false
        turnFollowUps = []
        turnStagedPage = false
        turnWearerLed = true
        turnWebSourceCount = 0
        turnHasSearchSuggestions = false
    }

    // MARK: - Live modes (Plan LC §5)

    /// A live-mode model turn ended with `text` as its transcript: show it as a card of its own,
    /// whole. `question` is what the wearer said that turn (nil when they said nothing);
    /// `wearerLed` is whether they spoke or pressed that turn, which alone lets the card reopen a
    /// lens they dismissed. Over a task card, a menu, a page view's frame or an approval card
    /// (`GlassesDisplayService.acceptsAnswerCard` false) nothing shows: a live answer is heard,
    /// and nothing it would flash is worth covering the wearer's work for.
    func presentLiveAnswer(_ text: String, question: String?, wearerLed: Bool) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, display.acceptsAnswerCard else { return }
        beginTurn(question: question)
        turnWearerLed = wearerLed
        turn?.finish(reply: reply)
        update()
        endTurn()
    }

    // MARK: - The picture behind a vision answer (Plan LC §5)

    /// A frame is on its way to the model: any thumbnail staged for an earlier one is dropped, and
    /// the returned ticket names this one for `stagePicture`.
    func expectPicture() -> Int {
        pictureTicket += 1
        stagedPicture = nil
        return pictureTicket
    }

    /// The thumbnail of the frame `ticket` named, ready. The next new card takes it. Ignored when a
    /// later frame or the end of the turn has moved the ticket on (the thumbnail decodes off the
    /// main actor and can land late), and for a backend that draws no pictures.
    func stagePicture(_ picture: HUDPicture?, ticket: Int) {
        guard ticket == pictureTicket, let picture, display.drawsPictures else { return }
        stagedPicture = (picture, now())
    }

    /// No answer will take the staged thumbnail (its turn ended, or failed).
    func dropStagedPicture() {
        pictureTicket += 1
        stagedPicture = nil
    }

    /// The staged thumbnail while it is fresh and the backend draws pictures: the picture the next
    /// new card would take. Read once per layout, so the lines the first page reserves for it and
    /// the picture the card takes are the same.
    private func freshStagedPicture() -> HUDPicture? {
        guard let staged = stagedPicture, display.drawsPictures,
              now().timeIntervalSince(staged.at) < Self.stagedPictureLifetime else { return nil }
        return staged.picture
    }

    /// Plan KV §4: the open turn staged a manual page. Its card's Actions offer **Page**.
    func notePageStaged() {
        guard turn != nil else { return }
        turnStagedPage = true
        guard turnHasCard, !hasPage else { return }
        hasPage = true
        // Page goes on the last page (and the Actions screen changes with it), or leads the
        // reading view's buttons.
        guard isShowing, isOnActions || isOnLastPage || (isReadingView && openedTurnID == nil) else { return }
        recordInLog()
        let screen = currentScreen()
        if display.presentAnswerCard(screen, onSelect: selectionHandler) { shownScreen = screen }
    }

    /// Plan KP P2: the open turn's reply came back with these follow-ups (its tail, already taken
    /// off the reply). They show when the reply is final on the card (`finishTurn`, or the whole
    /// answer reaching `absorb`); a card already showing the final answer is redrawn with them.
    /// Ignored with no turn open.
    func offerFollowUps(_ questions: [String]) {
        guard turn != nil else { return }
        turnFollowUps = Array(questions.prefix(FollowUpTail.maxFollowUps))
        guard let open = turn, open.isFinished else { return }
        update()
    }

    /// The open turn's reply is final (a streamed reply's text is known before it has all been
    /// said): the whole answer shows now.
    func finishTurn(reply: String) {
        guard var open = turn, !open.isFinished, display.acceptsAnswerCard else { return }
        open.finish(reply: reply)
        turn = open
        update()
    }

    /// The turn is over. A turn that ended before its reply was final (an error, a barge-in) shows
    /// what was said. The lifetime counts from here: the answer has finished being spoken.
    func endTurn() {
        guard var open = turn else { return }
        if !open.isFinished, !open.isEmpty, display.acceptsAnswerCard {
            // Cut short: what was said shows, with no follow-ups for an answer never finished.
            turnFollowUps = []
            open.seal()
            turn = open
            update()
        }
        if turnHasCard, isShowing { armIdleTimer() }
        turn = nil
        // Plan LC §5: a thumbnail this turn's card did not take belongs to no later answer.
        dropStagedPicture()
    }

    /// Plan KZ: the open turn's reply rests on `count` web pages, and maybe Google's Search
    /// Suggestions. The final card ends with one line saying where to find them — no addresses on
    /// the lens. The Display draws text, not Google's snippet, so the suggestions are pointed to on
    /// the phone rather than re-styled here.
    func offerWebSources(count: Int, hasSearchSuggestions: Bool) {
        guard turn != nil else { return }
        turnWebSourceCount = max(0, count)
        turnHasSearchSuggestions = hasSearchSuggestions
        guard let open = turn, open.isFinished else { return }
        update()
    }

    /// The card's closing line for a reply's web sources and suggestions, or nil.
    static func webSourcesLine(count: Int, hasSearchSuggestions: Bool) -> String? {
        switch (count, hasSearchSuggestions) {
        case (0, false): return nil
        case (0, true): return String(localized: "Google search suggestions on your phone")
        case (1, false): return String(localized: "1 web source on your phone")
        case (1, true): return String(localized: "1 web source and Google search suggestions on your phone")
        case (let n, false): return String(localized: "\(n) web sources on your phone")
        case (let n, true): return String(localized: "\(n) web sources and Google search suggestions on your phone")
        }
    }

    /// What the pager lays out: the answer, and once it is final, the sources line under it.
    private func cardText(for turn: HUDAnswerTurn) -> String {
        guard turn.isFinished,
              let line = Self.webSourcesLine(count: turnWebSourceCount,
                                             hasSearchSuggestions: turnHasSearchSuggestions) else { return turn.text }
        return turn.text + "\n\n" + line
    }

    /// A line the speech service is about to say as an answer. True when the card took it (shown,
    /// collected, or already on the card); false sends it down today's `showText` path.
    @discardableResult
    func absorb(_ text: String, streamed: Bool) -> Bool {
        guard display.acceptsAnswerCard else { return false }
        if var open = turn {
            if open.isFinished { return true }      // already on the card
            if streamed { open.append(text) } else { open.finish(reply: text) }
            turn = open
            update()
            return true
        }
        guard !streamed else { return false }
        beginTurn()
        turn?.finish(reply: text)
        update()
        turn = nil
        dropStagedPicture()      // Plan LC §5: the whole answer was this line
        return true
    }

    private func update() {
        guard let turn, !turn.isEmpty else { return }
        let shape = geometry()
        let questionLine = HUDAnswerCardBuilder.questionLine(for: turn.question, maxChars: shape.maxChars)
        // The first page's picture: the staged one this layout would show the card with, then the
        // one the card took. Its lines are reserved from the first layout on, so the reservation is
        // the same for the card's whole life and settled pages keep their lines as the answer grows.
        let firstPagePicture = turnHasCard ? picture : freshStagedPicture()
        let reserved = Self.firstPageReservedLines(hasQuestion: questionLine != nil, picture: firstPagePicture,
                                                   geometry: shape)
        let text = cardText(for: turn)
        let laid = HUDAnswerPager.pages(for: text, geometry: shape,
                                        firstPageReservedLines: reserved)
        guard !laid.isEmpty else { return }
        let progress = Self.readingProgress(text, geometry: shape, isComplete: turn.isFinished)
        if !turnHasCard {
            let reading = usesReadingView()
            if reading {
                guard turn.isFinished || progress.settledRows > 0 else { return }
            } else {
                guard turn.isFinished || HUDAnswerPager.settledPageCount(laid) > 0 else { return }
            }
            question = questionLine
            answer = turn.text
            answerMadeAt = now()
            pages = laid
            answerIsComplete = turn.isFinished
            pageIndex = 0
            isOnActions = false
            followUps = turn.isFinished ? turnFollowUps : []
            hasPage = turnStagedPage
            picture = firstPagePicture
            stagedPicture = nil      // taken once
            closedCard = nil         // a new answer is the one to bring back now
            forgetOnClose = false
            cardSerial += 1
            turnID = cardSerial
            shownText = text
            isReadingView = reading
            openedTurnID = nil
            redraw.reset()
            if reading { _ = redraw.textChanged(progress) }
            let screen = currentScreen()
            guard display.presentAnswerCard(screen, wearerLed: turnWearerLed,
                                            onSelect: selectionHandler) else { return }
            shownScreen = screen
            turnHasCard = true
            noteDrawn(screen)
            recordInLog()
            armIdleTimer()
        } else {
            if answer != turn.text { answerMadeAt = now() }
            answer = turn.text
            shownText = text
            pages = laid
            answerIsComplete = turn.isFinished
            followUps = turn.isFinished ? turnFollowUps : []
            hasPage = hasPage || turnStagedPage
            recordInLog()
            // The wearer closed it: more of the answer doesn't bring it back. Under the page view
            // it is still held, and kept current for when the view closes (Plan KV).
            guard isHeld else { return }
            let screen = currentScreen()
            if isReadingView, !isOnActions {
                // Plan MG §2: a redraw resets the wearer's place, so the text redraws the view only
                // at settle points and once complete; an earlier turn open at the top is not redrawn
                // for the newest at all. After the final draw only the answer's own buttons (its
                // follow-ups, a page it staged) redraw it.
                guard openedTurnID == nil else { return }
                let textDraws = redraw.textChanged(progress)
                let buttonsChanged = redraw.drewComplete
                    && shownScreen.map { $0.items.map(\.id) != screen.items.map(\.id) } ?? true
                guard textDraws || buttonsChanged else { return }
            }
            if display.presentAnswerCard(screen, onSelect: selectionHandler) {
                shownScreen = screen
                noteDrawn(screen)
                armIdleTimer()      // more of the answer is not idle
            }
        }
    }

    /// How far `text` has settled into reading-view rows and paragraphs.
    static func readingProgress(_ text: String, geometry: TeleprompterPaginator.Geometry,
                                isComplete: Bool) -> ReadingRedrawPolicy.Progress {
        let chars = HUDReadingRows.maxChars(for: geometry)
        return ReadingRedrawPolicy.Progress(
            settledRows: HUDReadingRows.settledRowCount(for: text, maxChars: chars, isComplete: isComplete),
            settledParagraphs: HUDReadingRows.settledParagraphCount(for: text, isComplete: isComplete),
            isComplete: isComplete)
    }

    /// The card's turn, once its answer is final, goes into what the lens remembers — unless the
    /// private conversation it belonged to has ended (`forgetOnClose`).
    private func recordInLog() {
        guard answerIsComplete, !answer.isEmpty, !forgetOnClose, turnID > 0 else { return }
        log.record(LensConversationTurn(id: turnID, question: question, answer: answer, followUps: followUps,
                                        stagedPage: hasPage, madeAt: answerMadeAt ?? now()))
    }

    /// A reading view went to the lens: its size, for the report.
    private func noteDrawn(_ screen: HUDScreen) {
        guard isReadingView, !isOnActions else { return }
        readingStats.noteView(rows: screen.allBlocks.count, characters: HUDReadingViewBuilder.characters(in: screen))
    }

    // MARK: - Presses

    /// A press from voice or a temple tap, issued against the card as last drawn: while a
    /// notification is over the card, it is stale and dropped (§2).
    func press(_ action: HUDAnswerAction) {
        handle(action, issuedAgainst: display.heldScreenRevision)
    }

    /// Whether a spoken paging word would move the card. "Next" on the last readable page or
    /// "back" on the first has nothing to do, so `HUDRouter` leaves the utterance to the model
    /// (it may mean the next track) instead of swallowing it.
    func canTurn(_ action: HUDAnswerAction) -> Bool {
        // Not while another app has the Display: the card can't be seen, so the word goes on.
        guard isShowing, display.displayAvailability != .inUse else { return false }
        switch action {
        case .next: return !isReadingView && !isOnActions && pageIndex + 1 < visiblePageCount
        case .back:
            // Plan MG §2: the reading view has no pages; "back" leaves Actions or an earlier answer.
            if isReadingView { return isOnActions || openedTurnID != nil }
            return isOnActions || pageIndex > 0
        default: return true
        }
    }

    /// A press issued against `revision`. Dropped (and logged) when another frame has been
    /// enqueued since, through `PageTurnGate`.
    func handle(_ action: HUDAnswerAction, issuedAgainst revision: UInt64) {
        guard display.acceptsCardPress(issuedAgainst: revision) else { return }
        armIdleTimer()
        switch action {
        case .next:
            guard !isReadingView, !isOnActions, pageIndex + 1 < visiblePageCount else { return }
            show(page: pageIndex + 1, actions: false, revision)
        case .back:
            if isOnActions {
                show(page: pageIndex, actions: false, revision)
            } else if isReadingView {
                if openedTurnID != nil { showReading(opening: nil, revision) }
            } else if pageIndex > 0 {
                show(page: pageIndex - 1, actions: false, revision)
            }
        case .answer:
            guard isOnActions else { return }
            show(page: pageIndex, actions: false, revision)
        case .actions:
            guard !isOnActions else { return }
            show(page: pageIndex, actions: true, revision)
        case .more:
            submitTurn?(Self.moreRequest)
        case .repeatAnswer:
            speakAgain?(answer)
        case .save:
            save()
        case .send:
            submitTurn?(Self.sendRequest)
        case .close:
            close()
        case .followUp(_, let text):
            submitTurn?(text)
        case .page:
            guard hasPage, pageCanOpen() else { return }
            openPage?()
        case .repeatFrom(_, let text):
            guard !text.isEmpty else { return }
            readingStats.rowPresses += 1
            speakAgain?(text)
        case .openTurn(let id):
            guard isReadingView, !isOnActions, log.turn(id: id) != nil, id != turnID else { return }
            showReading(opening: id, revision)
        case .latest:
            guard isReadingView, openedTurnID != nil else { return }
            showReading(opening: nil, revision)
        }
    }

    /// The reading view with `opening` at its top (nil: the newest), as a press: drawn only when
    /// nothing has been enqueued since, otherwise dropped and the view left as it was.
    private func showReading(opening id: Int?, _ revision: UInt64) {
        let previous = openedTurnID
        openedTurnID = id
        let screen = currentScreen()
        if display.turnAnswerCard(to: screen, issuedAgainst: revision, onSelect: selectionHandler) {
            shownScreen = screen
            if id != nil { readingStats.earlierOpened += 1 }
            noteDrawn(screen)
        } else {
            openedTurnID = previous
        }
    }

    /// Clear the card and leave interactive mode so ambient producers resume. The card is kept,
    /// in memory, for `reopen()` (Plan MG §7) unless `remember` is false.
    func close(remember: Bool = true) {
        idleGeneration += 1
        let wasShowing = isShowing
        let keep = remember && !forgetOnClose && !answer.isEmpty && !pages.isEmpty
        forgetOnClose = false
        closedCard = keep
            ? ClosedCard(answer: answer, pages: pages, pageIndex: pageIndex, followUps: followUps,
                         question: question, picture: picture, closedAt: now(), turnID: turnID,
                         text: shownText, openedTurnID: openedTurnID)
            : nil
        if !wasShowing, display.holdsAnswerCardUnderPage { display.dropAnswerCardUnderPage() }
        answer = ""
        pages = []
        pageIndex = 0
        isOnActions = false
        followUps = []
        question = nil
        answerIsComplete = false
        hasPage = false
        picture = nil
        shownScreen = nil
        answerMadeAt = nil
        shownText = ""
        isReadingView = false
        openedTurnID = nil
        redraw.reset()
        if wasShowing { display.endInteractive() }
    }

    // MARK: - Bringing the card back (Plan MG §7)

    /// How long after it closed a card can still be brought back by voice. The card is in memory
    /// only, and a new answer replaces it.
    static let reopenLifetime: TimeInterval = 10 * 60

    /// The last card closed (**Close**, its lifetime), for `reopen()`.
    private struct ClosedCard {
        let answer: String
        let pages: [HUDAnswerPage]
        let pageIndex: Int
        let followUps: [String]
        let question: String?
        let picture: HUDPicture?
        let closedAt: Date
        /// Plan MG §2: the turn as the log knows it, its text with the sources line, and the
        /// earlier answer open at the top of the reading view when it closed.
        let turnID: Int
        let text: String
        let openedTurnID: Int?
    }
    private var closedCard: ClosedCard?

    /// Whether there is an answer `reopen()` could put back on the lens: the card it holds (the
    /// glasses' Back gesture leaves it held but off the lens), or the last one closed inside
    /// `reopenLifetime`.
    var canReopen: Bool {
        if !answer.isEmpty, !pages.isEmpty { return true }
        guard let closedCard else { return false }
        return now().timeIntervalSince(closedCard.closedAt) < Self.reopenLifetime
    }

    /// The wearer asked, hands-free, to see the last answer again ("show that again",
    /// `HUDReopenCommand`). The card goes up on the page they were reading, as a frame they asked
    /// for: a lens they dismissed with the glasses' Back gesture opens again. A card already on
    /// the lens is drawn again. False — and nothing changes — when there is no answer to bring
    /// back or the lens cannot take the card now (the HUD off, a task card or a menu up); the
    /// caller then lets the words go on as an ordinary request.
    ///
    /// Only ever on the wearer's word: nothing calls this on a timer to keep the lens awake.
    @discardableResult
    func reopen() -> Bool {
        guard canReopen, display.acceptsAnswerCard else { return false }
        if answer.isEmpty || pages.isEmpty, let closed = closedCard {
            answer = closed.answer
            pages = closed.pages
            pageIndex = min(closed.pageIndex, closed.pages.count - 1)
            followUps = closed.followUps
            question = closed.question
            picture = closed.picture
            answerIsComplete = true
            hasPage = false
            cardSerial += 1
            turnID = closed.turnID
            shownText = closed.text
            openedTurnID = closed.openedTurnID.flatMap { log.turn(id: $0) != nil ? $0 : nil }
        }
        closedCard = nil
        isOnActions = false
        // Plan MG §7: the reading view comes back as the reading view, at the answer the wearer
        // last had at its top (where they had scrolled to, the app never knows).
        isReadingView = usesReadingView()
        if isReadingView { _ = redraw.textChanged(Self.readingProgress(shownText, geometry: geometry(),
                                                                      isComplete: answerIsComplete)) }
        answerMadeAt = now()
        display.wearerAskedForAnswerCard()
        let screen = currentScreen()
        guard display.presentAnswerCard(screen, wearerLed: true, onSelect: selectionHandler) else { return false }
        shownScreen = screen
        noteDrawn(screen)
        armIdleTimer()
        return true
    }

    /// Forget the card, held or closed, so no word brings it back: the private conversation ended
    /// (Plan LU), and its words must not reappear on the lens. A card on the lens now stays until
    /// it closes, and is not kept when it does. Plan MG §3: what the lens remembers of the
    /// conversation goes too, so no earlier answer of it is offered again.
    func forgetForReopen() {
        closedCard = nil
        log.clear()
        if !isHeld { close(remember: false) } else { forgetOnClose = true }
    }

    /// Plan MG §3: the conversation was reset (a new chat, "new topic"): nothing of it is brought
    /// back to the lens or offered as an earlier answer.
    func conversationEnded() {
        forgetForReopen()
    }

    /// Plan MG §3: the HUD was turned off; the lens forgets the conversation.
    func hudTurnedOff() {
        log.clear()
        closedCard = nil
    }

    /// Plan MG §3: the glasses' link went down (or came back). Down for longer than the card's
    /// lifetime, the lens forgets the conversation; back before that, nothing changes.
    func glassesLinkChanged(_ connected: Bool) {
        linkGeneration += 1
        guard !connected else { return }
        let generation = linkGeneration
        scheduleIdleTimer(currentLifetime) { [weak self] in
            guard let self, generation == self.linkGeneration else { return }
            self.log.clear()
            self.closedCard = nil
        }
    }

    /// The lifetime of the card as it is shown: the reading view's, or the paged card's.
    private var currentLifetime: TimeInterval { isReadingView ? readingIdleLifetime : idleLifetime }
    private var forgetOnClose = false

    /// Plan KP §8 rule 4: the Display is ours again after another app had it. The held card shows
    /// again, on the page the wearer left, if it is inside its lifetime counted from when the answer
    /// was made; an older one is dropped. The lifetime timer already running is left as it is.
    func displayReturned() {
        guard isShowing else { return }
        guard let made = answerMadeAt, now().timeIntervalSince(made) < currentLifetime else {
            close()
            return
        }
        let screen = currentScreen()
        if display.presentAnswerCard(screen, onSelect: selectionHandler) { shownScreen = screen }
    }

    /// Plan KV: the page view closed and this card, held under it, is on the lens again. Its
    /// lifetime starts over: the wearer was reading the page, not ignoring the answer.
    func returnedFromPage() {
        guard isShowing else { return }
        let screen = currentScreen()
        if display.presentAnswerCard(screen, onSelect: selectionHandler) { shownScreen = screen }
        armIdleTimer()
    }

    /// The wearer is on the card's last readable page.
    private var isOnLastPage: Bool {
        !isOnActions && pageIndex >= max(1, min(visiblePageCount, pages.count)) - 1
    }

    private func show(page: Int, actions: Bool, _ revision: UInt64) {
        let previous = (pageIndex, isOnActions)
        pageIndex = page
        isOnActions = actions
        let screen = currentScreen()
        if display.turnAnswerCard(to: screen, issuedAgainst: revision, onSelect: selectionHandler) {
            shownScreen = screen
        } else {
            (pageIndex, isOnActions) = previous
        }
    }

    private func save() {
        let title = Self.noteTitle(for: answer)
        let content = answer
        guard !content.isEmpty, let saveNote else { return }
        Task { @MainActor [weak self] in
            let saved = await saveNote(title, content)
            self?.display.flash(saved ? String(localized: "Saved") : String(localized: "Couldn't save that"),
                                duration: 2)
        }
    }

    /// Restart the lifetime. A timer armed earlier finds a newer generation and does nothing, so
    /// an old timer never clears a newer card; nor does one clear a card that is no longer ours
    /// (a task card or a menu took the HUD).
    private func armIdleTimer() {
        idleGeneration += 1
        let generation = idleGeneration
        scheduleIdleTimer(currentLifetime) { [weak self] in
            guard let self, generation == self.idleGeneration, self.isShowing else { return }
            self.close()
        }
    }

    // MARK: - Screens

    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let shown = self?.shownScreen else { return }
            if let item = shown.items.first(where: { $0.id == id }) {
                item.action()
            } else if let block = shown.block(id: id) {
                block.action?()   // Plan MG §2: a reading-view row or an earlier answer
            }
        }
    }

    /// A band press acts on the buttons of the card as last drawn.
    private var onAction: (HUDAnswerAction) -> Void {
        { [weak self] action in
            guard let self else { return }
            self.handle(action, issuedAgainst: self.display.heldScreenRevision)
        }
    }

    /// The screen for the card's position: a page carrying every readable page (for the web
    /// mirror), or the Actions screen.
    private func currentScreen() -> HUDScreen {
        let onAction = self.onAction
        let showsPage = hasPage && pageCanOpen()
        if isReadingView, !isOnActions {
            var screen = HUDReadingViewBuilder.screen(readingState(hasPage: showsPage), geometry: geometry(),
                                                      onAction: onAction)
            screen.pageSet = HUDPageSet(pages: [screen], index: 0, card: cardSerial)
            return screen
        }
        if isOnActions {
            return HUDAnswerCardBuilder.actions(pages, followUps: followUps, hasPage: showsPage,
                                                onAction: onAction)
        }
        let readable = max(1, min(visiblePageCount, pages.count))
        let screens = (0..<readable).compactMap {
            HUDAnswerCardBuilder.page(pages, index: $0, followUps: followUps, question: question,
                                      picture: picture, hasPage: showsPage, onAction: onAction)
        }
        let index = min(pageIndex, readable - 1)
        var screen = screens.indices.contains(index) ? screens[index] : HUDScreen()
        screen.pageSet = HUDPageSet(pages: screens, index: index, card: cardSerial)
        return screen
    }

    /// The reading view's state: the newest turn (or the earlier one open at the top) and the
    /// conversation's earlier answers under it.
    private func readingState(hasPage: Bool) -> HUDReadingViewState {
        if let opened = openedTurnID, let turn = log.turn(id: opened) {
            return HUDReadingViewState(
                top: .init(id: turn.id, question: turn.question, text: turn.answer, isComplete: true,
                           followUps: [], hasPage: false),
                topIsLatest: false, earlier: log.earlier(than: opened))
        }
        let earlier = log.turn(id: turnID) != nil
            ? log.earlier(than: turnID)
            : log.newestFirst.filter { $0.id != turnID }
        return HUDReadingViewState(
            top: .init(id: turnID, question: question, text: shownText, isComplete: answerIsComplete,
                       followUps: followUps, hasPage: hasPage),
            topIsLatest: true, earlier: earlier)
    }

    // MARK: - The reading view's words (Plan MG §2)

    /// The reading view is the frame on the lens, and the lens is ours.
    var showsReadingView: Bool {
        isShowing && isReadingView && !isOnActions && display.displayAvailability != .inUse
    }

    /// A spoken reading word (`HUDReadingCommand`), while an answer is on the lens. True when it
    /// did something; false leaves the words to the model ("earlier" with nothing earlier).
    @discardableResult
    func handleReadingCommand(_ command: HUDReadingCommand) -> Bool {
        guard isShowing, display.displayAvailability != .inUse, !isOnActions else { return false }
        let revision = display.heldScreenRevision
        switch command {
        case .sayAgain:
            let text = openedTurnID.flatMap { log.turn(id: $0)?.answer } ?? answer
            guard !text.isEmpty, let speakAgain else { return false }
            speakAgain(text)
            return true
        case .earlier:
            let topID = openedTurnID ?? turnID
            let target = log.turn(id: topID) != nil
                ? log.turn(before: topID)
                : log.newestFirst.first { $0.id != turnID }
            guard let target else { return false }
            if isReadingView {
                guard display.acceptsCardPress(issuedAgainst: revision) else { return false }
                armIdleTimer()
                showReading(opening: target.id, revision)
                return openedTurnID == target.id
            }
            return showAsPages(target)
        case .latest:
            if isReadingView {
                guard openedTurnID != nil, display.acceptsCardPress(issuedAgainst: revision) else { return false }
                armIdleTimer()
                showReading(opening: nil, revision)
                return openedTurnID == nil
            }
            guard let latest = log.latest, latest.id != turnID else { return false }
            return showAsPages(latest)
        }
    }

    /// Paged answers (Even, or **Pages**): an answer the lens remembers goes up as the card, from
    /// its first page. Not while a turn is still answering: the card is the turn's.
    private func showAsPages(_ remembered: LensConversationTurn) -> Bool {
        guard turn == nil else { return false }
        let laid = HUDAnswerPager.pages(for: remembered.answer, geometry: geometry(),
                                        firstPageReservedLines: remembered.question == nil ? 0 : 1)
        guard !laid.isEmpty else { return false }
        answer = remembered.answer
        shownText = remembered.answer
        pages = laid
        pageIndex = 0
        isOnActions = false
        followUps = remembered.followUps
        question = remembered.question
        picture = nil
        hasPage = false
        answerIsComplete = true
        turnID = remembered.id
        cardSerial += 1
        answerMadeAt = now()
        let screen = currentScreen()
        guard display.presentAnswerCard(screen, onSelect: selectionHandler) else { return false }
        shownScreen = screen
        readingStats.earlierOpened += 1
        armIdleTimer()
        return true
    }

    // MARK: - The support report (Plan MG §3: counts and sizes only)

    var reportLines: [String] {
        LensReadingReport.lines(stats: readingStats, heldTurns: log.count,
                                style: usesReadingView() ? "scroll" : "pages")
    }
}
