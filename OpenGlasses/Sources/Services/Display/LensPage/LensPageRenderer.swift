import CoreGraphics
import Foundation
import PDFKit
import UIKit

// Plan KV §2 / P1 — the page as the lens draws it. The decisions are `LensPageRenderPlan`'s; this
// file opens the PDF, rasterises the crop, runs the plan's tone over the pixels and strokes the
// rectangles it placed. Everything here runs off the main actor, and no PDFKit object leaves the
// task that opened its document.

/// What the lens needs to know about one staged page before it can draw it: where to read it, and
/// what is marked on it. Plain values, so it crosses into a detached task.
struct LensPageRequest: Equatable {
    let source: URL
    /// The printed page (`StagedFigure.page`); the PDF page index is one less.
    let page: Int
    let citedPassages: [CitedPassage]
    let pictureAreas: [ManualTable.PictureArea]
    let tone: LensPageRenderPlan.Tone
    /// What the request said about the drawing it wants (Plan KV P1b).
    let ask: PageFigureAsk
    /// The page's key in `PageFigureCache` (document, page, revision, file); nil analyses the page
    /// every time it is laid out.
    let figureKey: String?

    var pageIndex: Int { page - 1 }

    init(source: URL, page: Int, citedPassages: [CitedPassage] = [],
         pictureAreas: [ManualTable.PictureArea] = [], tone: LensPageRenderPlan.Tone = .lineArt,
         ask: PageFigureAsk = .none, figureKey: String? = nil) {
        self.source = source
        self.page = page
        self.citedPassages = citedPassages
        self.pictureAreas = pictureAreas
        self.tone = tone
        self.ask = ask
        self.figureKey = figureKey
    }

    init(staged: FieldSessionService.StagedFigure, source: URL, ask: PageFigureAsk = .none) {
        self.init(source: source, page: staged.page, citedPassages: staged.citedPassages,
                  pictureAreas: staged.pictureAreas,
                  tone: ManualFigureCue.isPhotographed(staged) ? .photographed : .lineArt,
                  ask: ask,
                  figureKey: PageFigureCache.key(documentId: staged.documentId, page: staged.page,
                                                 sourceRevision: staged.sourceRevision,
                                                 sourceFile: staged.sourceFile))
    }
}

/// One page laid out for the lens: its size, its marks as rectangles, its drawings, where the view
/// opens, how legible its text is, and — for a cited text passage — its words to read. Pure once
/// made.
struct LensPageLayout: Equatable {
    let pageSize: CGSize
    let marks: LensPageMarks?
    /// The pictured table's outlined areas on this page, in top-down page points.
    let pictureAreas: [CGRect]
    let tone: LensPageRenderPlan.Tone
    /// The page's drawings, in reading order (Plan KV P1b); empty where none were found.
    let drawings: [PageDrawing]
    /// The drawing `PageFigureChoice` chose, when there is one.
    let figureIndex: Int?
    let focus: LensPageFocus
    let legibility: LensLegibility
    /// The cited passages' own words, when the view opens on a cited text passage (reading mode,
    /// `LensPageReading`); nil when it opens on anything else.
    let reading: LensPageReading?

    /// `figure` is a known drawing's rectangle; without one, the chosen drawing's (`figureIndex`
    /// into `drawings`). `drawingFocus` says where the drawing stands in the order (§1): ahead of
    /// the cited passages (`.first`), after them (`.afterMarks`), or not a focus at all (`.none`,
    /// a request for the page: the drawings are still kept for **Next diagram ›**). `reading` is
    /// kept only when the view opens on the cited passages.
    init(pageSize: CGSize, marks: LensPageMarks?, pictureAreas: [CGRect],
         tone: LensPageRenderPlan.Tone, figure: CGRect? = nil,
         drawings: [PageDrawing] = [], figureIndex: Int? = nil,
         drawingFocus: PageFigureAsk.DrawingFocus = .afterMarks,
         reading: LensPageReading? = nil) {
        self.pageSize = pageSize
        self.marks = marks.flatMap { $0.isEmpty ? nil : $0 }
        self.pictureAreas = pictureAreas
        self.tone = tone
        self.drawings = drawings
        let chosen = figureIndex.flatMap { drawings.indices.contains($0) ? $0 : nil }
        self.figureIndex = chosen
        let drawing = drawingFocus == .none ? nil : (figure ?? chosen.map { drawings[$0].rect })
        focus = LensPageFocus.pick(pageSize: pageSize, passageRects: self.marks?.marks.map(\.bounds) ?? [],
                                   pictureAreas: pictureAreas, figure: drawing,
                                   figureFirst: drawingFocus == .first)
        if focus.source == .figure, let chosen {
            legibility = Self.legibility(of: drawings[chosen])
        } else {
            legibility = LensLegibility(lineRects: self.marks?.lineRects ?? [])
        }
        self.reading = focus.source == .citedPassages && pictureAreas.isEmpty && tone == .lineArt ? reading : nil
    }

