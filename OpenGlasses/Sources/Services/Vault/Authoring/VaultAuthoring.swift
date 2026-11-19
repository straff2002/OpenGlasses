import Foundation

/// Plan LW P1 — a vault of the subscriber's own, made and grown on the phone.
///
/// Every change goes through the importer the folder picker uses (`VaultImporter.installReporting`),
/// so validation, the atomic baseline swap and the overlay rules are its own: *New Vault* installs
/// the starter (`VaultStarter`) as a user-imported vault, *Add manual* re-lays the vault with one
/// more document (`VaultDocumentCarry.relay`), and *Add file* re-lays it with one more core file.
/// A kept draft row is an edit, so it is written to the overlay through `VaultStore.write`, as the
/// file editor writes, and an export carries it.
@MainActor
enum VaultAuthoring {

    enum Failure: LocalizedError, Equatable {
        /// Only a vault the subscriber made or imported can be changed on the phone.
        case notOwned
        case emptyFileName
        case fileExists(String)
        case noFileForLayer(String)
        case noManual

        var errorDescription: String? {
            switch self {
            case .notOwned:
                return String(localized: "Only a vault you made or imported yourself can be changed on this phone.")
            case .emptyFileName:
                return String(localized: "Give the file a name.")
            case .fileExists(let name):
                return String(localized: "The vault already has a file called \(name).")
            case .noFileForLayer(let name):
                return String(localized: "This vault has no \(name). Add it with Add file, then keep the row again.")
            case .noManual:
                return String(localized: "That manual is no longer in this vault.")
            }
        }
    }

    // MARK: - Whose vault it is

    /// Whether `vaultId` is a vault the subscriber owns: installed from a folder or made on the phone,
    /// not My Manuals, not a pack, not received from a link, and with no company layer over it.
    static func isOwned(_ vaultId: String) -> Bool {
        guard let manifest = VaultImporter.installedManifest(id: vaultId) else { return false }
        return !manifest.isPersonalLibrary
            && VaultImporter.installedPack(for: vaultId) == nil
            && VaultImporter.receipt(for: vaultId) == nil
            && VaultCompanyLayer.installed(baseId: vaultId) == nil
    }

    /// The trade the vault was made for: the one recorded at *New Vault*, else the one its manifest's
    /// trades name, else General.
    static func template(for manifest: VaultManifest) -> TradeTemplate {
        if let recorded = VaultAuthoringRecord.load(vaultId: manifest.id)?.template,
           let id = TradeTemplate.ID(rawValue: recorded) {
            return TradeTemplate.template(id: id)
        }
        return inferredTemplate(trades: manifest.trades)
    }

    nonisolated static func inferredTemplate(trades: [String]?) -> TradeTemplate {
        let named = Set(trades ?? [])
        return TradeTemplate.all.first { template in
            guard let trades = template.trades else { return false }
            return !named.isDisjoint(with: trades)
        } ?? .general
    }

    // MARK: - New Vault

