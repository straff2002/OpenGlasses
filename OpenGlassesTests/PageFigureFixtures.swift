import CoreGraphics
import PDFKit
import UIKit
@testable import OpenGlasses

/// Invented pages for the Plan KV P1b tests, drawn with `UIGraphicsPDFRenderer` on a letter page:
/// block diagrams, captions and paragraphs made up for the tests. No real manual, caption or
/// label; captions are invented numbers ("Figure 12").
enum PageFigureFixtures {

    static let letter = LensPageFixtures.letter
    static let font = UIFont.systemFont(ofSize: 10)

    // MARK: Pages

    /// A block diagram with paragraphs above and below it.
    static let blockDiagram = CGRect(x: 150, y: 220, width: 300, height: 180)

    /// Two drawings, each with a caption under it.
    static let captionedUpper = CGRect(x: 100, y: 90, width: 400, height: 200)
    static let captionedLower = CGRect(x: 100, y: 400, width: 400, height: 200)

    /// Two drawings and no caption: the upper one larger, labelled for the blower; the lower one
    /// labelled for the board.
    static let blowerDrawing = CGRect(x: 90, y: 100, width: 420, height: 240)
    static let boardDrawing = CGRect(x: 150, y: 450, width: 300, height: 180)

    /// A drawing with no caption, no label and no title.
    static let bareDrawing = CGRect(x: 150, y: 260, width: 300, height: 200)

    /// The drawing that fills the page.
    static let wholeSheet = CGRect(x: 24, y: 24, width: 564, height: 744)

    /// A table drawn as its border only.
    static let tableBorder = CGRect(x: 72, y: 200, width: 468, height: 300)

    static func blockDiagramPage() throws -> URL {
        try pdf("block") {
            paragraph(lines: 5, top: 60)
            diagram(in: blockDiagram, labels: ["relay", "board", "fan"])
            paragraph(lines: 6, top: 500)
            text("Invented footer 4", at: CGPoint(x: 72, y: 740))
        }
    }

    static func twoCaptionedPage() throws -> URL {
        try pdf("captions") {
            diagram(in: captionedUpper, labels: ["coil", "valve", "switch"])
            text("Figure 12. Invented coil layout", at: CGPoint(x: 100, y: captionedUpper.maxY + 10))
            diagram(in: captionedLower, labels: ["pump", "sensor", "timer"])
            text("Figure 13. Invented pump layout", at: CGPoint(x: 100, y: captionedLower.maxY + 10))
            text("See Figure 13 for the pump.", at: CGPoint(x: 72, y: 700))
        }
    }

    static func twoUncaptionedPage() throws -> URL {
        try pdf("uncaptioned") {
            text("Invented upper layout", at: CGPoint(x: 90, y: blowerDrawing.minY - 22))
            diagram(in: blowerDrawing, labels: ["blower", "motor", "capacitor"])
            paragraph(lines: 2, top: 370)
            text("Invented lower layout", at: CGPoint(x: 120, y: boardDrawing.minY - 22))
            diagram(in: boardDrawing, labels: ["board", "fuse", "jumper"])
        }
    }

    static func bareDrawingPage() throws -> URL {
        try pdf("bare") {
            paragraph(lines: 8, top: 60)
            zigzag(in: bareDrawing)
            paragraph(lines: 8, top: 520)
        }
    }

    static func textOnlyPage() throws -> URL {
        try pdf("text") { paragraph(lines: 40, top: 60) }
    }

    static func wholeSheetPage() throws -> URL {
        try pdf("sheet") {
            stroke(UIBezierPath(rect: wholeSheet))
            let columns = 3, rows = 4
            let cell = CGSize(width: wholeSheet.width / CGFloat(columns), height: wholeSheet.height / CGFloat(rows))
            var names = ["blower", "board", "fuse", "relay", "motor", "valve", "coil", "pump", "timer", "switch",
                         "sensor", "fan"].makeIterator()
            for row in 0..<rows {
                for column in 0..<columns {
                    let origin = CGPoint(x: wholeSheet.minX + CGFloat(column) * cell.width,
                                         y: wholeSheet.minY + CGFloat(row) * cell.height)
                    let box = CGRect(x: origin.x + 30, y: origin.y + 40, width: cell.width - 60, height: cell.height - 90)
                    stroke(UIBezierPath(ovalIn: box))
                    let wire = UIBezierPath()
                    wire.move(to: CGPoint(x: box.midX, y: box.maxY))
                    wire.addLine(to: CGPoint(x: origin.x + cell.width - 4, y: origin.y + cell.height - 4))
                    stroke(wire)
                    text(names.next() ?? "", at: CGPoint(x: box.midX - 14, y: box.midY - 6))
                }
            }
        }
    }

