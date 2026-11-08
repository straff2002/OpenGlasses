import CoreGraphics
import Foundation

// Plan KV P1b — finding the diagram on a page from its ink alone. No caption, figure number or
// title is needed to find one; a caption only helps choose when a page holds several
// (`PageFigureChoice`). Everything here is pure: the PDF edge that builds the mask and reads the
// text lines is `PageFigureAnalysis`.

/// A coarse ink mask of one page: a grid of square cells over the page, each inked or not, in
/// top-down page points from the media box's top left (P0's convention, `LensPageViewport`).
struct PageInkMask: Equatable, Sendable {
    /// The page, in PDF points.
    let pageSize: CGSize
    /// A cell's side, in page points.
    let cellSize: CGFloat
    let columns: Int
    let rows: Int
    /// Row-major, the top row first.
    private(set) var cells: [Bool]

    /// An empty mask over `pageSize`, or one from `cells` (row-major, top row first) when their
    /// count fits the grid.
    init(pageSize: CGSize, cellSize: CGFloat, cells: [Bool]? = nil) {
        let side = max(cellSize, 0.5)
        self.pageSize = pageSize
        self.cellSize = side
        columns = max(1, Int((max(pageSize.width, 1) / side).rounded(.up)))
        rows = max(1, Int((max(pageSize.height, 1) / side).rounded(.up)))
        if let cells, cells.count == columns * rows {
            self.cells = cells
        } else {
            self.cells = [Bool](repeating: false, count: columns * rows)
        }
    }

    /// A mask from a page's luma, one byte a pixel, top row first, `width` × `height` pixels over
    /// the page: a cell is inked when any of its pixels is darker than `threshold`.
    init(luma: [UInt8], width: Int, height: Int, pageSize: CGSize, cellSize: CGFloat, threshold: UInt8) {
        self.init(pageSize: pageSize, cellSize: cellSize)
        guard width > 0, height > 0, luma.count >= width * height,
              pageSize.width > 0, pageSize.height > 0 else { return }
        let pointsPerPixelX = pageSize.width / CGFloat(width)
        let pointsPerPixelY = pageSize.height / CGFloat(height)
        for y in 0..<height {
            let row = min(rows - 1, Int((CGFloat(y) + 0.5) * pointsPerPixelY / self.cellSize))
            let base = y * width
            for x in 0..<width where luma[base + x] < threshold {
                let column = min(columns - 1, Int((CGFloat(x) + 0.5) * pointsPerPixelX / self.cellSize))
                cells[row * columns + column] = true
            }
        }
    }

    subscript(column: Int, row: Int) -> Bool {
        get {
            guard column >= 0, row >= 0, column < columns, row < rows else { return false }
            return cells[row * columns + column]
        }
        set {
            guard column >= 0, row >= 0, column < columns, row < rows else { return }
            cells[row * columns + column] = newValue
        }
    }

    var inkedCount: Int { cells.lazy.filter { $0 }.count }

    /// Cell `(column, row)` in page points.
    func rect(column: Int, row: Int) -> CGRect {
        CGRect(x: CGFloat(column) * cellSize, y: CGFloat(row) * cellSize, width: cellSize, height: cellSize)
    }

    /// The cells a page rectangle touches, clamped to the grid; nil when it touches none.
    func cellRange(of rect: CGRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        let r = rect.standardized
        guard !r.isNull, r.maxX > 0, r.maxY > 0,
              r.minX < CGFloat(columns) * cellSize, r.minY < CGFloat(rows) * cellSize else { return nil }
        let c0 = max(0, Int((r.minX / cellSize).rounded(.down)))
        let r0 = max(0, Int((r.minY / cellSize).rounded(.down)))
        let c1 = min(columns - 1, Int((r.maxX / cellSize).rounded(.up)) - 1)
        let r1 = min(rows - 1, Int((r.maxY / cellSize).rounded(.up)) - 1)
        guard c1 >= c0, r1 >= r0 else { return nil }
        return (c0...c1, r0...r1)
    }