    /// The view's opening viewport, for its first frame (the citation line over it).
    var openingViewport: LensPageViewport {
        Self.viewport(opening: focus, legibility: legibility, citation: true)
    }

    /// The drawing the view opened on, when it opened on one.
    var openingDrawing: Int? { focus.source == .figure ? figureIndex : nil }

    /// The view opened on drawing `index` (**Next diagram ›**, "the bottom one"), on a later frame.
    func viewport(onDrawing index: Int) -> LensPageViewport? {
        guard drawings.indices.contains(index) else { return nil }
        return Self.viewport(opening: LensPageFocus.pick(pageSize: pageSize, figure: drawings[index].rect),
                             legibility: Self.legibility(of: drawings[index]), citation: false)
    }

    /// The picture opened on passage `number`'s mark (reading mode's **Page**), on a later frame;
    /// all the marks when that one isn't on the page.
    func viewport(onPassage number: Int?) -> LensPageViewport {
        let mark = marks?.marks.first { $0.number == number }
        let rects = mark.map { [$0.bounds] } ?? marks?.marks.map(\.bounds) ?? []
        let lines = mark?.lineRects ?? marks?.lineRects ?? []
        return Self.viewport(opening: LensPageFocus.pick(pageSize: pageSize, passageRects: rects),
                             legibility: LensLegibility(lineRects: lines), citation: false)
    }

    /// `focus` fitted exactly into the box its frame leaves the picture: the citation line on the
    /// first frame, and the hint when the opening needs it (`HUDPageViewState.showsZoomHint`).
    static func viewport(opening focus: LensPageFocus, legibility: LensLegibility,
                         citation: Bool) -> LensPageViewport {
        let plain = LensPageViewport(opening: focus, box: LensPageFrame.pictureBox(citation: citation, hint: false))
        guard HUDPageViewState.needsZoomHint(plain, legibility: legibility, citation: citation) else { return plain }
        return LensPageViewport(opening: focus, box: LensPageFrame.pictureBox(citation: citation, hint: true))
    }

    /// A drawing's legibility: its labels' height, or the default for a drawing's labels.
    static func legibility(of drawing: PageDrawing) -> LensLegibility {
        LensLegibility(lineRects: drawing.labels.map(\.rect))
    }
}

enum LensPageRenderer {

    // MARK: - Laying out

    /// Open the page and lay it out, off the main actor. Nil when the page can't be opened.
    static func layout(_ request: LensPageRequest) async -> LensPageLayout? {
        await Task.detached(priority: .userInitiated) { () -> LensPageLayout? in
            guard let document = PDFDocument(url: request.source),
                  let page = pdfPage(document, index: request.pageIndex) else { return nil }
            return layout(page, request: request)
        }.value
    }

    /// The synchronous half, for a page already open.
    static func layout(_ page: PDFPage, request: LensPageRequest) -> LensPageLayout {
        let geometry = PDFKitPageTextGeometry(page: page)
        let marks: LensPageMarks?
        if request.citedPassages.isEmpty {
            marks = nil
        } else {
            let passageMarks = PassageMarks(passages: request.citedPassages, page: request.page,
                                            pageText: page.string)
            marks = LensPageMarks(passageMarks, geometry: geometry)
        }
        let areas = request.pictureAreas.filter { $0.physical == request.page }.map(\.rect)
        let choice = figureChoice(page, request: request)
        return LensPageLayout(pageSize: geometry.pageSize, marks: marks, pictureAreas: areas, tone: request.tone,
                              drawings: choice.drawings, figureIndex: choice.index,
                              drawingFocus: request.ask.drawingFocus,
                              reading: reading(page, request: request))
    }

