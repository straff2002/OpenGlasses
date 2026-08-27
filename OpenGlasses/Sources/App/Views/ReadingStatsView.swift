import SwiftUI
import UniformTypeIdentifiers

/// Per-book reading progress (docs/plans/BT-reading-companion.md P3) — the on-phone entry point.
/// Books appear as the reading companion captures them; here you browse stats and, for P4, attach
/// a canonical copy of the book so captures align to clean text and true progress.
struct ReadingStatsView: View {
    @ObservedObject private var store = ReadingSessionStore.shared

    var body: some View {
        Group {
            if store.books().isEmpty {
                ContentUnavailableView(
                    "No Reading Yet",
                    systemImage: "book",
                    description: Text("Say “start reading” with a book's title and the glasses will follow along."))
            } else {
                List {
                    ForEach(store.books(), id: \.id) { book in
                        NavigationLink {
                            ReadingBookDetailView(bookID: book.id)
                        } label: {
                            ReadingBookRow(bookID: book.id)
                        }
                    }
                    .onDelete { offsets in
                        let books = store.books()
                        offsets.map { books[$0].id }.forEach { store.deleteBook(id: $0) }
                    }
                }
                .ogFormStyle()
            }
        }
        .navigationTitle("Reading")
    }
}

private struct ReadingBookRow: View {
    @ObservedObject private var store = ReadingSessionStore.shared
    let bookID: String

    var body: some View {
        if let stats = store.stats(forBook: bookID) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stats.bookTitle).font(.headline)
                Text(summaryLine(stats))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryLine(_ stats: ReadingStats) -> String {
        var parts = ["\(stats.pageCount) page\(stats.pageCount == 1 ? "" : "s")",
                     "\(stats.sessionCount) sitting\(stats.sessionCount == 1 ? "" : "s")"]
        if let progress = store.progress(forBook: bookID), progress > 0 {
            parts.insert("\(min(100, max(1, Int((progress * 100).rounded()))))%", at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

/// One book: sessions, pace, streak, and the P4 reference copy controls.
struct ReadingBookDetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = ReadingSessionStore.shared
    let bookID: String

    @State private var showingImporter = false
    @State private var showingDocumentPicker = false
    @State private var attachMessage: String?

    var body: some View {
        List {
            if let stats = store.stats(forBook: bookID) {
                Section("Progress") {
                    if let progress = store.progress(forBook: bookID) {
                        LabeledContent("Through the book",
                                       value: "\(min(100, max(1, Int((progress * 100).rounded()))))%")
                    }
                    LabeledContent("Pages read", value: "\(stats.pageCount)")
                    LabeledContent("Sittings", value: "\(stats.sessionCount)")
                    LabeledContent("Time", value: "\(Int(stats.totalMinutes.rounded())) min")
                    if stats.pagesPerMinute > 0, stats.pageCount >= 3 {
                        LabeledContent("Pace", value: String(format: "%.1f min/page", 1 / stats.pagesPerMinute))
                    }
                    let streak = ReadingStreaks.current(
                        sessionDates: store.sessions(forBook: bookID).map(\.startedAt))
                    if streak > 0 {
                        LabeledContent("Streak", value: "\(streak) day\(streak == 1 ? "" : "s")")
                    }
                    if let last = stats.lastReadAt {
                        LabeledContent("Last read", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section {
                if let reference = store.reference(forBook: bookID) {
                    LabeledContent("Attached copy", value: reference.documentName)
                    if let asserted = reference.assertedReadUpTo, reference.wordCount > 0 {
                        LabeledContent("Confirmed read",
                                       value: "up to \(min(100, max(1, Int((Double(asserted) / Double(reference.wordCount) * 100).rounded()))))%")
                    }
                    Button {
                        attachMessage = ReadingCompanionService.shared.assertCaughtUp(bookID: bookID)
                    } label: {
                        Label("I've read up to my current spot", systemImage: "checkmark.circle")
                    }
                    Button("Detach copy", role: .destructive) {
                        store.detachReference(forBook: bookID)
                    }
                } else {
                    Button {
                        showingDocumentPicker = true
                    } label: {
                        Label("Attach from Documents", systemImage: "doc.text")
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Attach a file (PDF or text)", systemImage: "square.and.arrow.down")
                    }
                }
                if let attachMessage {
                    Text(attachMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Reference copy")
            } footer: {
                Text("Attach your own copy of the book and captures align to its clean text, with "
                     + "true progress. The camera still decides what you've read — nothing past "
                     + "the last page you've looked at is ever used. Takes effect next session.")
            }

            Section("Sittings") {
                ForEach(store.sessions(forBook: bookID).reversed()) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("\(session.pages.count) page\(session.pages.count == 1 ? "" : "s") · \(Int(session.durationMinutes.rounded())) min")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .ogFormStyle()
        .navigationTitle(store.stats(forBook: bookID)?.bookTitle ?? "Book")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.pdf, .epub, .plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            Task { await attachFile(url) }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            NavigationStack {
                ReadingReferencePickerView(bookID: bookID) { message in
                    attachMessage = message
                }
            }
        }
    }

    /// Extract (PDF / EPUB / UTF-8 via `BookFileExtractor`), ingest into the Plan O DocumentStore,
    /// and point the book at it.
    private func attachFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let extracted = BookFileExtractor.extract(from: url) else {
            attachMessage = "Couldn't read text from that file (scanned PDFs aren't supported)."
            return
        }

        guard let ref = await appState.documentStore.ingest(
            name: extracted.name, text: extracted.text, sourceType: "book") else {
            attachMessage = "Couldn't import the file."
            return
        }
        ReadingReferenceAttacher.attach(documentId: ref.id, documentName: extracted.name,
                                        text: extracted.text, toBook: bookID, store: store)
        attachMessage = "Attached \(extracted.name)."
    }
}

/// Pick an already-imported document as the book's reference copy.
private struct ReadingReferencePickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    let onAttached: (String) -> Void

    var body: some View {
        List(appState.documentStore.list()) { document in
            Button {
                if let text = appState.documentStore.fullText(documentId: document.id) {
                    ReadingReferenceAttacher.attach(documentId: document.id, documentName: document.name,
                                                    text: text, toBook: bookID,
                                                    store: ReadingSessionStore.shared)
                    onAttached("Attached \(document.name).")
                } else {
                    onAttached("That document has no readable text.")
                }
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name)
                    Text("\(document.charCount) characters")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .ogFormStyle()
        .navigationTitle("Choose a copy")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// Shared attach step: word count computed with the alignment tokenization so stored progress and
/// index positions agree.
@MainActor
enum ReadingReferenceAttacher {
    static func attach(documentId: String, documentName: String, text: String,
                       toBook bookID: String, store: ReadingSessionStore) {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        store.attachReference(BookReference(
            bookID: bookID, documentId: documentId, documentName: documentName,
            wordCount: wordCount, attachedAt: Date()))
    }
}
