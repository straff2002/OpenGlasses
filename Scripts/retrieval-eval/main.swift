import Foundation
import NaturalLanguage
import PDFKit

// The local retrieval eval on a Mac, on the device's embedding model. Compiled by run.sh with the
// app's own DocumentStore, DocumentChunker and VaultRetriever and the shared eval core in
// OpenGlassesTests/RetrievalEval, so what it measures is what the app ships. See README.md.

@main
struct RetrievalEvalMain {
    @MainActor
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard let vaultPath = env["RETRIEVAL_EVAL_VAULT"], let keyPath = env["RETRIEVAL_EVAL_ANSWER_KEY"] else {
            fail("set RETRIEVAL_EVAL_VAULT (a vault folder) and RETRIEVAL_EVAL_ANSWER_KEY (a JSON-lines file)")
        }
        let vault = URL(fileURLWithPath: vaultPath, isDirectory: true)
        guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8) else { fail("can't read the answer key") }
        let questions = RetrievalEval.loadAnswerKey(keyText)
        guard !questions.isEmpty else { fail("the answer key has no questions") }
        // Plan KN P1: RETRIEVAL_EVAL_FEATURES=<path> writes every candidate's ranking features, one
        // JSON line each, to a file outside the repository. Checked before anything is indexed.
        let featuresFile = env["RETRIEVAL_EVAL_FEATURES"].map(featuresDestination)
        let family: Int = env["RETRIEVAL_EVAL_FAMILY"].map { value in
            guard let number = Int(value), number >= 0 else { fail("RETRIEVAL_EVAL_FAMILY is a whole number") }
            return number
        } ?? 0

        // Plan IV P5: estimate how often one guided retry (the book's index, or the nearest
        // headings) would find what a missed question was after.
        RetrievalEval.retry = env["RETRIEVAL_EVAL_RETRY"].flatMap(RetrievalEval.Retry.init(rawValue:))
        // Plan JJ P1: which routes search a table's row passages (1, 0, token or table).
        if let rows = env["RETRIEVAL_EVAL_TABLE_ROWS"] {
            guard let mode = RetrievalEval.TableRows(rawValue: rows) else { fail("RETRIEVAL_EVAL_TABLE_ROWS is 1, 0, token or table") }
            RetrievalEval.tableRows = mode
        }
        let embedder = Embedder()
        guard embedder.isAvailable else { fail("no NaturalLanguage embedding model on this Mac") }

        // The store lives in a work folder the developer names (and deletes), so a long document is
        // embedded once, not on every run. Never inside the repository.
        let work = URL(fileURLWithPath: env["RETRIEVAL_EVAL_WORKDIR"]
                       ?? NSTemporaryDirectory() + "retrieval-eval-store", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let store = DocumentStore(directory: work, chunker: RetrievalEval.chunker(named: env["RETRIEVAL_EVAL_CHUNKER"]))

        // Plan JN P1: tables printed as pictures read too, by the document grid or the words
        // reading (off by default, as the text layer alone). Give each its own work folder.
        let pictures: PictureTableReading.Context?
        switch env["RETRIEVAL_EVAL_RECOGNISE"] ?? "off" {
        case "off": pictures = nil
        case "grid": pictures = .init(reader: VisionTableReader(), reading: .documentGrid)
        case "words": pictures = .init(reader: VisionTableReader(), reading: .words)
        default: fail("RETRIEVAL_EVAL_RECOGNISE is off, grid or words")
        }
        // Plan JY P5a: RETRIEVAL_EVAL_RELOCATE=1 re-chunks an indexed document's text and, where it
        // chunks as stored, rewrites only its pages, sections and figures (`writeLocations`, the
        // app's location migration), so a change that moves only citations is measured on the
        // same index and vectors. A document whose text no longer chunks the same is reported.
        let relocate = env["RETRIEVAL_EVAL_RELOCATE"] == "1"
        var relocated = 0, notRelocated = 0
        for document in manifestDocuments(in: vault) {
            if let existing = store.document(named: document.title) {
                if relocate {
                    let isPDF = document.url.pathExtension.lowercased() == "pdf"
                    let file = isPDF ? extractedText(of: document.url, into: work) : document.url
                    let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let chunks = RetrievalEval.chunker(named: env["RETRIEVAL_EVAL_CHUNKER"])
                        .sized(for: DocumentLanguageProfile.detect(text), text: text).chunk(text)
                    if store.writeLocations(documentId: existing.id, chunks: chunks) { relocated += 1 } else { notRelocated += 1 }
                }
                continue
            }
            let file = document.url
            // A PDF is indexed as the phone indexes it: its text, here as the Mac extractor writes
            // it (into the work folder, once), and its tables, read by the app's own table reader
            // (Plan JJ P1). A text document gets the tables of the original it names, if any.
            let isPDF = file.pathExtension.lowercased() == "pdf"
            let pdf = isPDF ? file : document.source.flatMap { $0.pathExtension.lowercased() == "pdf" ? $0 : nil }
            let textFile: URL
            if isPDF {
                textFile = extractedText(of: file, into: work)
            } else {
                guard ["md", "txt"].contains(file.pathExtension.lowercased()) else {
                    fail("document \(store.documents.count + 1): the Mac runner reads a PDF or extracted text")
                }
                textFile = file
            }
            guard let text = try? String(contentsOf: textFile, encoding: .utf8) else { fail("can't read document \(store.documents.count + 1)") }
            FileHandle.standardError.write("indexing document \(store.documents.count + 1)…\n".data(using: .utf8)!)
            var tables: [ManualTable] = []
            if let pdf, let doc = PDFDocument(url: pdf) {
                tables = await PDFTableReader.read(document: doc, printedLabels: printedLabels(of: doc), pictures: pictures).stored
            }
            _ = await store.ingest(name: document.title, text: text, sourceType: "vault_document", tables: tables)
        }

        // Plan JY P3: what each document was detected as, counted by script, language and rule —
        // codes only, so the line is as safe to paste as the counts.
        var profiles: [String: Int] = [:]
        for document in store.documents {
            let profile = store.languageProfile(documentId: document.id)
            profiles["\(profile.script.rawValue)/\(profile.language ?? "?")/\(profile.termRule)", default: 0] += 1
        }
        // Plan JY P3: RETRIEVAL_EVAL_VECTORS=pending measures a document in another script as it is
        // searched while its script's model is missing (decision 6): the index keeps its vectors,
        // but no script model answers, so every such passage is judged by its words alone.
        if let vectors = env["RETRIEVAL_EVAL_VECTORS"] {
            guard vectors == "pending" else { fail("RETRIEVAL_EVAL_VECTORS is pending") }
            store.scriptEmbedderProvider = { _ in nil }
        }

        // The shipped gate for this embedder, or a candidate one to calibrate a gate against both
        // sets: RETRIEVAL_EVAL_GATE="<min shared terms>,<shared fraction>" (floor 0.30), or "floor".
        var policy = RetrievalEvidencePolicy.default(for: embedder.modelId)
        if let gate = env["RETRIEVAL_EVAL_GATE"] {
            let parts = gate.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if gate == "floor" {
                policy = RetrievalEvidencePolicy()
            } else if parts.count == 2, let terms = Int(parts[0]), let fraction = Double(parts[1]) {
                policy = RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: terms, sharedFraction: fraction)
            } else {
                fail("RETRIEVAL_EVAL_GATE is \"floor\" or \"<terms>,<fraction>\"")
            }
        }
        // A candidate lower floor for a passage sharing every content term of the question:
        // RETRIEVAL_EVAL_FULL_MATCH="<floor>[,<fewest question terms>]" (terms: the policy's, 4
        // unless given), or "off". `RETRIEVAL_EVAL_GATE` builds a policy without one.
        if let full = env["RETRIEVAL_EVAL_FULL_MATCH"] {
            let parts = full.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if full == "off" {
                policy.fullMatchFloor = nil
            } else if let floor = Float(parts[0]), parts.count <= 2 {
                policy.fullMatchFloor = floor
                if parts.count == 2 {
                    guard let terms = Int(parts[1]) else { fail("RETRIEVAL_EVAL_FULL_MATCH is \"<floor>[,<terms>]\" or \"off\"") }
                    policy.fullMatchMinTerms = terms
                }
            } else {
                fail("RETRIEVAL_EVAL_FULL_MATCH is \"<floor>[,<terms>]\" or \"off\"")
            }
        }
        // Plan JY P3: a language group's candidate criterion and pending-passage increase
        // (RETRIEVAL_EVAL_GATE_GROUP, RETRIEVAL_EVAL_PENDING), over whatever the gate above is.
        for (group, criterion) in RetrievalEvalTuning.groupCriteria { policy.groupCriteria[group] = criterion }
        for (group, increase) in RetrievalEvalTuning.pendingIncrease { policy.pendingIncrease[group] = increase }
        // A vault holding a work in more than one edition answers from the newest unless the
        // question reaches past it, as the app's retrieval factory does.
        let documents = manifestDocuments(in: vault)
        let editions = DocumentEditions(entries: documents.map { (title: $0.title, kind: $0.kind, edition: $0.edition) })
        let open = RetrievalEvidencePolicy(similarityFloor: 0)
        let report = RetrievalEval.run(questions,
                                       gatedFor: { RetrievalEval.retriever(over: store, policy: policy, editions: editions, turn: $0) },
                                       openFor: { RetrievalEval.retriever(over: store, policy: open, editions: editions, turn: $0) },
                                       store: store,
                                       passageLimit: env["RETRIEVAL_EVAL_PASSAGES"] == "4" ? nil
                                           // Plan JY P4: RETRIEVAL_EVAL_PROSE_PASSAGES=5 measures a prose budget.
                                           : ManualPassageLimit(prose: env["RETRIEVAL_EVAL_PROSE_PASSAGES"].flatMap(Int.init) ?? 4))
        let label = (env["RETRIEVAL_EVAL_LABEL"] ?? "local vault") + (env["RETRIEVAL_EVAL_GATE"].map { " gate=\($0)" } ?? "")
            + (env["RETRIEVAL_EVAL_FULL_MATCH"].map { " full_match=\($0)" } ?? "")
            + (env["RETRIEVAL_EVAL_VECTORS"].map { " vectors=\($0)" } ?? "")
            + ["RETRIEVAL_EVAL_GATE_GROUP", "RETRIEVAL_EVAL_PENDING", "RETRIEVAL_EVAL_PREFIX", "RETRIEVAL_EVAL_MINLEN", "RETRIEVAL_EVAL_ENDINGS", "RETRIEVAL_EVAL_FOLD", "RETRIEVAL_EVAL_CJK",
               "RETRIEVAL_EVAL_CHUNK_SCALE", "RETRIEVAL_EVAL_P4_OFF", "RETRIEVAL_EVAL_PROSE_PASSAGES"]
                .compactMap { name in env[name].map { " \(name.dropFirst(15).lowercased())=\($0)" } }.joined()
            + " table_rows=\(RetrievalEval.tableRows.rawValue)"
        for line in report.lines(label: label, embedder: embedder.modelId) {
            print(line)
        }
        // RETRIEVAL_EVAL_DETAIL=1: each question by its line number in the key, with the pages it
        // expects and the pages of the four passages it got — numbers only, for a local look at
        // the misses. Never a question's text.
        if env["RETRIEVAL_EVAL_DETAIL"] == "1" {
            for (index, q) in questions.enumerated() {
                let outcome = RetrievalEval.retriever(over: store, policy: policy, editions: editions, turn: q.q)
                    .retrieve(.init(turn: q.q, limit: 4))
                let got = outcome.passages.prefix(4).map { p in p.page.map(String.init) ?? "-" }.joined(separator: ",")
                let expected = (q.pages ?? [:]).values.flatMap { $0 }.map(String.init).joined(separator: ",")
                let hit = outcome.passages.prefix(4).contains { RetrievalEval.holds($0, q) }
                print("[DETAIL] \(index + 1) \(q.outOfScope == true ? "oos" : "in") expect [\(expected)] got [\(got)] "
                      + (outcome.isSufficient ? "answered" : "refused") + (hit ? " hit" : ""))
            }
        }
        if let featuresFile {
            let index = Dictionary(documents.enumerated().compactMap { offset, document in
                store.document(named: document.title).map { ($0.id, offset + 1) }
            }, uniquingKeysWith: min)
            let lines = RetrievalEval.featureLines(
                questions, openFor: { RetrievalEval.retriever(over: store, policy: open, editions: editions, turn: $0) },
                family: family, embedder: embedder.modelId, documentIndex: { index[$0] })
            do {
                let text = try lines.map { try $0.encoded() }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
                try text.write(to: featuresFile, atomically: true, encoding: .utf8)
            } catch {
                fail("can't write the features file")
            }
            print("[EVAL]   features: \(lines.count) candidate lines, \(lines.filter { $0.label == 1 }.count) holding the answer, "
                  + "\(Set(lines.map(\.q)).count) questions, schema \(RankingFeatures.schemaVersion)")
        }
        if relocate { print("[EVAL]   relocated \(relocated), not relocated (text changed) \(notRelocated)") }
        print("[EVAL]   documents: " + profiles.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    }

    /// Where `RETRIEVAL_EVAL_FEATURES` writes, refused inside this repository or any other git
    /// working tree: the lines are numbers, but a features file is per-question results, which
    /// never go in a repository. The folder must exist; links in it are resolved before the check.
    static func featuresDestination(_ path: String) -> URL {
        let given = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let folder = given.deletingLastPathComponent().resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            fail("RETRIEVAL_EVAL_FEATURES: its folder does not exist")
        }
        let file = folder.appendingPathComponent(given.lastPathComponent)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().resolvingSymlinksInPath()
        if file.pathComponents.starts(with: root.pathComponents) {
            fail("RETRIEVAL_EVAL_FEATURES must name a file outside the repository")
        }
        var ancestor = folder
        while ancestor.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                fail("RETRIEVAL_EVAL_FEATURES must name a file outside every git working tree")
            }
            ancestor.deleteLastPathComponent()
        }
        return file
    }

    struct Document { let title: String; let url: URL; let kind: String?; let edition: String?; let source: URL? }

    /// The text of a PDF as `Scripts/extract-manual-text.swift` writes it, extracted once into the
    /// work folder (never the repository) and reused.
    static func extractedText(of pdf: URL, into work: URL) -> URL {
        let digest = pdf.lastPathComponent.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let out = work.appendingPathComponent("text-\(String(digest, radix: 16)).md")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let script = ProcessInfo.processInfo.environment["RETRIEVAL_EVAL_EXTRACTOR"].map { URL(fileURLWithPath: $0) }
            ?? here.appendingPathComponent("extract-manual-text.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", script.path, pdf.path, out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        FileHandle.standardError.write("extracting text…\n".data(using: .utf8)!)
        do { try process.run() } catch { fail("can't run the text extractor") }
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            fail("the text extractor failed")
        }
        return out
    }

    /// The printed page numbers, read as the phone reads them (`VaultDocumentExtractor.pageLabels`,
    /// its decision `PrintedPageBand.labels`).
    static func printedLabels(of document: PDFDocument) -> [Int: String] {
        var pdfLabels: [Int: String] = [:]
        var bands: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { bands.append(""); continue }
            let physical = index + 1
            if let label = page.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty, label != String(physical) {
                pdfLabels[physical] = label
                bands.append("")
                continue
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.height > 0 else { bands.append(""); continue }
            let band = bounds.height * 0.09
            let bottom = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: band)
            let top = CGRect(x: bounds.minX, y: bounds.maxY - band, width: bounds.width, height: band)
            bands.append([top, bottom].compactMap { page.selection(for: $0)?.string }.joined(separator: "\n"))
        }
        return Dictionary(PrintedPageBand.labels(bands: bands, pdfLabels: pdfLabels).map { ($0.page, $0.label) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// The manifest's documents, read with only the fields this needs.
    static func manifestDocuments(in vault: URL) -> [Document] {
        struct Manifest: Decodable {
            struct Entry: Decodable { let file: String; let title: String; let kind: String?; let edition: String?; let source: String? }
            let documents: [Entry]?
            let documents_dir: String?
        }
        guard let data = try? Data(contentsOf: vault.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            fail("no readable manifest.json in the vault folder")
        }
        let dir = manifest.documents_dir.map { vault.appendingPathComponent($0, isDirectory: true) } ?? vault
        return (manifest.documents ?? []).map {
            Document(title: $0.title, url: dir.appendingPathComponent($0.file), kind: $0.kind, edition: $0.edition,
                     source: $0.source.map { dir.appendingPathComponent($0) })
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("retrieval-eval: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