    /// The cited text passages' own words on the page, for reading mode (Plan KV §1): nil for a
    /// photographed page, a pictured table, or a page whose cited passages include a table row
    /// (located by its printed runs, so its words are a row of cells): those keep the picture.
    static func reading(_ page: PDFPage, request: LensPageRequest) -> LensPageReading? {
        guard request.tone == .lineArt,
              !request.pictureAreas.contains(where: { $0.physical == request.page }) else { return nil }
        let onPage = request.citedPassages.filter { $0.anchor.covers(request.page) }
        guard !onPage.isEmpty, onPage.allSatisfy({ $0.anchor.printedRuns.isEmpty }) else { return nil }
        let text = page.string
        let marks = PassageMarks(passages: request.citedPassages, page: request.page, pageText: text)
        return LensPageReading(marks, pageText: text)
    }

    /// The page's drawings and the one the request means (Plan KV P1b). A photographed page has no
    /// text layer to blank out, so it finds none and opens as before.
    static func figureChoice(_ page: PDFPage, request: LensPageRequest,
                             cache: PageFigureCache = .shared) -> PageFigureChoice {
        guard request.tone == .lineArt else { return PageFigureChoice.choose([], ask: request.ask) }
        let drawings: [PageDrawing]
        if let key = request.figureKey {
            drawings = cache.drawings(for: key) { PageFigureAnalysis.drawings(on: page) }
        } else {
            drawings = PageFigureAnalysis.drawings(on: page)
        }
        let captions = drawings.count > 1
            ? request.ask.captionNumber.map { PageFigureAnalysis.captionRects(number: $0, on: page) } ?? []
            : []
        return PageFigureChoice.choose(drawings, ask: request.ask, captionRects: captions)
    }

    // MARK: - Drawing

