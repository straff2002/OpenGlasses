import Foundation
import PDFKit

/// Gives manuals indexed before passages knew their place on the page (Plan IN P0) the place, on a
/// later launch, without anyone importing anything again.
///
/// The `EmbeddingVersion` pattern for positions: a row whose `location_version` is older than
/// `DocumentStore.locationVersion` is re-read from the vault's own copy of the file and chunked
/// again. When the new chunking is the stored one row for row — the usual case, since the chunker's
/// packing did not change — only the place is written onto the existing rows, so the document id,
/// the chunk text and the embedding are exactly as they were and every ledger entry, citation and
/// page-evidence label that names them still does. When the text no longer chunks the same way
/// (an extractor change since import), the document is re-chunked under the same id.
///
/// A manual any page of which was read by recognition is read again from the pages its import
/// recognised, which the vault keeps beside its ledger (Plan JY P5a): never by recognising them a
/// second time. One imported before those pages were kept is left as it is; its rows keep working,
/// and the locator splits their sentences itself.
///
/// **Tables (Plan JJ P0, location version 3; pictures, Plan JN P1, version 6; marked captions and
/// in-step folios, Plan JW P0, version 7).** The same pass reads each document's tables from
/// its PDF — the document itself, or the original a text import was made from, when that is still
/// on the phone — and adds their row passages beside the existing chunks, which are only located,
/// never re-chunked, when their text is unchanged. A document with no PDF has no positions to read
/// tables from; it is located as before and the log says its tables were skipped.
///
/// **Structure in other languages (Plan JY P4, location version 8).** Every document's text is read
/// again once: a folio printed alone on a line no longer renumbers its page, and a book in another
/// language gets its caption words, headings without case, collapsed fake bold, CJK splitting and
/// chunk size. Where the text chunks as stored — every English document, whose rules did not
/// change — the rows keep their ids, text and vectors and only their page, section and figure are
/// rewritten; a document whose text changed is re-chunked, and re-embedded, under its own id.
///
/// **Remaining defects (Plan JY P5a, location version 9).** Read again once more: a chunk is cited
/// at the page that holds most of it in the languages measured to gain, and a caption's dotted
/// label is whole. A manual read by recognition is read from the pages its import kept, and the
/// Documents library outside vaults gets the version-8 re-read from its own chunks
/// (`migrateLibrary`).
///
/// **Pages inside a chunk (Plan KE P2, location version 10).** Read again once more, for the page
/// breaks of a chunk packed across a page and for sections no longer opened by a table's rows. No
/// word moves, so the rows and vectors stay. The library outside vaults has no file to read and is only
/// stamped.
@MainActor
enum PassageLocationMigration {

    enum Outcome: String, Equatable {
        case current
        case located
        case rechunked
        case recognisedSkipped = "recognised_skipped"
        case unreadable
    }

    struct Report: Equatable {
        var located = 0
        var rechunked = 0
        var skipped = 0
    }

    /// Every installed vault, one at a time, each under its own operation lock so an import, a
    /// removal or an uninstall never sees a half-migrated document.
    @discardableResult
    static func run(store: DocumentStore,
                    manifests: [VaultManifest]? = nil) async -> Report {
        var report = Report()
        for manifest in manifests ?? VaultImporter.installedManifests() {
            await VaultOperationLock.withLock(manifest.id) {
                let ledger = VaultImporter.documentLedger(for: manifest.id)
                for entry in ledger.entries {
                    guard let document = manifest.documents.first(where: { $0.file == entry.file }) else { continue }
                    let root = VaultImporter.baselineDirectory(for: manifest.id)
                    let url = root.appendingPathComponent(manifest.documentRelativePath(document))
                    let original = manifest.documentSourceRelativePath(document).map { root.appendingPathComponent($0) }
                    switch await migrate(entry: entry, fileURL: url, originalURL: original, store: store,
                                         checkpointDirectory: VaultImporter.overlayDirectory(for: manifest.id)) {
                    case .located: report.located += 1
                    case .rechunked: report.rechunked += 1
                    case .recognisedSkipped, .unreadable: report.skipped += 1
                    case .current: break
                    }
                }
            }
        }
        let library = await migrateLibrary(store: store)
        report.located += library.located
        report.rechunked += library.rechunked
        if report.located + report.rechunked > 0 {
            PrivacyLog.store(.ragDocuments, .migrated, count: report.located,
                             total: report.located + report.rechunked)
        }
        return report
    }

