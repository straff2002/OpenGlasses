import SwiftUI

/// Lays pills out left to right and starts a new line only when the next one does not fit — the
/// session card's pill row. Each pill gets its full word: one wider than the row is offered the
/// row's width and wraps inside itself rather than being cut.
///
/// Rows are vertically centred, so a 44pt tap target and a drawn-only badge share a line without
/// the badge riding up.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 0

    /// Which items go on which line, by index, for items of the given widths in a row
    /// `maxWidth` wide. Pure, so the wrapping rule is testable without a view.
    static func lines(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > maxWidth {
                lines.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private struct Arrangement {
        var sizes: [CGSize]
        var lines: [[Int]]
        var lineHeights: [CGFloat]
        var size: CGSize
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> Arrangement {
        let sizes = subviews.map { subview -> CGSize in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
        let lines = Self.lines(widths: sizes.map(\.width), maxWidth: maxWidth, spacing: spacing)
        var lineHeights: [CGFloat] = []
        var widest: CGFloat = 0
        for line in lines {
            var lineWidth: CGFloat = 0
            var lineHeight: CGFloat = 0
            for index in line {
                lineWidth += sizes[index].width
                lineHeight = max(lineHeight, sizes[index].height)
            }
            lineWidth += spacing * CGFloat(max(line.count - 1, 0))
            widest = max(widest, lineWidth)
            lineHeights.append(lineHeight)
        }
        var height: CGFloat = lineSpacing * CGFloat(max(lines.count - 1, 0))
        for lineHeight in lineHeights { height += lineHeight }
        return Arrangement(sizes: sizes, lines: lines, lineHeights: lineHeights,
                           size: CGSize(width: widest, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let arrangement = arrange(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for (line, lineHeight) in zip(arrangement.lines, arrangement.lineHeights) {
            var x = bounds.minX
            for index in line {
                let size = arrangement.sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
