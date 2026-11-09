import PDFKit
import SwiftUI

/// The manual page, on the technician's phone (Plan EK P2, opened by any citation in P3).
///
/// Speech cannot read a drawing back and the lens cannot render one legibly, so this is where the
/// technician actually sees the page an answer came from. Two routes, one sheet: the manufacturer's
/// own PDF in PDFKit's viewer when the vault holds it, and the text the importer extracted when it
/// does not — with a header that says which of the two is on screen and, for the manufacturer's
/// file, whether it is still the file that was imported.
///
/// What is drawn, how it pages and what is written to the audit log is decided by
/// `ManualPageSheetModel` / `ManualPageController`, which are tested without a screen.
struct ManualFigureSheet: View {
    let request: AppState.ManualFigureRequest
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var presentation: ManualFigurePresentation
    /// Which of the request's pages is up, when "show me the relevant pages" opened several
    /// (Plan IN P2). Each page gets its own controller, so its audit trail is its own.

    var body: some View {
        let stops = request.stops
        let index = presentation.index(for: request)
        ManualSourcePage(stop: stops[index], position: stops.count > 1 ? (index + 1, stops.count) : nil,
                         onPreviousSource: { presentation.select(index - 1, in: request) },
                         onNextSource: { presentation.select(index + 1, in: request) },
                         controller: presentation.controller(for: request, at: index),
                         onClose: onClose)
            .id("\(request.id):\(index)")
    }
}

/// The cited manual page, opened in place under the answer on the Voice tab rather than over it in
/// a sheet. The same page — its own header, paging and Close — on a card the feed scrolls with.
struct InlineManualPage: View {
    let request: AppState.ManualFigureRequest
    let height: CGFloat
    let onClose: () -> Void

    var body: some View {
        ManualFigureSheet(request: request, onClose: onClose)
            .frame(height: height)
            .background(OGTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator, lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Manual page")
    }
}

/// One cited page in the sheet.
private struct ManualSourcePage: View {
    let stop: AppState.ManualFigureRequest.Stop
    /// "2 of 3" when the sheet holds several pages.
    let position: (current: Int, count: Int)?
    let onPreviousSource: () -> Void
    let onNextSource: () -> Void
    @ObservedObject var controller: ManualPageController
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// What marking the PDF page on screen came to, reported by the viewer (Plan IN P1).
    @State private var pdfMarks: PassageMarks?
    @State private var pdfPageText: String?

    private var model: ManualPageSheetModel { controller.model }

    /// The marks for whatever is on screen, on either route.
    private var marks: PassageMarks? {
        model.route == .manufacturerPDF ? pdfMarks : model.currentTextMarks
    }