    /// The Documents library outside vaults (Plan JY P5a), which the vault pass never sees. Its
    /// documents are text with no file kept, so a document's text is rebuilt from its own chunks
    /// (`DocumentStore.reconstructedText`) and chunked again under its own id — only for a
    /// document in a script whose rules location version 8 changed (CJK: chunk size, splitting and
    /// clause numbers without case; Arabic script: clause numbers without case). Every other
    /// document — Latin and Cyrillic text, whose chunking did not change — keeps its rows, ids and
    /// vectors and is only stamped located, so it is not looked at again.
    static func migrateLibrary(store: DocumentStore) async -> Report {
        var report = Report()
        for document in store.libraryDocumentsNeedingLocation() {
            guard rulesChanged(for: document.profile.script),
                  let text = store.reconstructedText(documentId: document.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                store.markLocated(documentId: document.id)
                continue
            }
            let chunks = DocumentChunker().sized(for: document.profile, text: text).chunk(text)
            guard !chunks.isEmpty else { report.skipped += 1; continue }
            if store.writeLocations(documentId: document.id, chunks: chunks) {
                report.located += 1
            } else if await store.rechunk(documentId: document.id, chunks: chunks) {
                report.rechunked += 1
            } else {
                report.skipped += 1
            }
        }
        return report
    }

    /// Whether location version 8's text rules differ for a library document in `script`.
    static func rulesChanged(for script: TextScript) -> Bool {
        script.isCJK || script == .arabic
    }

