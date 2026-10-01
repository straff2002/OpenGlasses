import CoreGraphics

/// The home grid's pages, as arithmetic.
///
/// The grid used to scroll vertically inside a panel that already paged horizontally — two scroll
/// axes in one piece of glass. It pages like a home screen now: the conversation first, then as
/// many grid pages as the tiles need, one whole page per swipe. Everything that decides *which*
/// tile is *where* lives here, so the view only draws what this says and the rules can be checked
/// without a screen.
///
/// **One order, cut into pages.** The tiles are the user's arranged order, flowed row by row
/// across the pages: nothing is reordered to fill a page, skipped at a page edge, or drawn twice.
/// A page is a contiguous slice of that order and only the last page can be short. The editor
/// edits the order, never the pages, so moving a tile never depends on how tall the screen is.
///
/// **Rows adapt; columns do not.** How many rows a page holds is how many whole tiles fit the room
/// the cards above left — `rowsThatFit` — between one and `maxRows`. The column count comes in from
/// the view (three, or one at accessibility text sizes) and is not this type's decision.
struct HomeGridPaging: Equatable {
    /// The most rows a page holds. Past four, a page is a wall of keys rather than a set of them,
    /// and the remainder of a tall panel is better as calm glass than as a fifth row.
    static let maxRows = 4

    /// The pager's index for the conversation page. It always comes first, so swiping back from
    /// grid page 1 is the way to it.
    static let conversationIndex = 0

    let tileCount: Int
    let columns: Int
    let rows: Int

    init(tileCount: Int, columns: Int, rows: Int) {
        self.tileCount = max(0, tileCount)
        self.columns = max(1, columns)
        self.rows = min(Self.maxRows, max(1, rows))
    }

    // MARK: - Fitting

    /// Whole rows that fit `height` — the page's body above the dots — at `rowHeight` per tile
    /// and `rowSpacing` between rows, clamped to `1...maxRows`.
    ///
    /// Every row past the first also costs the gap above it, so the budget is `height + gap`
    /// divided by `tile + gap`; truncating *is* the whole-row rule — a sliced tile is not a smaller
    /// control, it is an unreachable one. Never zero: a panel at its floor still shows one row,
    /// and the zone above scrolls instead. Dynamic Type grows `rowHeight`, so larger text fits
    /// fewer rows rather than smaller tiles.
    static func rowsThatFit(height: CGFloat, rowHeight: CGFloat,
                            rowSpacing: CGFloat = DockGridMetrics.rowSpacing) -> Int {
        guard rowHeight > 0, height.isFinite, height > 0 else { return 1 }
        let whole = Int(((height + rowSpacing) / (rowHeight + rowSpacing)).rounded(.down))
        return min(maxRows, max(1, whole))
    }

    // MARK: - Pages

    var tilesPerPage: Int { rows * columns }

    /// At least one: an empty grid still has its page, so the cog has somewhere to sit.
    var pageCount: Int {
        guard tileCount > 0 else { return 1 }
        return (tileCount + tilesPerPage - 1) / tilesPerPage
    }

    /// The dots under the panel: the conversation and every grid page.
    var dotCount: Int { 1 + pageCount }

    /// The contiguous slice of the one order that `page` holds — empty for a page that does not
    /// exist.
    func tileRange(onPage page: Int) -> Range<Int> {
        guard page >= 0, page < pageCount else { return 0..<0 }
        let start = min(tileCount, page * tilesPerPage)
        return start..<min(tileCount, start + tilesPerPage)
    }

    /// The page tile `index` is drawn on, clamped into the grid.
    func page(ofTile index: Int) -> Int {
        guard tileCount > 0 else { return 0 }
        return min(max(0, index), tileCount - 1) / tilesPerPage
    }

    struct Position: Equatable {
        let page: Int
        let row: Int
        let column: Int
    }

    /// Where tile `index` is drawn: row-major within its page, so a page reads left to right, top
    /// to bottom, in the order the editor shows.
    func position(ofTile index: Int) -> Position? {
        guard index >= 0, index < tileCount else { return nil }
        let within = index % tilesPerPage
        return Position(page: index / tilesPerPage, row: within / columns, column: within % columns)
    }

    /// Rows a page actually draws. Only the last page can be short; a row with no tile in it is
    /// not drawn, and the glass under the last drawn row is the panel's remainder.
    func rowsDrawn(onPage page: Int) -> Int {
        let count = tileRange(onPage: page).count
        return (count + columns - 1) / columns
    }