    private var markedText: String? {
        model.route == .manufacturerPDF ? pdfPageText : model.currentText
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // VoiceOver reads the highlighted passage first, then the page (Plan IN P1).
                if let spoken = marks?.spokenPassages(in: markedText) {
                    Color.clear
                        .frame(height: 0)
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: spoken))
                        .accessibilitySortPriority(2)
                }
                if let position { sourceStepper(position) }
                header
                Divider()
                content
            }
            .navigationTitle(Text(verbatim: model.hasContent ? model.paging.title : model.citation))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .bottomBar) { bottomControls }
            }
            .task { await controller.open() }
            .onDisappear { controller.close() }
        }
    }

    // MARK: - Header

    /// What the technician is looking at, in words they can put in a report: whose document, which
    /// page, and whether it is unchanged since the vault imported it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: model.headerLine)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(model.integrity == .changed ? OGTheme.warnLabel : Color.primary)
            Text(verbatim: model.citation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let original = model.originalLine {
                Text(verbatim: original)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let pictured = model.pictureLine {
                Text(verbatim: pictured)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Decision 3: a passage that could not be found is said, never guessed at.
            if let unmarked = marks?.unmarkedLine {
                Text(verbatim: unmarked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OGTheme.card)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.route {
        case .manufacturerPDF where model.manufacturerPDF != nil:
            ManualPDFPageView(source: model.manufacturerPDF!,
                              pageIndex: model.paging.currentPage - 1,
                              passages: model.citedPassages,
                              pictureAreas: model.pictureAreas,
                              onPageChanged: { controller.viewerMoved(to: $0 + 1) },
                              onMarked: { marks, text in
                                  pdfMarks = marks
                                  pdfPageText = text
                              })
                .ignoresSafeArea(edges: .bottom)
        case .extractedText where !model.extractedPages.isEmpty:
            extractedText
        default:
            unavailable
        }
    }

    /// The stored text of one printed page, rendered rather than dumped: the vault's manuals are
    /// headings and pipe tables, and a table read as a paragraph loses the column that answers the
    /// question.
    private var extractedText: some View {
        ScrollView {
            Group {
                let marks = model.currentTextMarks
                if let text = model.currentText, !marks.located.isEmpty {
                    // The same passages the PDF route marks, marked in the stored text. Plain
                    // rather than rendered: the marks are ranges in this exact string.
                    Text(Self.highlighted(text, marks: marks))
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    MessageContentView(text: model.currentText ?? "")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OGTheme.canvas)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < 0 { controller.next() } else { controller.previous() }
                }
        )
    }

    /// The stored page text with the located passages on the design kit's highlight.
    private static func highlighted(_ text: String, marks: PassageMarks) -> AttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let wash = UIColor(OGTheme.Token.passageHighlight.color).withAlphaComponent(OGTheme.Opacity.passageHighlight)
        for mark in marks.located {
            for range in mark.location.ranges where NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(.backgroundColor, value: wash, range: range)
            }
        }
        return (try? AttributedString(attributed, including: \.uiKit)) ?? AttributedString(text)
    }

    /// Moves between the pages "show me the relevant pages" opened.
    private func sourceStepper(_ position: (current: Int, count: Int)) -> some View {
        HStack {
            Button(action: onPreviousSource) { Image(systemName: "chevron.backward") }
                .disabled(position.current <= 1)
                .accessibilityLabel("Previous source")
            Spacer()
            Text("Source \(position.current) of \(position.count)")
                .font(.footnote.weight(.semibold))
            Spacer()
            Button(action: onNextSource) { Image(systemName: "chevron.forward") }
                .disabled(position.current >= position.count)
                .accessibilityLabel("Next source")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(OGTheme.card)
    }

    /// Neither the manufacturer's page nor stored text — the honest limit, with what to change so
    /// the next job does not hit it.
    private var unavailable: some View {
        OGScrollPage {
            OGCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: model.citation)
                        .font(.headline)
                    Text("This manual was imported as extracted text, so there is no page to show. The citation still names where to find it in the printed book.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            OGNotice(text: "Import the manual as a PDF, or bundle the original beside the extracted text, to see its pages here.",
                     systemImage: "doc.richtext")
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var bottomControls: some View {
        HStack(spacing: 14) {
            if model.route == .extractedText, !model.extractedPages.isEmpty {
                Button { controller.previous() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.paging.canGoBack)
                    .accessibilityLabel("Previous page")
                Button { controller.next() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!model.paging.canGoForward)
                    .accessibilityLabel("Next page")
            }
            if model.paging.isAwayFromCitedPage, model.hasContent {
                Button { controller.returnToCitedPage() } label: {
                    Label("Back to cited page", systemImage: "arrow.uturn.backward")
                        .font(.footnote)
                }
            }
            Spacer(minLength: 0)
            // The only way a page becomes "verified" on the record by touch: the technician says
            // it checked out. The sheet appearing verifies nothing (Plan GB P1).
            if model.hasContent {
                Button { controller.confirmChecked() } label: {
                    Label(controller.currentPageConfirmed ? "Checked" : "Checked against manual",
                          systemImage: controller.currentPageConfirmed
                              ? "checkmark.seal.fill" : "checkmark.seal")
                        .font(.footnote)
                }
                .disabled(controller.currentPageConfirmed)
            }
            if model.canOpenOriginal {
                Button { Task { await controller.openOriginal() } } label: {
                    Label("Open manufacturer's page", systemImage: "doc.richtext")
                        .font(.footnote)
                }
            }
            if model.publishedURL != nil {
                Button {
                    if let url = controller.openPublished() { openURL(url) }
                } label: {
                    Label("Manufacturer's published manual", systemImage: "safari")
                        .font(.footnote)
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Manufacturer's published manual")
            }
        }
    }
}

/// PDFKit's viewer, opened on one page and paged by swipe. `usePageViewController` gives the
/// horizontal, page-at-a-time gesture a technician expects from a manual while keeping the zoom
/// that makes 8-point terminal labels readable; a continuous scroll would let a stray swipe drift
/// off the drawing.
private struct ManualPDFPageView: UIViewRepresentable {
    let source: URL
    let pageIndex: Int
    /// Cited passages to mark wherever they are found (Plan IN P1).
    var passages: [CitedPassage] = []
    /// Regions a table was read from a picture in, outlined on their pages (Plan JN P2).
    var pictureAreas: [ManualTable.PictureArea] = []
    var onPageChanged: (Int) -> Void = { _ in }
    /// What marking the page on screen came to, and that page's text, for the header's line and
    /// for VoiceOver.
    var onMarked: (PassageMarks, String?) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, passages: passages, pictureAreas: pictureAreas, onMarked: onMarked)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: source)
        goToPage(view)
        context.coordinator.observe(view)
        context.coordinator.markCurrentPage(scrolling: true)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onMarked = onMarked
        // Plan JW P0: new marks on the page already marked are drawn, not skipped. The coordinator
        // marks a page once (`markedPage`), so marks handed to a viewer that stays up used to be
        // kept aside while the page went on showing the previous answer's.
        let remark = context.coordinator.passages != passages || context.coordinator.pictureAreas != pictureAreas
        context.coordinator.passages = passages
        context.coordinator.pictureAreas = pictureAreas
        if view.document?.documentURL != source {
            view.document = PDFDocument(url: source)
        }
        goToPage(view)
        if remark { context.coordinator.remarkCurrentPage() }
    }

    private func goToPage(_ view: PDFView) {
        guard let document = view.document, pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        guard view.currentPage != page else { return }
        view.go(to: page)
    }

    /// Reports the page the viewer landed on, so the model — and the audit log — follow the
    /// technician's swipes rather than only the app's own jumps.
    final class Coordinator: NSObject {
        var onPageChanged: (Int) -> Void
        var passages: [CitedPassage]
        var pictureAreas: [ManualTable.PictureArea]
        var onMarked: (PassageMarks, String?) -> Void
        private weak var view: PDFView?
        /// The page last marked, so a redraw does not mark it again.
        private var markedPage: PDFPage?

        init(onPageChanged: @escaping (Int) -> Void, passages: [CitedPassage],
             pictureAreas: [ManualTable.PictureArea], onMarked: @escaping (PassageMarks, String?) -> Void) {
            self.onPageChanged = onPageChanged
            self.passages = passages
            self.pictureAreas = pictureAreas
            self.onMarked = onMarked
        }

        /// Mark the cited passages on the page on screen, in memory only — the vault's file is
        /// never written — and bring the first mark into view.
        func markCurrentPage(scrolling: Bool) {
            guard let view, let document = view.document, let page = view.currentPage,
                  page !== markedPage else { return }
            if let previous = markedPage { PassageHighlighter.clear(previous) }
            markedPage = page
            let text = page.string
            let number = document.index(for: page) + 1
            let marks = PassageMarks(passages: passages, page: number, pageText: text)
            var first = marks.hasPassages ? PassageHighlighter.apply(marks, to: page) : nil
            // A table read from a picture has no text to mark: the region it was read from is
            // outlined instead (Plan JN P2).
            let areas = pictureAreas.filter { $0.physical == number }
            if !areas.isEmpty {
                if !marks.hasPassages { PassageHighlighter.clear(page) }
                first = PassageHighlighter.outline(areas.map(\.rect), on: page) ?? first
            }
            if scrolling, let first {
                DispatchQueue.main.async { [weak view] in
                    view?.go(to: first.insetBy(dx: 0, dy: -40), on: page)
                }
            }
            let report = onMarked
            DispatchQueue.main.async { report(marks, text) }
        }

        /// Take this app's marks off the page last marked and mark the page on screen again, with
        /// the passages and regions as they are now.
        func remarkCurrentPage() {
            if let previous = markedPage { PassageHighlighter.clear(previous) }
            markedPage = nil
            markCurrentPage(scrolling: true)
        }

        func observe(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                                   name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged() {
            guard let view, let document = view.document, let page = view.currentPage else { return }
            onPageChanged(document.index(for: page))
            markCurrentPage(scrolling: false)
        }
    }
}
