import PDFKit
import SwiftUI

/// The wiring diagram, on the technician's phone (Plan EK P2).
///
/// Speech cannot read a drawing back and the lens cannot render one legibly, so when a turn's
/// evidence points at a figure this is where the technician actually sees it. The body is PDFKit's
/// own viewer opened on the source page: pinch-zoom, the real type, and the surrounding page — all
/// of which a re-rendered bitmap would give up, on exactly the dense drawings that need them.
///
/// What is drawn is decided by `ManualFigurePresenter`, which is tested without a screen.
struct ManualFigureSheet: View {
    let presenter: ManualFigurePresenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch presenter.content {
                case .page(let source, let pageIndex):
                    ManualPDFPageView(source: source, pageIndex: pageIndex)
                        .ignoresSafeArea(edges: .bottom)
                case .unavailable:
                    unavailable
                }
            }
            .navigationTitle(Text(verbatim: presenter.citation))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The Markdown route's honest limit: the citation is still right, there is simply no page in
    /// the vault to draw. Says what to change so the next job has one.
    private var unavailable: some View {
        OGScrollPage {
            OGCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: presenter.citation)
                        .font(.headline)
                    Text("This manual was imported as extracted text, so there is no page to show. The citation still names where to find it in the printed book.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            OGNotice(text: "Import the manual as a PDF to see its drawings here and to let the assistant read them.",
                     systemImage: "doc.richtext")
        }
    }
}

/// PDFKit's viewer, opened on one page. Single-page display with zoom: the technician is looking
/// at *this* drawing, and a continuous scroll would let a stray swipe leave it.
private struct ManualPDFPageView: UIViewRepresentable {
    let source: URL
    let pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: source)
        goToPage(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
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
}