    // MARK: - The pager's indices

    /// The pager index of grid page `page` (zero-based): the conversation is index 0.
    func panelIndex(forGridPage page: Int) -> Int {
        1 + min(max(0, page), pageCount - 1)
    }

    /// The grid page a pager index shows, or `nil` for the conversation. An index past the last
    /// page is clamped to it rather than treated as the conversation.
    func gridPage(forPanelIndex index: Int) -> Int? {
        guard index > Self.conversationIndex else { return nil }
        return min(index - 1, pageCount - 1)
    }

    // MARK: - Reflow

    /// The grid page to show for a remembered anchor tile.
    ///
    /// The anchor is the first tile of the page the user last chose. When the rows per page change
    /// — a card above expands, the text size changes — the page that holds that tile is the page
    /// that still shows what they were looking at, which is the whole of "keep the first visible
    /// tile". The anchor is never rewritten by a reflow, so a card opening and closing again comes
    /// back to the page it started on rather than drifting.
    ///
    /// An anchor that is no longer in the grid (the tile was removed, or its gate closed) falls
    /// back to `fallback`, clamped to the pages that exist.
    func gridPage(anchoredAt anchor: String?, in tileIDs: [String], fallback: Int = 0) -> Int {
        if let anchor, let index = tileIDs.firstIndex(of: anchor) {
            return page(ofTile: index)
        }
        return min(max(0, fallback), pageCount - 1)
    }

    /// The anchor a user's move to grid page `page` records: that page's first tile — or `nil` for
    /// the first page, which stays the first page whatever is put in front of its first tile.
    func anchor(forGridPage page: Int, in tileIDs: [String]) -> String? {
        let clamped = min(max(0, page), pageCount - 1)
        guard clamped > 0 else { return nil }
        let range = tileRange(onPage: clamped)
        guard let first = range.first, first < tileIDs.count else { return nil }
        return tileIDs[first]
    }

    /// The pager index the panel shows for a pager state, under this paging. Derived every time
    /// rather than stored, so a reflow moves the panel to the anchor's page with nothing to keep in
    /// step.
    func panelIndex(for state: DockPagerState, tileIDs: [String]) -> Int {
        switch state.page {
        case .conversation:
            return Self.conversationIndex
        case .actions:
            return panelIndex(forGridPage: gridPage(anchoredAt: state.gridAnchor, in: tileIDs))
        }
    }
}

// MARK: - The tiles a page actually draws

/// One cell of the home grid. Usually an arranged slot; the on-device model's load/unload key is a
/// tile of its own, riding just in front of Model so the two model controls read as one group.
enum HomeGridTile: Identifiable, Equatable {
    case slot(DockSlot)
    case localModel

    static let localModelID = "tile:local-model"

    var id: String {
        switch self {
        case .slot(let slot): return slot.id
        case .localModel: return Self.localModelID
        }
    }
}

/// Which arranged slots draw a tile right now.
///
/// The scrolling grid could let a slot draw nothing — a gated control simply left no cell — but a
/// paged grid has to know exactly which tiles each page holds, or a page grows a hole and the next
/// page starts a tile early. So the gates are applied *before* paging, here, and the view draws
/// every tile it is handed. Gating changes WHEN a slot appears, never where: the arranged order is
/// kept, and nothing is added twice.
struct HomeGridTilePresence: Equatable {
    /// The live preview is reachable (glasses connected).
    var previewAvailable = false
    /// The surface can open a typed message.
    var canType = true
    /// Assistive mode is turned on in Settings.
    var assistiveAvailable = false
    /// Glasses are connected, so there is something to disconnect.
    var connected = false
    /// The active model runs on the device, so its load/unload key rides in front of Model.
    var localModelActive = false

    func isPresent(_ item: DockItem) -> Bool {
        switch item {
        case .model, .camera, .micMode: return true
        case .preview: return previewAvailable
        case .type: return canType
        case .assistive: return assistiveAvailable
        case .disconnect: return connected
        }
    }

    /// The arranged slots as the tiles the grid draws, in the same order.
    func tiles(for slots: [DockSlot]) -> [HomeGridTile] {
        var tiles: [HomeGridTile] = []
        tiles.reserveCapacity(slots.count + 1)
        for slot in slots {
            if case .control(let item) = slot {
                guard isPresent(item) else { continue }
                if item == .model, localModelActive { tiles.append(.localModel) }
            }
            tiles.append(.slot(slot))
        }
        return tiles
    }
}
