import Foundation
import PDFKit

// The table lookup scored against a key of cells, on a Mac: the vault's PDFs read as an import on
// the phone reads them (`PDFTableReader`, `TableExtractor`), each question looked up with the app's
// own `TableLookup`, and the counts printed by `TableLookupEval` — never a question, a table's
// label, a row, a column, a cell or a document's name. See README.md.

@main
struct TableLookupEvalRunner {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: table-lookup-eval <vault folder> <key.jsonl>\n".utf8))
            exit(2)
        }
        let environment = ProcessInfo.processInfo.environment
        let label = environment["TABLE_LOOKUP_EVAL_LABEL"] ?? "vault"
        let vault = URL(fileURLWithPath: arguments[0], isDirectory: true)
        guard let key = try? String(contentsOf: URL(fileURLWithPath: arguments[1]), encoding: .utf8) else {
            print("[CELLS] the key could not be read")
            exit(1)
        }

        // TABLE_LOOKUP_EVAL_OUTCOMES=<file>: one outcome per question, by its place and a hash,
        // written outside every git working tree for a later run to pair with.
        // TABLE_LOOKUP_EVAL_BASELINE=<an earlier run's outcomes file>: pair with it and print the
        // paired difference. Both checked before any PDF is read.
        let outcomesFile: URL? = environment["TABLE_LOOKUP_EVAL_OUTCOMES"].map { path in
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            var isFolder: ObjCBool = false
            let folder = file.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                print("[CELLS] TABLE_LOOKUP_EVAL_OUTCOMES: its folder does not exist")
                exit(2)
            }
            guard !EvalOutcomes.isInsideGitWorkingTree(folder) else {
                print("[CELLS] TABLE_LOOKUP_EVAL_OUTCOMES must name a file outside every git working tree")
                exit(2)
            }
            return file
        }
        let baseline: [EvalOutcome]? = environment["TABLE_LOOKUP_EVAL_BASELINE"].map { path in
            guard let read = try? EvalOutcomes.read(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
                print("[CELLS] TABLE_LOOKUP_EVAL_BASELINE could not be read as an outcomes file")
                exit(2)
            }
            return read
        }

        // The documents: every one the manifest lists that is a PDF or whose original is, with its
        // title; with no manifest, every PDF in the folder.
        var documents: [(url: URL, name: String)] = []
        if let data = try? Data(contentsOf: vault.appendingPathComponent("manifest.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let base = (json["documents_dir"] as? String).map { vault.appendingPathComponent($0, isDirectory: true) } ?? vault
            for entry in json["documents"] as? [[String: Any]] ?? [] {
                guard let file = entry["file"] as? String else { continue }
                let title = entry["title"] as? String ?? file
                let url = base.appendingPathComponent(file)
                if url.pathExtension.lowercased() == "pdf" {
                    documents.append((url, "\(title) \(file)"))
                } else if let source = entry["source"] as? String, source.lowercased().hasSuffix(".pdf") {
                    documents.append((base.appendingPathComponent(source), "\(title) \(source)"))
                }
            }
        } else if let walker = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil) {
            for case let url as URL in walker.allObjects where url.pathExtension.lowercased() == "pdf" {
                documents.append((url, url.lastPathComponent))
            }
        }

        // Tables printed as pictures (Plan JN P1): off (the text layer only, as an import read
        // before), or recognised on this Mac by the document grid or the words reading, at a floor.
        let recognise = environment["TABLE_LOOKUP_EVAL_RECOGNISE"] ?? "off"
        let reading: ManualTable.Source.Reader?
        switch recognise {
        case "off": reading = nil
        case "grid": reading = .documentGrid
        case "words": reading = .words
        default:
            print("[CELLS] TABLE_LOOKUP_EVAL_RECOGNISE is off, grid or words")
            exit(2)
        }
        let floor = environment["TABLE_LOOKUP_EVAL_FLOOR"].flatMap(Float.init) ?? PictureTableReading.floor
        let pictures = reading.map { PictureTableReading.Context(reader: VisionTableReader(), reading: $0, floor: floor) }

        let started = Date()
        var sources: [TableLookup.Source] = []
        var unreadable = 0
        var totals = PDFTableReader.Result()
        for (index, document) in documents.enumerated() {
            guard document.url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: document.url) else {
                unreadable += 1
                continue
            }
            if let pictures, environment["TABLE_LOOKUP_EVAL_DIAGNOSE"] == "1" { await diagnose(pdf, document: index, pictures: pictures) }
            let result = await PDFTableReader.read(document: pdf, pictures: pictures)
            if pictures != nil {
                // Whether reading the pictures changed anything the document stores, against the
                // text layer alone: a count of tables that differ, never which.
                let plain = PDFTableReader.read(document: pdf).stored
                let changed = zip(plain, result.stored).filter { $0 != $1 }.count + abs(plain.count - result.stored.count)
                print("[CELLS] document \(index + 1): stored tables differing from the text layer alone=\(changed)")
            }
            totals.recognised += result.recognised
            totals.unclearInPicture += result.unclearInPicture
            totals.uncertainCells += result.uncertainCells
            totals.uncertainKeys += result.uncertainKeys
            totals.uncertainColumns += result.uncertainColumns
            sources += result.stored.map { TableLookup.Source(documentId: "document-\(index)", documentName: document.name, table: $0) }
        }
        print(String(format: "[CELLS] documents=%d unreadable=%d tables=%d read=%d seconds=%.1f",
                     documents.count, unreadable, sources.count, sources.filter(\.table.isExtracted).count,
                     Date().timeIntervalSince(started)))
        if let reading {
            // Per table read from a picture, by its place in the run only: its cells and how many
            // of them, its row keys and its headings were uncertain.
            let pictured = sources.map(\.table).filter { $0.source.isRecognised }
            print("[CELLS] recognise=\(reading.rawValue) floor=\(floor): tables read from a picture=\(totals.recognised) "
                  + "unclear_in_picture=\(totals.unclearInPicture) uncertain cells=\(totals.uncertainCells) "
                  + "keys=\(totals.uncertainKeys) headings=\(totals.uncertainColumns)")
            for (number, table) in pictured.enumerated() {
                let cells = table.rows.flatMap(\.cells).filter { !$0.isEmpty }
                print("[CELLS]   pictured table \(number + 1): rows=\(table.rows.count) columns=\(table.columns.count) "
                      + "cells=\(cells.count) uncertain=\(cells.filter(\.uncertain).count) "
                      + "uncertain keys=\(table.rows.filter(\.keyUncertain).count) "
                      + "uncertain headings=\(table.columns.filter(\.uncertain).count)")
            }
        }

        let parsed = TableLookupEval.parseCounting(key)
        let scored = TableLookupEval.scoreWithOutcomes(parsed.questions, unreadable: parsed.unreadable.values.reduce(0, +),
                                                       sources: sources)
        var report = scored.report
        report.unreadableBy = Dictionary(uniqueKeysWithValues: parsed.unreadable.map { ($0.key.rawValue, $0.value) })
        for line in TableLookupEval.render(report, label: label, checked: environment["TABLE_LOOKUP_EVAL_KEY_CHECKED"] == "1") {
            print(line)
        }
        for line in TableLookupEval.renderIntervals(scored.outcomes) {
            print(line)
        }
        if let outcomesFile {
            do {
                try EvalOutcomes.write(scored.outcomes, to: outcomesFile)
                print("[CELLS]   outcomes: \(scored.outcomes.count) questions written")
            } catch {
                print("[CELLS]   outcomes: could not be written")
            }
        }
        if let baseline {
            let pairing = EvalOutcomes.pair(baseline: baseline, current: scored.outcomes)
            for line in EvalOutcomes.comparisonLines(prefix: "[CELLS]  ", pairing: pairing, metrics: TableLookupEval.metrics) {
                print(line)
            }
        }
        for line in TableLookupEval.renderPictures(TableLookupEval.scorePictures(parsed.questions, sources: sources), label: label) {
            print(line)
        }
    }

    /// Per region recognised, in counts and the extractor's closed failure names only: what kind of
    /// caption sent it, how tall it was, how many words and tables the recogniser read in it, and
    /// what the reading came to. Never a word, a label or a value.
    static func diagnose(_ pdf: PDFDocument, document: Int, pictures: PictureTableReading.Context) async {
        let first = PDFTableReader.scan(document: pdf, pictures: nil)
        let recognitions = await PictureTableReading.recognise(first.candidates, in: pdf, context: pictures)
        let inputs = PictureTableReading.Inputs(recognitions: recognitions, reading: pictures.reading, floor: pictures.floor)
        print("[DIAG] document \(document + 1): candidates=\(first.candidates.count)")
        for (number, candidate) in first.candidates.enumerated() {
            guard let page = pdf.page(at: candidate.physical - 1) else { continue }
            switch candidate.kind {
            case .page:
                let words = recognitions.pages[candidate.physical]?.words.count ?? -1
                print("[DIAG]   \(number + 1): page with no text layer, words=\(words)")
            case .caption(let caption):
                let words = PDFTableReader.positionedWords(on: page)
                let failure = TableExtractor.extractGrids(words: words, page: .init(physical: candidate.physical))
                    .first { $0.caption.label.caseInsensitiveCompare(caption.label) == .orderedSame }?.outcome.failure?.rawValue ?? "?"
                guard let recognition = recognitions.regions[.init(physical: candidate.physical, label: caption.label)] else {
                    print("[DIAG]   \(number + 1): caption (\(failure)) not recognised")
                    continue
                }
                let read = PictureTableReading.read(recognition, captionWords: PictureTableReading.captionWords(of: caption, in: words),
                                                    caption: caption, page: .init(physical: candidate.physical), inputs: inputs)
                let confidences = recognition.first.words.map(\.confidence)
                let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
                print(String(format: "[DIAG]   %d: caption (%@) region=%dpt words=%d mean=%.2f tables=%d cells=%@ -> %@ uncertain=%d keys=%d headings=%d",
                             number + 1, failure, Int(candidate.region.height), recognition.first.words.count, mean,
                             recognition.first.tables.count, recognition.first.tables.map { String($0.cells.count) }.joined(separator: "/"),
                             read.outcome.failure?.rawValue ?? "table", read.assessment.uncertain, read.assessment.uncertainKeys,
                             read.assessment.uncertainColumns))
            }
        }
    }
}