    /// One document. Extraction and chunking run off the main actor; the store is written on it.
    /// `originalURL` is the original a text document was extracted from, when the vault has one.
    /// `pictureReader` reads the tables printed as pictures (Plan JN P1), its regions checkpointed
    /// in `checkpointDirectory` when one is given.
    static func migrate(entry: VaultDocumentLedger.Entry, fileURL: URL, originalURL: URL? = nil,
                        store: DocumentStore,
                        pictureReader: PictureTableReader? = VaultImporter.defaultPictureReader,
                        checkpointDirectory: URL? = nil) async -> Outcome {
        guard store.needsLocation(documentId: entry.documentId) else { return .current }
        // A recognised manual is read again from the pages its import recognised, kept with the
        // vault (Plan JY P5a), never by recognising them a second time. One imported before they
        // were kept, a photographed manual's review, or one whose pages the record no longer
        // covers is left as it is.
        var recognised: OCRCheckpoint?
        if entry.usedRecognition {
            guard entry.capturedManual == nil, let checkpointDirectory, fileURL.pathExtension.lowercased() == "pdf" else {
                return .recognisedSkipped
            }
            let kept = OCRCheckpoint.load(from: checkpointDirectory, contentHash: entry.contentHash)
            guard !kept.pages.isEmpty else { return .recognisedSkipped }
            recognised = kept
        }
        let tablesPDF = VaultDocumentExtractor.tablesSource(document: fileURL, original: originalURL)
        let tablesHash = tablesPDF == fileURL ? entry.contentHash : (entry.sourceContentHash ?? entry.contentHash)
        let pictures = pictureReader.map { reader in
            checkpointDirectory.map { PictureTableReading.context(reader, checkpointIn: $0, contentHash: tablesHash) }
                ?? PictureTableReading.Context(reader: reader)
        }
        func readTables() async -> PDFTableReader.Result? {
            guard let tablesPDF else { return nil }
            let read = await Task.detached(priority: .utility) {
                await VaultDocumentExtractor.tables(from: tablesPDF, pictures: pictures)
            }.value
            if let checkpointDirectory { PictureTableCheckpoint.remove(from: checkpointDirectory, contentHash: tablesHash) }
            return read
        }
        // Text already located by location version 3 (Plan JJ P0): only the tables changed since —
        // version 4 keeps the captions whose page did not resolve to a grid (Plan JJ P1), 5 reads
        // more of the layouts a code book prints (Plan JJ P5), 6 reads the tables printed as
        // pictures (Plan JN P1), and 7 reads marked captions, "(Concluded)" pages and a folio at
        // the end of the footer line (Plan JW P0) — so the tables are read again and the
        // document's text is left exactly as it is. A document that is itself a PDF has its
        // printed page labels read again with them (version 7): the tables' pages are named from
        // the same labels, and `manual_figure`'s printed page and `show_source` read them back.
        // Version 8 (Plan JY P4) reads the text again, so a document below it takes the full
        // path below; the tables-only path is for a later bump that changes the tables alone.
        if recognised == nil, let floor = store.textLocationVersion(documentId: entry.documentId),
           floor >= DocumentStore.textReadVersion {
            if fileURL.pathExtension.lowercased() == "pdf" {
                let labels = await Task.detached(priority: .utility) {
                    PDFDocument(url: fileURL).map(VaultDocumentExtractor.pageLabels(of:))
                }.value
                if let labels { store.setPageLabels(labels, documentId: entry.documentId) }
            }
            let tables = await readTables()
            var dropped = 0
            if let tables {
                dropped = await store.replaceTables(tables.stored, documentId: entry.documentId).rowsDropped
            }
            store.markLocated(documentId: entry.documentId)
            VaultDocumentExtractor.logTables(tables, rowsDropped: dropped)
            return .located
        }
        let record = recognised
        let text: (chunks: [DocumentChunker.Chunk], labels: [PageLabel])? = await Task.detached(priority: .utility) {
            let extracted: VaultDocumentExtractor.Extracted?
            if let record {
                // Every page the import recognised comes from the record; a page it never saw is
                // a page this read would have to recognise, so the read is abandoned instead.
                let reader = RecordedPagesOnlyReader()
                extracted = try? await VaultDocumentExtractor.extract(
                    from: fileURL, reader: reader, checkpoint: (load: { record }, save: { _ in }))
                guard !reader.wasAsked else { return nil }
            } else {
                extracted = try? VaultDocumentExtractor.extract(from: fileURL)
            }
            guard let extracted else { return nil }
            // As the import indexed it: a one-page PDF opens with its page marker.
            let joined = extracted.pageCount == 1 && record != nil ? "Page 1\n" + extracted.text : extracted.text
            let text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return (DocumentChunker().sized(for: DocumentLanguageProfile.detect(text), text: text).chunk(text), extracted.pageLabels)
        }.value
        if recognised != nil, text == nil { return .recognisedSkipped }
        guard let text, !text.chunks.isEmpty else { return .unreadable }
        let read = (chunks: text.chunks, labels: text.labels, tables: await readTables())
        store.setPageLabels(read.labels, documentId: entry.documentId)
        let outcome: Outcome
        if store.writeLocations(documentId: entry.documentId, chunks: read.chunks) {
            outcome = .located
        } else if await store.rechunk(documentId: entry.documentId, chunks: read.chunks) {
            outcome = .rechunked
        } else {
            return .unreadable
        }
        var dropped = 0
        if let tables = read.tables {
            dropped = await store.replaceTables(tables.stored, documentId: entry.documentId).rowsDropped
        }
        VaultDocumentExtractor.logTables(read.tables, rowsDropped: dropped)
        return outcome
    }
}

/// The reader a recognised manual is read again with (Plan JY P5a): every page it is asked for was
/// not in the record of what the import recognised, so it recognises nothing and says it was asked.
final class RecordedPagesOnlyReader: ScannedPageReader, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    var wasAsked: Bool { lock.withLock { asked } }
    func recognise(_ image: CGImage) async -> ScannedPageText {
        lock.withLock { asked = true }
        return .empty
    }
}
