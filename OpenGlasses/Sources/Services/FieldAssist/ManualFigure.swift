import Foundation
import PDFKit
import UIKit

/// Everything the staged figure (Plan EK P2) does once it exists: whether it goes to the model as
/// this turn's picture, how that page is rendered, what the lens says, and what the phone shows.
///
/// Deliberately free of the LLM service and of SwiftUI. The decision is a function of four facts,
/// the render is a function of a file and a page number, and the sheet's content is a function of
/// a staged figure — so all three are provable headlessly, which is the only test a wiring diagram
/// on a technician's phone is going to get before it is in front of one.

// MARK: - Does the figure go to the model?

/// Whether this turn's single image slot carries a manual page.
enum ManualFigureAttachment {

    /// Why a turn is not carrying a figure. Named rather than boolean because each reason is a
    /// different product answer: the camera one is correct behaviour, the on-device one is a
    /// policy, and the missing-page one is the Markdown route's honest limit.
    enum Skipped: String, Equatable {
        /// Nothing staged for this turn.
        case noFigure
        /// The technician is pointing the camera at something; that frame wins the slot.
        case cameraFrame
        /// An on-device model. They run in the foreground only and vision costs them dearly, so a
        /// rendered page is never handed to one as a matter of course.
        case onDevice
        /// The document was imported as text, so there is no page to render.
        case noSourcePage
    }

    enum Decision: Equatable {
        case attach(source: URL, page: Int)
        case skip(Skipped)

        var attachedPage: Int? {
            if case .attach(_, let page) = self { return page }
            return nil
        }
    }

    /// The whole rule, over the four facts that decide it. `sourceURL` is the vault baseline PDF
    /// the figure's page comes from, already resolved (and existence-checked) by the session.
    static func decide(staged: FieldSessionService.StagedFigure?,
                       sourceURL: URL?,
                       hasCameraImage: Bool,
                       isOnDevice: Bool) -> Decision {
        guard let staged else { return .skip(.noFigure) }
        if hasCameraImage { return .skip(.cameraFrame) }
        if isOnDevice { return .skip(.onDevice) }
        guard let sourceURL, staged.hasSourcePage else { return .skip(.noSourcePage) }
        return .attach(source: sourceURL, page: staged.page)
    }

    /// What the prompt says about the attached page. The first sentence is the one the plan
    /// specifies; the rest keeps the model from reading a manual page as a camera photo, which is
    /// what the vision block above it would otherwise have told it.
    static func promptLine(for staged: FieldSessionService.StagedFigure) -> String {
        let name = staged.figure.flatMap { $0.isEmpty ? nil : $0 } ?? "The drawing"
        return """
        MANUAL FIGURE: \(name) (page \(staged.page)) is attached as this turn's image. \
        It is a page of \(staged.documentTitle), not a camera photo — read the drawing and answer \
        from it, citing "\(staged.citation)". The technician has the same page on their phone.
        """
    }

    // MARK: - Rendering

    /// Render resolution for a manual page. 150 dpi puts a letter page at about 1275 × 1650 —
    /// inside `LLMImagePreparer`'s long-edge ceiling, so the page reaches the model without being
    /// downscaled again, and small enough that the encoded JPEG is a fraction of the byte cap.
    /// Terminal labels on a wiring diagram are 8 pt; below about 120 dpi they stop being readable.
    static let renderDPI = 150
    /// Hard pixel bound, so a poster-sized foldout drawing cannot allocate an absurd bitmap.
    static let maxPixels = 2200

    /// Render one page of a PDF and bound it for the wire. Off the main actor, one page, once —
    /// the document is opened inside the task, so no PDFKit object crosses an isolation boundary.
    ///
    /// `page` is the **printed** page number, which is what a citation names and what the
    /// extractor verified against the physical page at import. Out-of-range asks return nil rather
    /// than the nearest page: sending the wrong drawing is worse than sending none.
    static func render(source: URL, page: Int) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let document = PDFDocument(url: source), page >= 1, page <= document.pageCount,
                  let pdfPage = document.page(at: page - 1),
                  let image = PDFPageRasterizer.image(for: pdfPage, dpi: renderDPI, maxPixels: maxPixels),
                  let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }
            return LLMImagePreparer.prepared(jpeg)
        }.value
    }
}

// MARK: - What the lens says

/// The one line the in-lens display gets when a figure is staged. A lens display cannot make a
/// wiring diagram legible — the HUD screen model has no image type and would not help if it did —
/// so the lens says where the drawing is and nothing else.
enum ManualFigureCue {

    /// "Figure 58, page 44, on your phone".
    static func line(for staged: FieldSessionService.StagedFigure) -> String {
        let name = staged.figure.flatMap { $0.isEmpty ? nil : $0 } ?? "Drawing"
        return "\(name), page \(staged.page), on your phone"
    }

    /// Flash the cue over whatever the HUD is showing, replacing nothing persistent. A no-op when
    /// the wearer has no display, which the service itself decides.
    @MainActor
    static func show(_ staged: FieldSessionService.StagedFigure, on display: GlassesDisplayService) {
        display.showNotification(title: nil, body: line(for: staged), icon: .info, duration: 6)
    }
}

// MARK: - What the phone shows

/// What the figure sheet draws for a staged figure, decided without SwiftUI so both states are
/// provable. The PDF route hands the sheet the source file and a page index for PDFKit's own
/// viewer — zoom, the real page, and no re-rendering; the Markdown route has no page at all and
/// says so, with the citation still in front of the technician so they can turn to it themselves.
struct ManualFigurePresenter: Equatable {

    enum Content: Equatable {
        /// PDFKit opens `source` at `pageIndex` (zero-based).
        case page(source: URL, pageIndex: Int)
        /// No page to show; the document was imported as text.
        case unavailable
    }

    let figure: FieldSessionService.StagedFigure
    let content: Content

    /// The sheet's title — the same citation the model was told to use.
    var citation: String { figure.citation }

    var hasPicture: Bool {
        if case .page = content { return true }
        return false
    }

    init(figure: FieldSessionService.StagedFigure, sourceURL: URL?) {
        self.figure = figure
        if let sourceURL, figure.hasSourcePage, figure.page >= 1 {
            content = .page(source: sourceURL, pageIndex: figure.page - 1)
        } else {
            content = .unavailable
        }
    }

    /// Build the presenter for what the session has staged, recording in the audit log that this
    /// figure was put in front of the technician. Nil when nothing is staged.
    @MainActor
    static func present(_ figure: FieldSessionService.StagedFigure,
                        session: FieldSessionService) -> ManualFigurePresenter {
        let presenter = ManualFigurePresenter(figure: figure, sourceURL: session.sourcePDFURL(for: figure))
        session.logFigureShown(figure, asPicture: presenter.hasPicture)
        return presenter
    }
}