    static func tableBorderPage() throws -> URL {
        try pdf("table") {
            paragraph(lines: 3, top: 80)
            stroke(UIBezierPath(rect: tableBorder))
            for row in 0..<10 {
                let y = tableBorder.minY + 14 + CGFloat(row) * 27
                text("Invented row \(row + 1)", at: CGPoint(x: tableBorder.minX + 12, y: y))
                text("\(row * 3 + 4) A", at: CGPoint(x: tableBorder.midX + 12, y: y))
            }
            paragraph(lines: 4, top: 560)
        }
    }

    static func ruleLinePage() throws -> URL {
        try pdf("rule") {
            paragraph(lines: 10, top: 60)
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 72, y: 340, width: 468, height: 1))
            paragraph(lines: 10, top: 380)
        }
    }

    // MARK: Opening

    static func page(_ url: URL, index: Int = 0) -> PDFPage? {
        PDFDocument(url: url)?.page(at: index)
    }

    // MARK: Drawing

    private static func pdf(_ name: String, _ draw: () -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kv-p1b-\(name)-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            draw()
        }
        return url
    }

    static func text(_ string: String, at point: CGPoint) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: UIColor.black])
    }

    static func paragraph(lines: Int, top: CGFloat) {
        for line in 0..<lines {
            text("Invented note line \(line + 1) about checking the invented unit before service",
                 at: CGPoint(x: 72, y: top + CGFloat(line) * 14))
        }
    }

    private static func stroke(_ path: UIBezierPath, width: CGFloat = 1.5) {
        UIColor.black.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    /// Three boxes, the outer two along the top edge and the middle one on the bottom edge,
    /// joined by wires, each with its label inside. The ink's bounds are `rect`.
    static func diagram(in rect: CGRect, labels: [String]) {
        let size = CGSize(width: rect.width * 0.26, height: rect.height * 0.32)
        let left = CGRect(origin: CGPoint(x: rect.minX, y: rect.minY), size: size)
        let right = CGRect(origin: CGPoint(x: rect.maxX - size.width, y: rect.minY), size: size)
        let middle = CGRect(origin: CGPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height), size: size)
        // The stroke straddles the path, so the boxes sit half a stroke inside the rectangle.
        for box in [left, right, middle] { stroke(UIBezierPath(rect: box.insetBy(dx: 0.75, dy: 0.75))) }
        let wire = UIBezierPath()
        wire.move(to: CGPoint(x: left.maxX, y: left.midY))
        wire.addLine(to: CGPoint(x: right.minX, y: right.midY))
        wire.move(to: CGPoint(x: rect.midX, y: left.midY))
        wire.addLine(to: CGPoint(x: rect.midX, y: middle.minY))
        wire.move(to: CGPoint(x: left.midX, y: left.maxY))
        wire.addLine(to: CGPoint(x: left.midX, y: middle.midY))
        wire.addLine(to: CGPoint(x: middle.minX, y: middle.midY))
        wire.move(to: CGPoint(x: right.midX, y: right.maxY))
        wire.addLine(to: CGPoint(x: right.midX, y: middle.midY))
        wire.addLine(to: CGPoint(x: middle.maxX, y: middle.midY))
        stroke(wire)
        for (box, label) in zip([left, right, middle], labels) {
            text(label, at: CGPoint(x: box.minX + 8, y: box.midY - 6))
        }
    }

    /// A trace and a ring, and no text at all.
    static func zigzag(in rect: CGRect) {
        let trace = UIBezierPath()
        trace.move(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
        let steps = 10
        for step in 1...steps {
            let x = rect.minX + 1 + (rect.width - 2) * CGFloat(step) / CGFloat(steps)
            let y = step.isMultiple(of: 2) ? rect.maxY - 1 : rect.minY + 60
            trace.addLine(to: CGPoint(x: x, y: y))
        }
        stroke(trace)
        stroke(UIBezierPath(ovalIn: CGRect(x: rect.midX - 30, y: rect.minY + 1, width: 60, height: 50)))
    }
}
