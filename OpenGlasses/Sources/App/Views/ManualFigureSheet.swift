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
    @StateObject private var controller: ManualPageController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(request: AppState.ManualFigureRequest) {
        self.request = request
        _controller = StateObject(wrappedValue: ManualPageController(model: request.sheet,
                                                                     session: FieldSessionService.shared))
    }

    private var model: ManualPageSheetModel { controller.model }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .navigationTitle(Text(verbatim: model.hasContent ? model.paging.title : model.citation))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) { bottomControls }
            }
            .task { await controller.open() }
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
                              onPageChanged: { controller.viewerMoved(to: $0 + 1) })
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
            MessageContentView(text: model.currentText ?? "")
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
                Button { controller.previous() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.paging.canGoBack)
                    .accessibilityLabel("Previous page")
                Button { controller.next() } label: { Image(systemName: "chevron.right") }
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
    var onPageChanged: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onPageChanged: onPageChanged) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: source)
        goToPage(view)
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        if view.document?.documentURL != source {
            view.document = PDFDocument(url: source)
        }
        goToPage(view)
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
        private weak var view: PDFView?

        init(onPageChanged: @escaping (Int) -> Void) {
            self.onPageChanged = onPageChanged
        }

        func observe(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                                   name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged() {
            guard let view, let document = view.document, let page = view.currentPage else { return }
            onPageChanged(document.index(for: page))
        }
    }
}