    /// The models typed on the New Vault form: one per line, or comma or semicolon separated, each
    /// with its other spellings in brackets (`QX-100 (QX100, QX 100)`).
    nonisolated static func models(fromText text: String) -> [VaultStarter.Model] {
        var entries: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "(": depth += 1; current.append(character)
            case ")": depth = max(0, depth - 1); current.append(character)
            case ",", ";", "\n", "\r", "\r\n":
                if depth == 0 { entries.append(current); current = "" } else { current.append(character) }
            default: current.append(character)
            }
        }
        entries.append(current)
        return entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let open = trimmed.firstIndex(of: "(") else { return VaultStarter.Model(trimmed) }
            let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            let inside = trimmed[trimmed.index(after: open)...].replacingOccurrences(of: ")", with: "")
            let aliases = inside.components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !name.isEmpty else { return aliases.first.map { VaultStarter.Model($0, aliases: Array(aliases.dropFirst())) } }
            return VaultStarter.Model(name, aliases: aliases)
        }
    }

    /// The id to pass `VaultStarter.make` for `name`: nil when the default (`vaultId(forName:)`) is
    /// free, else the default with the first free number after it (`rooftop_units_2`).
    nonisolated static func freeId(forName name: String, taken: Set<String>) -> String? {
        let base = VaultStarter.vaultId(forName: name)
        guard taken.contains(base) else { return nil }
        var number = 2
        while taken.contains("\(base)_\(number)") { number += 1 }
        return "\(base)_\(number)"
    }

    /// Every vault id on the phone: the bundled vaults, the installed ones and My Manuals.
    static var takenIds: Set<String> {
        Set(VaultRegistry.shared.allManifests.map(\.id) + VaultImporter.installedManifests().map(\.id))
    }

    /// Make the starter and install it as a user-imported vault. The trade is recorded beside it, for
    /// the prompt kits, the proposals and the vault check.
    @discardableResult
    static func createVault(name: String, template: TradeTemplate, models: [VaultStarter.Model] = [],
                            taken: Set<String>? = nil) throws -> VaultManifest {
        let output = try VaultStarter.make(name: name, template: template, models: models,
                                           id: freeId(forName: name, taken: taken ?? takenIds))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VaultNew-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let folder = root.appendingPathComponent(output.id, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try output.manifestJSON.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        for file in output.files {
            try file.contents.write(to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }
        // Validated on the main thread on purpose: a starter is a handful of short Markdown files
        // and no manuals, so the check is quick, and the id is new, so nothing else holds it.
        let report = try VaultImporter.installReporting(from: folder)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        // After the install: a first baseline clears whatever overlay the id had.
        try VaultAuthoringRecord(template: template.id.rawValue).save(vaultId: report.manifest.id)
        return report.manifest
    }

    // MARK: - Add manual

    /// What the author adds: the prepared upload (`ManualFileUpload.prepare`), its title and edition,
    /// and whether its pages were photographed.
    struct NewManual {
        let original: URL
        let readingPDF: URL
        let converted: Bool
        let title: String
        let edition: String?
        let photographed: Bool

        init(original: URL, readingPDF: URL, converted: Bool, title: String, edition: String? = nil,
             photographed: Bool = false) {
            self.original = original
            self.readingPDF = readingPDF
            self.converted = converted
            self.title = title
            self.edition = edition
            self.photographed = photographed
        }

        init(_ prepared: ManualFileUpload.Prepared, title: String, edition: String?, photographed: Bool) {
            self.init(original: prepared.original, readingPDF: prepared.readingPDF, converted: prepared.converted,
                      title: title, edition: edition, photographed: photographed)
        }
    }

    /// A file name for a manual titled `title`: its slug, the extension kept, unique among `taken`
    /// (case-insensitively), so the key its index rows cite reads as the manual.
    nonisolated static func manualFileName(title: String, extension ext: String, taken: Set<String>) -> String {
        let stem = VaultExpects.slug(title)
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = "\(stem).\(ext)"
        var number = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(stem)-\(number).\(ext)"; number += 1
        }
        return candidate
    }

    /// The document a new manual becomes, with its files: the uploaded file, and for a Word or
    /// Markdown upload the PDF reading copy beside it (as My Manuals lays them). `revision` is the
    /// SHA-256 of the file the index reads it by (the same digest the ledger records); `origin` is
    /// the technician's own, or a capture for photographed pages.
    nonisolated static func kept(_ manual: NewManual, existingFiles: Set<String>) throws -> VaultDocumentCarry.Kept {
        let ext = manual.original.pathExtension.lowercased()
        let title = String(manual.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        let file = manualFileName(title: title.isEmpty ? "manual" : title, extension: ext, taken: existingFiles)
        let source = manual.converted ? (file as NSString).deletingPathExtension + ".reading.pdf" : nil
        let edition = manual.edition?.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = VaultDocumentLedger.hash(of: try Data(contentsOf: manual.original, options: .mappedIfSafe))
        let document = VaultDocument(file: file, title: title.isEmpty ? String(localized: "Manual") : title,
                                     source: source, edition: edition?.isEmpty == false ? edition : nil,
                                     personalCapture: manual.photographed ? true : nil,
                                     personalReadingCopy: manual.converted ? true : nil,
                                     revision: revision, origin: manual.photographed ? .capture : .technician)
        var files = [file: manual.original]
        if let source { files[source] = manual.readingPDF }
        return VaultDocumentCarry.Kept(document: document, files: files)
    }

    /// Add `manual` to the owned vault `vaultId`. Its per-file caps were applied when it was prepared;
    /// a vault of the subscriber's own has no manual count. The caller indexes the result.
    ///
    /// The vault is validated off the main thread, since that reads every manual it already holds,
    /// under its lock, so nothing else re-lays it in the meantime.
    @discardableResult
    static func addManual(_ manual: NewManual, to vaultId: String) async throws -> VaultManifest {
        try await VaultOperationLock.withLock(vaultId) {
            guard isOwned(vaultId), let manifest = VaultImporter.installedManifest(id: vaultId) else { throw Failure.notOwned }
            let taken = Set(manifest.documents.flatMap { [$0.file] + [$0.source].compactMap { $0 } } + manifest.files)
            let kept = try kept(manual, existingFiles: taken)
            return try await VaultDocumentCarry.relayOffMain(vaultId: vaultId, removing: [], adding: [kept])
        }
    }

    // MARK: - Add file

    /// The file name for a new core file named `name`: its slug with `.md`.
    nonisolated static func coreFileName(_ name: String) -> String? {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".md", ".markdown"] where trimmed.lowercased().hasSuffix(ext) { trimmed.removeLast(ext.count) }
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return VaultExpects.slug(trimmed) + ".md"
    }

    /// Add a Markdown core file named `name` to the owned vault `vaultId`, listed in `manifest.files`
    /// after the others. It starts as its title as a heading (the validator refuses an empty file);
    /// the author writes it in the editor. Returns the file's name.
    ///
    /// The whole vault is validated again, manuals included, so that runs off the main thread, under
    /// the vault's lock: the staging copy is taken from the baseline, and nothing may change the
    /// baseline before the copy is installed over it.
    @discardableResult
    static func addFile(named name: String, to vaultId: String) async throws -> String {
        try await VaultOperationLock.withLock(vaultId) { try await addFileLocked(named: name, to: vaultId) }
    }

    private static func addFileLocked(named name: String, to vaultId: String) async throws -> String {
        guard isOwned(vaultId), let manifest = VaultImporter.installedManifest(id: vaultId) else { throw Failure.notOwned }
        guard let file = coreFileName(name) else { throw Failure.emptyFileName }
        let taken = Set((manifest.files + manifest.documents.map(\.file)).map { $0.lowercased() })
        guard !taken.contains(file.lowercased()) else { throw Failure.fileExists(file) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("VaultAddFile-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: VaultImporter.baselineDirectory(for: vaultId), to: staging)
        let heading = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".md", with: "").components(separatedBy: .newlines).joined(separator: " ")
        try "# \(heading)\n".write(to: staging.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(manifest.withFiles(manifest.files + [file]))
            .write(to: staging.appendingPathComponent("manifest.json"))
        _ = try await VaultImporter.installReportingOffMain(from: staging)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        return file
    }

    // MARK: - Keeping a draft row

    /// What a kept row wrote, and where.
    struct KeptRow: Equatable {
        let file: String
        let line: String
        let citation: String
    }

    /// Write a kept `row` into the vault's file for its layer, citing the manual whose key is `key` at
    /// PDF page `page` (and its printed page, from `labels`, beside it when it differs). A row still
    /// in the manual's words is recorded, so the export's publishing check can say so until the
    /// author rewrites it.
    @discardableResult
    static func keep(_ row: DraftRow, key: String, page: Int, labels: PageLabelMap, inManualsWords: Bool,
                     vaultId: String) throws -> KeptRow {
        guard isOwned(vaultId), let store = VaultRegistry.shared.store(forId: vaultId) else { throw Failure.notOwned }
        guard let file = DraftKeeper.file(for: row.layer, among: store.manifest.files) else {
            throw Failure.noFileForLayer(DraftKeeper.fileName(for: row.layer))
        }
        let citation = IndexRowWriter.citation(key: key, page: page, printed: labels.printed(forPhysical: page))
        let result = DraftKeeper.keeping(row, citation: citation, in: store.read(file) ?? "")
        try store.write(file, contents: result.text)
        if inManualsWords {
            var record = VaultAuthoringRecord.load(vaultId: vaultId) ?? VaultAuthoringRecord(template: template(for: store.manifest).id.rawValue)
            record.copiedLines.append(.init(file: file, line: result.line))
            try record.save(vaultId: vaultId)
        }
        return KeptRow(file: file, line: result.line, citation: citation)
    }

    /// The key a document's index rows cite in `manifest` (`VaultExpects`).
    static func key(for document: VaultDocument, in manifest: VaultManifest) -> String {
        VaultExpects.key(forFile: document.file, among: manifest.documents.map(\.file)) ?? VaultExpects.slug(document.file)
    }
}

extension VaultManifest {
    /// This manifest with another core-file list, and everything else as it is.
    func withFiles(_ files: [String]) -> VaultManifest {
        VaultManifest(id: id, name: name, version: version, files: files, proceduresDir: proceduresDir,
                      documentsDir: documentsDir, documents: documents, documentsIncluded: documentsIncluded,
                      gating: gating, promptRules: promptRules, sourceAttributionFormat: sourceAttributionFormat,
                      sourceAttributionRequired: sourceAttributionRequired, trades: trades, sites: sites,
                      vaultOnly: vaultOnly)
    }
}

// MARK: - The authoring record

/// What the phone keeps about a vault being authored, beside its overlay (never exported): the trade
/// it was made for, the vault check's questions and the author's threshold, the last score, and the
/// kept rows still in the manual's words.
struct VaultAuthoringRecord: Codable, Equatable {
    struct PageAnswer: Codable, Equatable, Hashable {
        var key: String
        var page: Int
    }

    struct Question: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var key: String
        var page: Int
    }

    struct CopiedLine: Codable, Equatable {
        var file: String
        var line: String
    }

    struct LastCheck: Codable, Equatable {
        var asked: Int
        var found: Int
        var fraction: Double { asked == 0 ? 1 : Double(found) / Double(asked) }
    }

    var template: String
    /// The share of questions that must find their page for the publishing check to stay quiet.
    var threshold: Double = 0.8
    /// The page that answers each of the template's starter questions, by the question's text.
    var starterAnswers: [String: PageAnswer] = [:]
    var questions: [Question] = []
    var copiedLines: [CopiedLine] = []
    var lastCheck: LastCheck?

    static let fileName = ".vault-authoring.json"

    static func load(from directory: URL) -> VaultAuthoringRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(VaultAuthoringRecord.self, from: data)
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func load(vaultId: String) -> VaultAuthoringRecord? {
        load(from: VaultImporter.overlayDirectory(for: vaultId))
    }

    func save(vaultId: String) throws {
        try save(to: VaultImporter.overlayDirectory(for: vaultId))
    }
}

// MARK: - A manual from a publisher's link

/// Plan LW P1 — *Add manual* from a publisher's link or code: the same review the link sheet always
/// shows (the site, the signature, the size), and on its install the manuals the archive carries are
/// added to the vault being authored instead of installing the publisher's vault beside it. The
/// archive's core files are not taken: the vault is the author's.
@MainActor
enum AuthoringLinkIntake {

    enum Failure: LocalizedError {
        case noManuals
        var errorDescription: String? { String(localized: "This link carries no manuals to add.") }
    }

    /// Under the vault's lock, with the validation off the main thread (see `VaultAuthoring.addManual`).
    static func add(_ request: VaultLinkInstaller.Request, to vaultId: String) async throws -> VaultLinkInstaller.Outcome {
        try await VaultOperationLock.withLock(vaultId) { try await addLocked(request, to: vaultId) }
    }

    private static func addLocked(_ request: VaultLinkInstaller.Request, to vaultId: String) async throws -> VaultLinkInstaller.Outcome {
        guard VaultAuthoring.isOwned(vaultId), let target = VaultImporter.installedManifest(id: vaultId) else {
            throw VaultAuthoring.Failure.notOwned
        }
        guard let manifestData = request.files["manifest.json"] else { throw Failure.noManuals }
        let received = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
        guard !received.documents.isEmpty else { throw Failure.noManuals }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("VaultLinkManuals-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var taken = Set(target.documents.flatMap { [$0.file] + [$0.source].compactMap { $0 } } + target.files)
        var kept: [VaultDocumentCarry.Kept] = []
        for document in received.documents {
            let path = received.documentRelativePath(document)
            guard VaultArchiveReader.isSafeRelativePath(path), let data = request.files[path] else { continue }
            let ext = (document.file as NSString).pathExtension.lowercased()
            let file = VaultAuthoring.manualFileName(title: document.title, extension: ext, taken: taken)
            taken.insert(file)
            let local = folder.appendingPathComponent(file)
            try data.write(to: local, options: .atomic)
            var files = [file: local]
            var source: String?
            if let sourcePath = received.documentSourceRelativePath(document), VaultArchiveReader.isSafeRelativePath(sourcePath),
               let sourceData = request.files[sourcePath] {
                let name = (file as NSString).deletingPathExtension + ".original." + (sourcePath as NSString).pathExtension.lowercased()
                taken.insert(name)
                let url = folder.appendingPathComponent(name)
                try sourceData.write(to: url, options: .atomic)
                files[name] = url
                source = name
            }
            let added = VaultDocument(file: file, title: document.title, kind: document.kind, source: source,
                                      sourceUrl: document.sourceUrl, edition: document.edition,
                                      personalReadingCopy: document.personalReadingCopy,
                                      revision: VaultDocumentLedger.hash(of: data), origin: .technician)
            kept.append(.init(document: added, files: files))
        }
        guard !kept.isEmpty else { throw Failure.noManuals }
        let manifest = try await VaultDocumentCarry.relayOffMain(vaultId: vaultId, removing: [], adding: kept)
        return VaultLinkInstaller.Outcome(vaultId: vaultId, vaultName: manifest.name, warnings: [],
                                          needsDocumentSync: true, manifest: manifest)
    }
}