    /// Clear every cell `rect` (page points) touches.
    mutating func blank(_ rect: CGRect) {
        guard let range = cellRange(of: rect) else { return }
        for row in range.rows { for column in range.columns { self[column, row] = false } }
    }

    /// Ink every cell `rect` (page points) touches. For building masks by hand.
    mutating func ink(_ rect: CGRect) {
        guard let range = cellRange(of: rect) else { return }
        for row in range.rows { for column in range.columns { self[column, row] = true } }
    }
}

/// One line of a page's text, in top-down page points.
struct PageTextLine: Equatable, Sendable {
    let rect: CGRect
    let text: String
}

/// A drawing on a page: where it is, the text inside it (its labels, blanked out of the ink but
/// kept for choosing) and the line just above it (its heading).
struct PageDrawing: Equatable, Sendable {
    /// In top-down page points.
    let rect: CGRect
    let labels: [PageTextLine]
    let heading: PageTextLine?

    var area: CGFloat { rect.width * rect.height }
}

/// Finds a page's drawings in its ink (Plan KV P1b). Pure.
///
/// 1. **Text is not ink.** Every cell a text line touches (its rectangle grown by
///    `textMarginPoints`, for the glyphs' antialiased edges) is blanked, so paragraphs, captions
///    and a drawing's own labels never count.
/// 2. **Blocks.** The ink left is dilated by `gapClosingCells` (a square neighbourhood) and the
///    dilated mask is labelled into 8-connected blocks, so a diagram's thin lines, broken where a
///    label was blanked, hold together. Each block's rectangle is the tight bounds of its original
///    (undilated) ink. Blocks whose rectangles overlap are joined (a frame round loose parts).
/// 3. **What is not a drawing.** A block is dropped when it is too thin (`minimumSidePoints`, a
///    rule line), too small (`minimumAreaPoints`, `minimumLongSidePoints`: a logo, an icon, a
///    stray mark), has too little ink (`minimumInkCells`), or is only ruled lines: sparse
///    (`ruledDensityLimit` of its cells inked or fewer) with nearly all its ink
///    (`ruledInkShare`) on rows or columns that run across the whole block
///    (`fullSpanShare`) — a table's border, or a table's grid, and nothing inside.
/// 4. **Reading order.** Rows top to bottom (blocks sharing half their height share a row), left
///    to right within a row.
enum PageFigureLocator {

    /// A cell's side at the default analysis: 4 pt, about the stroke spacing of the finest
    /// hatching a drawing uses, and a letter page is 153 × 198 cells.
    static let defaultCellSize: CGFloat = 4
    /// Text rectangles grow by this before blanking.
    static let textMarginPoints: CGFloat = 2
    /// Dilation radius, in cells: 2 cells (8 pt) bridges a gap of up to 16 pt — a label blanked
    /// out of a wire, the space between a box and its leader — but not the 30 pt or more between
    /// two drawings with a caption line between them.
    static let gapClosingCells = 2
    /// Thinner than this on either side is a rule line, not a drawing.
    static let minimumSidePoints: CGFloat = 24
    /// Under a square inch is a logo or an icon.
    static let minimumAreaPoints: CGFloat = 72 * 72
    static let minimumLongSidePoints: CGFloat = 48
    static let minimumInkCells = 8
    /// The ruled-lines test: a row (or column) "runs across" when this share of the block's span
    /// is inked on it…
    static let fullSpanShare: CGFloat = 0.85
    /// …and a block is only ruled lines when this share of its ink lies on such rows or columns…
    static let ruledInkShare: CGFloat = 0.9
    /// …and no more than this share of its cells is inked (a solid picture is dense, and kept).
    static let ruledDensityLimit: CGFloat = 0.5
    /// The heading is the nearest line ending at most this far above the drawing.
    static let headingReachPoints: CGFloat = 48