    /// Draw `plan` from the request's page, off the main actor.
    static func render(_ request: LensPageRequest, plan: LensPageRenderPlan) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let document = PDFDocument(url: request.source),
                  let page = pdfPage(document, index: request.pageIndex) else { return nil }
            return draw(page, plan: plan)
        }.value
    }

    /// The accent the marks are drawn in: the AI accent's value for a dark ground, since the lens
    /// is one (`AccentColors.aiAccentDarkHex`, #E77F47).
    static var accent: CGColor {
        let hex = AccentColors.aiAccentDarkHex
        return CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Rasterise the crop at the plan's size, turn its tones for the lens, and draw the marks and
    /// the position frame. Synchronous; the caller is off the main actor.
    static func draw(_ page: PDFPage, plan: LensPageRenderPlan) -> UIImage? {
        let width = Int(plan.outputSize.width.rounded())
        let height = Int(plan.outputSize.height.rounded())
        guard width > 0, height > 0, plan.scale > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }

        // Paper everywhere first: the part of the crop past the page is paper too, so it turns
        // black (clear on the lens) with the rest.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Page space (origin at the media box's bottom left, y up) onto output pixels (origin at
        // the bottom left in Core Graphics): x' = (x − box.minX − crop.minX)·s and
        // y' = h − (box.maxY − y − crop.minY)·s.
        let box = page.bounds(for: .mediaBox)
        let s = plan.scale
        context.saveGState()
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.translateBy(x: -(box.minX + plan.crop.minX) * s,
                            y: CGFloat(height) - (box.maxY - plan.crop.minY) * s)
        context.scaleBy(x: s, y: s)
        if let reference = page.pageRef {
            // The page's content only: none of the app's or anyone's annotations.
            context.drawPDFPage(reference)
        } else {
            context.translateBy(x: box.minX, y: box.minY)
            page.draw(with: .mediaBox, to: context)
        }
        context.restoreGState()

        applyTone(plan.tone, to: context, width: width, height: height, page: plan.pageInOutput)
        drawOverlays(plan, in: context, height: height)

        guard let image = context.makeImage() else { return nil }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    /// Run every pixel through the plan's tone: a photographed page stretched to full range first
    /// (its levels read from the page alone, not the paper-white margin past it), then lightness
    /// inverted with the hue kept.
    private static func applyTone(_ tone: LensPageRenderPlan.Tone, to context: CGContext, width: Int, height: Int,
                                  page: CGRect) {
        guard let base = context.data else { return }
        let count = width * height
        let pixels = base.bindMemory(to: UInt8.self, capacity: count * 4)
        var levels: (black: UInt8, white: UInt8) = (0, 255)
        if tone == .photographed {
            var histogram = [Int](repeating: 0, count: 256)
            let area = page.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !area.isNull, area.width > 0, area.height > 0 {
                // The bitmap's rows run top down, as the plan's output coordinates do.
                for y in Int(area.minY)..<Int(area.maxY) {
                    for x in Int(area.minX)..<Int(area.maxX) {
                        let p = (y * width + x) * 4
                        histogram[Int(LensPageRenderPlan.luma(pixels[p], pixels[p + 1], pixels[p + 2]))] += 1
                    }
                }
            }
            levels = LensPageRenderPlan.stretchLevels(histogram: histogram)
        }
        let stretches = levels.black > 0 || levels.white < 255
        for index in 0..<count {
            let p = index * 4
            var r = pixels[p], g = pixels[p + 1], b = pixels[p + 2]
            if stretches {
                r = LensPageRenderPlan.stretch(r, black: levels.black, white: levels.white)
                g = LensPageRenderPlan.stretch(g, black: levels.black, white: levels.white)
                b = LensPageRenderPlan.stretch(b, black: levels.black, white: levels.white)
            }
            let turned = LensPageRenderPlan.invertLightness(r, g, b)
            pixels[p] = turned.0
            pixels[p + 1] = turned.1
            pixels[p + 2] = turned.2
            pixels[p + 3] = 255
        }
    }

    /// The marks and the position frame, in the plan's top-down output pixels.
    private static func drawOverlays(_ plan: LensPageRenderPlan, in context: CGContext, height: Int) {
        guard !plan.marks.isEmpty || plan.positionFrame != nil else { return }
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer {
            UIGraphicsPopContext()
            context.restoreGState()
        }

        let accent = Self.accent
        context.setStrokeColor(accent)
        context.setLineWidth(3)
        for mark in plan.marks {
            context.stroke(mark.rect)
            if let number = mark.number {
                let label = "\(number)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: UIColor(cgColor: accent),
                ]
                let size = label.size(withAttributes: attributes)
                let y = mark.rect.minY - size.height - 2 >= 0 ? mark.rect.minY - size.height - 2 : mark.rect.maxY + 2
                label.draw(at: CGPoint(x: max(0, mark.rect.minX), y: y), withAttributes: attributes)
            }
        }

        if let frame = plan.positionFrame {
            // The page's outline dim, the crop in the accent: a map, not a second picture.
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(frame.page)
            context.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1))
            context.setLineWidth(1.5)
            context.stroke(frame.page)
            context.setStrokeColor(accent)
            context.setLineWidth(2)
            context.stroke(frame.crop)
        }
    }

    private static func pdfPage(_ document: PDFDocument, index: Int) -> PDFPage? {
        guard index >= 0, index < document.pageCount else { return nil }
        return document.page(at: index)
    }
}

/// The lens pictures already drawn, keyed by the page's identity and the crop (§2). Least recently
/// used goes first. In memory only; nothing is written down.
@MainActor
final class LensPageRenderCache {
    nonisolated static let defaultCapacity = 12

    let capacity: Int
    private var pictures: [String: HUDPicture] = [:]
    private var order: [String] = []

    init(capacity: Int = LensPageRenderCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { pictures.count }
    func contains(_ key: String) -> Bool { pictures[key] != nil }

    func picture(for key: String) -> HUDPicture? {
        guard let picture = pictures[key] else { return nil }
        touch(key)
        return picture
    }

    func store(_ picture: HUDPicture, for key: String) {
        pictures[key] = picture
        touch(key)
        while order.count > capacity {
            pictures[order.removeFirst()] = nil
        }
    }

    func removeAll() {
        pictures = [:]
        order = []
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// What a picture shows: the page (`identity`), the crop to half a point, and how it is drawn.
    /// Also the picture's `contentKey`, so the render queue skips a frame it already sent.
    static func key(identity: String, plan: LensPageRenderPlan) -> String {
        func half(_ value: CGFloat) -> String {
            let rounded = (value * 2).rounded() / 2
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", Double(rounded))
        }
        let crop = plan.crop
        return "\(identity)@\(half(crop.minX)),\(half(crop.minY)),\(half(crop.width)),\(half(crop.height))"
            + ":\(plan.tone.rawValue):\(Int(plan.outputSize.width))x\(Int(plan.outputSize.height))"
    }
}
