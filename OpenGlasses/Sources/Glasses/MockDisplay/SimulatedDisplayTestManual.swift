#if DAT_MOCK_DISPLAY
import Foundation
import UIKit

/// An invented four-page manual for the simulated Display (Plan KV P4), drawn at runtime with
/// `UIGraphicsPDFRenderer`. Every word, label and number in it is made up; it is no real manual.
///
/// 1. A block diagram with small labels, captioned "Figure 1".
/// 2. Two drawings with no caption, one above the other.
/// 3. A table.
/// 4. A text page, with the sentence the walkthrough cites.
enum SimulatedDisplayTestManual {
    static let documentId = "simulated-display-test-manual"
    static let title = "Invented Q-7 Relay Board Guide"
    static let fileName = "simulated-display-test-manual.pdf"
    static let pageCount = 4
    static let letter = CGSize(width: 612, height: 792)

    /// The sentences on page 4 the walkthrough's answer cites, so the page view marks their lines and
    /// reads them.
    static let citedSentence = "Hold the purge key for five seconds until the amber lamp blinks twice."
    static let followingSentence = "Release the key and wait for the green lamp before closing the cover."

    static var url: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("SimulatedDisplay", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Writes the manual (again) and returns where it is.
    static func write() throws -> URL {
        let url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter))
        try renderer.writePDF(to: url) { context in
            context.beginPage(); blockDiagramPage(context.cgContext)
            context.beginPage(); twoDrawingsPage(context.cgContext)
            context.beginPage(); tablePage(context.cgContext)
            context.beginPage(); textPage(context.cgContext)
        }
        return url
    }

    /// The second sentence page 4's two-passage answer cites.
    static let secondCitedSentence = "Record the lamp colour in the service log before leaving the site."

    /// The table on page 3, in top-down page points: where a pictured table's outline goes.
    static let tableRect = CGRect(x: 54, y: 100, width: 490, height: 168)

    /// A staged page of the manual, as `show_source` would stage it. `cited` cites page 4's
    /// sentence; `citedTwice` cites it and a second one, so the passages are numbered;
    /// `pictured` outlines page 3's table as a pictured table's area.
    static func staged(page: Int, figure: String? = nil, cited: Bool = false, citedTwice: Bool = false,
                       pictured: Bool = false) -> FieldSessionService.StagedFigure {
        var staged = FieldSessionService.StagedFigure(documentId: documentId, documentTitle: title, page: page,
                                                      figure: figure, sourceFile: fileName, origin: .requested)
        if cited {
            staged.citedPassages = [CitedPassage(number: 1, anchor: PassageAnchor(
                documentId: documentId, chunkIndex: 0, text: citedSentence + " " + followingSentence, page: page))]
        }
        if citedTwice {
            staged.citedPassages = [
                CitedPassage(number: 1, anchor: PassageAnchor(documentId: documentId, chunkIndex: 0,
                                                              text: citedSentence, page: page)),
                CitedPassage(number: 2, anchor: PassageAnchor(documentId: documentId, chunkIndex: 1,
                                                              text: secondCitedSentence, page: page)),
            ]
        }
        if pictured {
            staged.pictureAreas = [ManualTable.PictureArea(physical: page, rect: tableRect)]
        }
        return staged
    }

    // MARK: - Pages

    private static func header(_ text: String, page: Int) {
        draw(text, at: CGPoint(x: 54, y: 36), size: 10, weight: .semibold)
        draw("\(page)", at: CGPoint(x: 552, y: 756), size: 9)
    }

    private static func blockDiagramPage(_ cg: CGContext) {
        header(title, page: 1)
        draw("Signal path", at: CGPoint(x: 54, y: 64), size: 16, weight: .bold)
        draw("The board passes the sensor line through four stages before the output relay.",
             at: CGPoint(x: 54, y: 90), size: 10)
        // The diagram: five labelled blocks, arrows between them.
        let blocks: [(CGRect, String, String)] = [
            (CGRect(x: 70, y: 200, width: 110, height: 60), "Intake filter", "F-12"),
            (CGRect(x: 250, y: 200, width: 110, height: 60), "Gain stage", "G-3"),
            (CGRect(x: 430, y: 200, width: 110, height: 60), "Mixer", "MX-8"),
            (CGRect(x: 430, y: 360, width: 110, height: 60), "Output relay", "K-2"),
            (CGRect(x: 250, y: 360, width: 110, height: 60), "Bias supply", "+9 V"),
        ]
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(1.5)
        for (rect, name, code) in blocks {
            cg.stroke(rect)
            draw(name, at: CGPoint(x: rect.minX + 8, y: rect.minY + 12), size: 9, weight: .semibold)
            draw(code, at: CGPoint(x: rect.minX + 8, y: rect.minY + 32), size: 7)
        }
        arrow(cg, from: CGPoint(x: 180, y: 230), to: CGPoint(x: 250, y: 230))
        arrow(cg, from: CGPoint(x: 360, y: 230), to: CGPoint(x: 430, y: 230))
        arrow(cg, from: CGPoint(x: 485, y: 260), to: CGPoint(x: 485, y: 360))
        arrow(cg, from: CGPoint(x: 305, y: 360), to: CGPoint(x: 305, y: 260))
        draw("TP1", at: CGPoint(x: 196, y: 214), size: 6)
        draw("TP2", at: CGPoint(x: 376, y: 214), size: 6)
        draw("TP3", at: CGPoint(x: 492, y: 300), size: 6)
        draw("Figure 1  Signal path of the Q-7 board", at: CGPoint(x: 160, y: 450), size: 9, weight: .semibold)
        paragraph("Measure each test point with the board powered and the cover off. A reading outside the band in Table 1 points to the stage before it.",
                  in: CGRect(x: 54, y: 500, width: 504, height: 60))
    }

    private static func twoDrawingsPage(_ cg: CGContext) {
        header(title, page: 2)
        draw("Terminal layouts", at: CGPoint(x: 54, y: 64), size: 16, weight: .bold)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(1.5)
        // The top drawing: a coil loop with two taps.
        cg.strokeEllipse(in: CGRect(x: 200, y: 120, width: 200, height: 160))
        cg.strokeEllipse(in: CGRect(x: 250, y: 160, width: 100, height: 80))
        cg.move(to: CGPoint(x: 200, y: 200)); cg.addLine(to: CGPoint(x: 140, y: 200))
        cg.move(to: CGPoint(x: 400, y: 200)); cg.addLine(to: CGPoint(x: 460, y: 200))
        cg.strokePath()
        draw("T1", at: CGPoint(x: 120, y: 192), size: 8)
        draw("T2", at: CGPoint(x: 466, y: 192), size: 8)
        draw("Sense coil", at: CGPoint(x: 272, y: 194), size: 7)
        // The bottom drawing: a terminal strip with three screws.
        let strip = CGRect(x: 160, y: 470, width: 290, height: 90)
        cg.stroke(strip)
        for (index, name) in ["A", "B", "C"].enumerated() {
            let x = strip.minX + 45 + CGFloat(index) * 95
            cg.strokeEllipse(in: CGRect(x: x, y: strip.minY + 25, width: 34, height: 34))
            cg.move(to: CGPoint(x: x + 6, y: strip.minY + 42)); cg.addLine(to: CGPoint(x: x + 28, y: strip.minY + 42))
            cg.strokePath()
            draw(name, at: CGPoint(x: x + 13, y: strip.maxY + 8), size: 8)
        }
        draw("Line", at: CGPoint(x: 200, y: 448), size: 7)
        draw("Load", at: CGPoint(x: 395, y: 448), size: 7)
    }

    private static func tablePage(_ cg: CGContext) {
        header(title, page: 3)
        draw("Table 1  Test point bands", at: CGPoint(x: 54, y: 64), size: 14, weight: .bold)
        let rows = [["Point", "Stage", "Low", "High", "Lamp"],
                    ["TP1", "Intake filter", "0.4 V", "0.9 V", "Green"],
                    ["TP2", "Gain stage", "2.1 V", "2.6 V", "Green"],
                    ["TP3", "Mixer", "4.0 V", "4.8 V", "Amber"],
                    ["TP4", "Output relay", "8.6 V", "9.2 V", "Amber"],
                    ["TP5", "Bias supply", "8.8 V", "9.1 V", "Red"]]
        let widths: [CGFloat] = [70, 150, 90, 90, 90]
        let origin = CGPoint(x: 54, y: 100)
        let rowHeight: CGFloat = 28
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(1)
        for (r, row) in rows.enumerated() {
            var x = origin.x
            let y = origin.y + CGFloat(r) * rowHeight
            for (c, cell) in row.enumerated() {
                cg.stroke(CGRect(x: x, y: y, width: widths[c], height: rowHeight))
                draw(cell, at: CGPoint(x: x + 6, y: y + 8), size: 9, weight: r == 0 ? .semibold : .regular)
                x += widths[c]
            }
        }
        paragraph("A lamp that stays red after a purge means the bias supply is outside its band.",
                  in: CGRect(x: 54, y: 300, width: 504, height: 40))
    }

    private static func textPage(_ cg: CGContext) {
        header(title, page: 4)
        draw("Clearing a latched fault", at: CGPoint(x: 54, y: 64), size: 16, weight: .bold)
        let text = [
            "The Q-7 board latches a fault when any test point stays outside its band for more than ten seconds. The amber lamp then stays lit and the output relay opens.",
            "Before clearing the fault, check the sensor line at the intake filter and confirm the cover switch is closed. A fault that latches again within a minute is not cleared by a purge.",
            citedSentence + " " + followingSentence,
            "If the lamp does not change, remove power for thirty seconds and repeat the purge once. " + secondCitedSentence,
        ]
        var y: CGFloat = 100
        for block in text {
            paragraph(block, in: CGRect(x: 54, y: y, width: 504, height: 80))
            y += 84
        }
    }

    // MARK: - Drawing

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: UIColor.black,
        ])
    }

    private static func paragraph(_ text: String, in rect: CGRect) {
        (text as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black,
        ])
    }

    private static func arrow(_ cg: CGContext, from start: CGPoint, to end: CGPoint) {
        cg.move(to: start)
        cg.addLine(to: end)
        cg.strokePath()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 8
        for side in [-0.45, 0.45] {
            cg.move(to: end)
            cg.addLine(to: CGPoint(x: end.x - head * cos(angle + side), y: end.y - head * sin(angle + side)))
        }
        cg.strokePath()
    }
}
#endif