    /// The page's drawings, in reading order.
    static func locate(mask: PageInkMask, textLines: [PageTextLine]) -> [PageDrawing] {
        var ink = mask
        for line in textLines {
            ink.blank(line.rect.insetBy(dx: -textMarginPoints, dy: -textMarginPoints))
        }
        guard ink.inkedCount > 0 else { return [] }

        let blocks = joinOverlapping(label(ink))
        let drawings = blocks.compactMap { block -> CGRect? in
            isDrawing(block, in: ink) ? block.rect(cellSize: ink.cellSize).intersection(page(ink)) : nil
        }
        return readingOrder(drawings).map { rect in
            PageDrawing(rect: rect, labels: labels(in: rect, textLines), heading: heading(of: rect, textLines))
        }
    }

    // MARK: Blocks

    /// A block of cells: its inked (undilated) cells and their bounds, in cells.
    struct Block: Equatable {
        var minColumn: Int
        var minRow: Int
        var maxColumn: Int
        var maxRow: Int
        var cells: [Int]

        var columnSpan: Int { maxColumn - minColumn + 1 }
        var rowSpan: Int { maxRow - minRow + 1 }

        func rect(cellSize: CGFloat) -> CGRect {
            CGRect(x: CGFloat(minColumn) * cellSize, y: CGFloat(minRow) * cellSize,
                   width: CGFloat(columnSpan) * cellSize, height: CGFloat(rowSpan) * cellSize)
        }

        func overlaps(_ other: Block) -> Bool {
            minColumn <= other.maxColumn && other.minColumn <= maxColumn
                && minRow <= other.maxRow && other.minRow <= maxRow
        }

        mutating func absorb(_ other: Block) {
            minColumn = min(minColumn, other.minColumn)
            minRow = min(minRow, other.minRow)
            maxColumn = max(maxColumn, other.maxColumn)
            maxRow = max(maxRow, other.maxRow)
            cells += other.cells
        }
    }

    /// Dilate, label the dilated mask 8-connected, and gather each label's original ink.
    static func label(_ ink: PageInkMask) -> [Block] {
        let columns = ink.columns, rows = ink.rows, radius = gapClosingCells
        // Dilation, separably: along the rows, then down the columns.
        var across = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            var lastInked = Int.min / 2
            var nextInked = [Int](repeating: Int.max / 2, count: columns)
            var upcoming = Int.max / 2
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if ink.cells[row * columns + column] { upcoming = column }
                nextInked[column] = upcoming
            }
            for column in 0..<columns {
                if ink.cells[row * columns + column] { lastInked = column }
                across[row * columns + column] = column - lastInked <= radius || nextInked[column] - column <= radius
            }
        }
        var dilated = [Bool](repeating: false, count: columns * rows)
        for column in 0..<columns {
            var lastInked = Int.min / 2
            var nextInked = [Int](repeating: Int.max / 2, count: rows)
            var upcoming = Int.max / 2
            for row in stride(from: rows - 1, through: 0, by: -1) {
                if across[row * columns + column] { upcoming = row }
                nextInked[row] = upcoming
            }
            for row in 0..<rows {
                if across[row * columns + column] { lastInked = row }
                dilated[row * columns + column] = row - lastInked <= radius || nextInked[row] - row <= radius
            }
        }

        var labels = [Int](repeating: -1, count: columns * rows)
        var blocks: [Block] = []
        var stack: [Int] = []
        for start in 0..<(columns * rows) where dilated[start] && labels[start] < 0 {
            let id = blocks.count
            var block = Block(minColumn: .max, minRow: .max, maxColumn: .min, maxRow: .min, cells: [])
            labels[start] = id
            stack.append(start)
            while let index = stack.popLast() {
                let row = index / columns, column = index % columns
                if ink.cells[index] {
                    block.cells.append(index)
                    block.minColumn = min(block.minColumn, column)
                    block.maxColumn = max(block.maxColumn, column)
                    block.minRow = min(block.minRow, row)
                    block.maxRow = max(block.maxRow, row)
                }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let r = row + dy, c = column + dx
                        guard r >= 0, c >= 0, r < rows, c < columns else { continue }
                        let next = r * columns + c
                        if dilated[next] && labels[next] < 0 {
                            labels[next] = id
                            stack.append(next)
                        }
                    }
                }
            }
            if !block.cells.isEmpty { blocks.append(block) }
        }
        return blocks
    }

    /// Join blocks whose rectangles overlap, until none do: a frame drawn round parts that don't
    /// touch it is one drawing.
    static func joinOverlapping(_ blocks: [Block]) -> [Block] {
        var joined = blocks
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < joined.count {
                var other = index + 1
                while other < joined.count {
                    if joined[index].overlaps(joined[other]) {
                        joined[index].absorb(joined.remove(at: other))
                        changed = true
                    } else {
                        other += 1
                    }
                }
                index += 1
            }
        }
        return joined
    }

    static func isDrawing(_ block: Block, in ink: PageInkMask) -> Bool {
        let rect = block.rect(cellSize: ink.cellSize)
        guard min(rect.width, rect.height) >= minimumSidePoints,
              max(rect.width, rect.height) >= minimumLongSidePoints,
              rect.width * rect.height >= minimumAreaPoints,
              block.cells.count >= minimumInkCells else { return false }
        return !isRuledOnly(block, columns: ink.columns)
    }

    /// Only ruled lines: sparse, and nearly all its ink on rows or columns that run across it.
    static func isRuledOnly(_ block: Block, columns: Int) -> Bool {
        let area = CGFloat(block.columnSpan * block.rowSpan)
        guard area > 0, CGFloat(block.cells.count) / area <= ruledDensityLimit else { return false }
        var perRow = [Int](repeating: 0, count: block.rowSpan)
        var perColumn = [Int](repeating: 0, count: block.columnSpan)
        for index in block.cells {
            perRow[index / columns - block.minRow] += 1
            perColumn[index % columns - block.minColumn] += 1
        }
        let fullRows = Set(perRow.indices.filter { CGFloat(perRow[$0]) >= fullSpanShare * CGFloat(block.columnSpan) })
        let fullColumns = Set(perColumn.indices.filter {
            CGFloat(perColumn[$0]) >= fullSpanShare * CGFloat(block.rowSpan)
        })
        let onLines = block.cells.lazy.filter {
            fullRows.contains($0 / columns - block.minRow) || fullColumns.contains($0 % columns - block.minColumn)
        }.count
        return CGFloat(onLines) >= ruledInkShare * CGFloat(block.cells.count)
    }

    // MARK: Order, labels, heading

    /// Rows top to bottom, left to right within a row. A drawing joins the row being built when it
    /// shares at least half the smaller height with it.
    static func readingOrder(_ rects: [CGRect]) -> [CGRect] {
        var rows: [[CGRect]] = []
        for rect in rects.sorted(by: { $0.minY < $1.minY || ($0.minY == $1.minY && $0.minX < $1.minX) }) {
            if let last = rows.last, let first = last.first {
                let span = last.dropFirst().reduce(first) { $0.union($1) }
                let shared = min(span.maxY, rect.maxY) - max(span.minY, rect.minY)
                if shared >= 0.5 * min(span.height, rect.height) {
                    rows[rows.count - 1].append(rect)
                    continue
                }
            }
            rows.append([rect])
        }
        return rows.flatMap { $0.sorted { $0.minX < $1.minX } }
    }

    /// The text lines whose centre lies inside the drawing.
    static func labels(in rect: CGRect, _ lines: [PageTextLine]) -> [PageTextLine] {
        lines.filter { rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
    }

    /// The nearest line ending just above the drawing and overlapping it across.
    static func heading(of rect: CGRect, _ lines: [PageTextLine]) -> PageTextLine? {
        lines.filter { line in
            line.rect.midY < rect.minY
                && rect.minY - line.rect.maxY <= headingReachPoints
                && line.rect.maxX > rect.minX && line.rect.minX < rect.maxX
        }.min { rect.minY - $0.rect.maxY < rect.minY - $1.rect.maxY }
    }

    private static func page(_ ink: PageInkMask) -> CGRect {
        CGRect(origin: .zero, size: ink.pageSize)
    }
}
