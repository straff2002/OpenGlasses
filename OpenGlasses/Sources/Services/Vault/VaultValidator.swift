import Foundation

/// Validates a candidate vault directory (manifest.json + markdown + procedures/*.json) before it's
/// installed via `VaultImporter` (Plan H). Surfaces problems up front so a broken customer pack can't
/// be loaded mid-session.
enum VaultValidator {

    struct Result {
        let manifest: VaultManifest?
        let issues: [String]
        /// Advisory only — the pack still installs. Surfaced so an author sees them where they can act.
        let warnings: [String]
        var isValid: Bool { issues.isEmpty }

        init(manifest: VaultManifest?, issues: [String], warnings: [String] = []) {
            self.manifest = manifest
            self.issues = issues
            self.warnings = warnings
        }
    }

    /// Minimum grounding rules every vault must keep, regardless of what the uploaded manifest says.
    static let requiredRuleThemes = VaultPackRules.requiredRuleThemes

    /// Core-tier size above which the validator warns. The core is loaded whole into every turn's
    /// system prompt; content past this point belongs in the reference tier (`documents`).
    static let coreBudgetCharacters = 32_768

    /// Validate a directory laid out like a bundled vault.
    static func validate(directory: URL, manualOnly: Bool = false) -> Result {
        var issues: [String] = []
        var warnings: [String] = []
        let fm = FileManager.default

        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return Result(manifest: nil, issues: ["manifest.json is missing or unreadable"])
        }
        guard let manifest = try? JSONDecoder().decode(VaultManifest.self, from: data) else {
            return Result(manifest: nil, issues: ["manifest.json does not decode to a valid vault manifest"])
        }

        // The manifest's own rules and the listed files are the licence core's (`VaultPackRules`),
        // which the licence service also holds an uploaded company vault to before it signs it.
        issues.append(contentsOf: VaultPackRules.manifestIssues(VaultPackRules.Manifest(manifest), manualOnly: manualOnly))

        // Files present and non-empty.
        var coreCharacters = 0
        for file in manifest.files {
            let contents = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            if let issue = VaultPackRules.listedFileIssue(file, contents: contents) { issues.append(issue) }
            coreCharacters += contents?.count ?? 0
        }
        if coreCharacters > coreBudgetCharacters {
            warnings.append("core files total \(coreCharacters) characters (budget \(coreBudgetCharacters)); the core is loaded into every turn — move manuals and long references to 'documents' so they are retrieved instead")
        }

        // Reference documents: present, supported, and extractable.
        var seenDocumentFiles = Set<String>()
        for document in manifest.documents {
            if document.title.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("document has no title: \(document.file)")
            }
            if !seenDocumentFiles.insert(document.file).inserted {
                issues.append("document listed twice: \(document.file)")
            }
            // A folder whose manifest says the manuals were left behind is answered once per
            // manual, naming the text and the manufacturer's original together, rather than one
            // file at a time across repeated attempts.
            if !manifest.documentsIncluded {
                let expected = [manifest.documentRelativePath(document),
                                manifest.documentSourceRelativePath(document)].compactMap { $0 }
                let absent = expected.filter { !fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
                if !absent.isEmpty {
                    issues.append(notIncludedIssue(title: document.title, paths: absent)); continue
                }
            }
            let uploadedURL = directory.appendingPathComponent(manifest.documentRelativePath(document))
            let url: URL
            if document.personalReadingCopy == true {
                guard ManualFileUpload.extensions.subtracting(["pdf"]).contains(uploadedURL.pathExtension.lowercased()),
                      fm.fileExists(atPath: uploadedURL.path),
                      let source = manifest.documentSourceRelativePath(document),
                      (try? ManualLibraryAdmission.pageCount(directory.appendingPathComponent(source))) != nil else {
                    issues.append("uploaded manual needs its original file and a readable PDF reading copy: \(document.file)")
                    continue
                }
                url = directory.appendingPathComponent(source)
            } else { url = uploadedURL }
            guard fm.fileExists(atPath: url.path) else {
                issues.append("listed document missing: \(manifest.documentRelativePath(document))"); continue
            }
            issues.append(contentsOf: originalIssues(for: document, manifest: manifest, directory: directory))
            // A scan is not a refusal: it is read by recognition at import, which is slow, so the
            // author is told how much of it that covers and can find the original PDF first.
            if let survey = VaultDocumentExtractor.survey(url), survey.needsRecognition {
                if survey.pagesWithText == 0 {
                    warnings.append("\(document.file) has no text layer on \(survey.pageCount) of \(survey.pageCount) pages; it will be read by on-device recognition at import, which takes several minutes for a long manual")
                } else {
                    warnings.append("\(document.file) has no text layer on \(survey.pagesWithoutText) of \(survey.pageCount) pages; those pages will be read by on-device recognition at import")
                }
                continue
            }
            do {
                _ = try VaultDocumentExtractor.extract(from: url)
            } catch {
                issues.append("document cannot be imported — \(error.localizedDescription)")
            }
        }

        // Procedures decode + graph-validate, and each declares its own id: a scenario is addressed
        // by id everywhere (the Field Assist tab, `procedure` actions), so two files sharing one
        // would leave one of them unreachable.
        if let dir = manifest.proceduresDir {
            let proceduresURL = directory.appendingPathComponent(dir, isDirectory: true)
            let jsons = ((try? fm.contentsOfDirectory(at: proceduresURL, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "json" } ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var fileById: [String: String] = [:]
            for url in jsons {
                guard let pdata = try? Data(contentsOf: url),
                      let procedure = try? JSONDecoder().decode(Procedure.self, from: pdata) else {
                    issues.append(VaultPackRules.procedureDoesNotDecode(url.lastPathComponent)); continue
                }
                if let first = fileById[procedure.id] {
                    issues.append("procedure id \(procedure.id) is declared by both \(first) and \(url.lastPathComponent)")
                } else {
                    fileById[procedure.id] = url.lastPathComponent
                }
                issues.append(contentsOf: validateProcedureGraph(procedure).map { "\(procedure.id): \($0)" })
            }
        }

        // Rule chains (Plan JJ P2). Only a vault that lists a chains.md reaches this.
        let chainFiles = manifest.files.filter(VaultChains.isChainsFile)
        if !chainFiles.isEmpty {
            let chained = chainIssues(files: chainFiles, manifest: manifest, directory: directory)
            issues.append(contentsOf: chained.issues)
            warnings.append(contentsOf: chained.warnings)
        }

        // Checks of pictured tables (Plan JN P3): warnings only. A bad entry is skipped and one for
        // a PDF the vault does not hold is kept; the vault installs either way.
        let checksURL = directory.appendingPathComponent(TableChecksFile.fileName)
        if fm.fileExists(atPath: checksURL.path) {
            warnings.append(contentsOf: tableCheckWarnings(checksURL, manifest: manifest, directory: directory))
        }

        // Site documents (Plan HV). Only a manifest that lists them reaches this, so every vault
        // without them validates exactly as it did.
        if let sites = manifest.sites {
            let site = siteIssues(sites, manifest: manifest, directory: directory)
            issues.append(contentsOf: site.issues)
            warnings.append(contentsOf: site.warnings)
        }

        return Result(manifest: manifest, issues: issues, warnings: warnings)
    }

    /// A vault's rule chains: every step that does not read is an issue naming its line, as a
    /// procedure that does not decode is; a chain that names a table none of the vault's manuals
    /// prints is a warning — the chain is kept, `rule_chain list` marks it as needing the table,
    /// and it stops at that step until a manual that prints it is loaded. A table whose caption was
    /// found and whose grid could not be read counts as there: the chain stops on it with its page.
    static func chainIssues(files: [String], manifest: VaultManifest,
                            directory: URL) -> (issues: [String], warnings: [String]) {
        var issues: [String] = []
        var chains: [(file: String, chain: ChainDefinition)] = []
        for file in files {
            // A missing or empty file is already an issue above.
            guard let contents = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else {
                continue
            }
            let parsed = ChainParser.parse(contents)
            issues.append(contentsOf: parsed.problems.map { "\(file) \($0.description)" })
            chains += parsed.chains.map { (file, $0) }
        }
        let naming = chains.filter { !$0.chain.tableLabels.isEmpty }
        guard !naming.isEmpty else { return (issues, []) }
        let labels = tableLabels(manifest: manifest, directory: directory)
        let warnings = naming.compactMap { entry -> String? in
            let missing = entry.chain.missingTables(available: labels)
            return missing.isEmpty ? nil : missingTablesWarning(file: entry.file, chain: entry.chain.name, missing: missing)
        }
        return (issues, warnings)
    }

    static func missingTablesWarning(file: String, chain: String, missing: [String]) -> String {
        "\(file): the chain '\(chain)' needs \(missing.joined(separator: ", ")), which no manual in this vault prints "
            + "as a table the app could find; the chain is kept, marked as needing it, and stops at that step"
    }

    /// The labels of every captioned table the vault's manuals print, read or not, as an import
    /// stores them (`PDFTableReader.Result.stored`). Read only when a chain names a table.
    static func tableLabels(manifest: VaultManifest, directory: URL) -> [String] {
        manifest.documents.flatMap { document -> [String] in
            let url = directory.appendingPathComponent(manifest.documentRelativePath(document))
            let original = manifest.documentSourceRelativePath(document).map { directory.appendingPathComponent($0) }
            guard let pdf = VaultDocumentExtractor.tablesSource(document: url, original: original),
                  let result = VaultDocumentExtractor.tables(from: pdf) else { return [] }
            return result.stored.map(\.label)
        }
    }

    /// What an import says about a vault's `table-checks.json` (Plan JN P3): each entry that does
    /// not read, and each PDF the checks are for that the vault does not hold. Never a value.
    static func tableCheckWarnings(_ url: URL, manifest: VaultManifest, directory: URL) -> [String] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= TableChecksFile.maximumBytes else {
            return ["\(TableChecksFile.fileName) is larger than \(TableChecksFile.maximumBytes / 1_048_576) MB, so it was not read"]
        }
        guard let data = try? Data(contentsOf: url) else { return ["\(TableChecksFile.fileName) cannot be read"] }
        let parsed = TableChecksFile.parse(data)
        guard !parsed.checks.isEmpty else { return parsed.problems }
        return parsed.problems
            + TableChecksFile.unknownDocumentWarnings(parsed.checks, known: tablePDFHashes(manifest: manifest, directory: directory))
    }

    /// The SHA-256 of every PDF the vault's tables are read from, as the import keys them.
    static func tablePDFHashes(manifest: VaultManifest, directory: URL) -> Set<String> {
        Set(manifest.documents.compactMap { document -> String? in
            let url = directory.appendingPathComponent(manifest.documentRelativePath(document))
            let original = manifest.documentSourceRelativePath(document).map { directory.appendingPathComponent($0) }
            guard let pdf = VaultDocumentExtractor.tablesSource(document: url, original: original),
                  let data = try? Data(contentsOf: pdf) else { return nil }
            return VaultDocumentLedger.hash(of: data)
        })
    }

    /// The `sites` list, each file on its own against the vault's own model index, then across the
    /// files (Plan HV §2).
    static func siteIssues(_ sites: [String], manifest: VaultManifest,
                           directory: URL) -> (issues: [String], warnings: [String]) {
        var issues = SiteSystemValidator.pathIssues(sites)
        var warnings: [String] = []
        let core = manifest.files.compactMap { file -> (filename: String, contents: String)? in
            (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)).map { (file, $0) }
        }
        let covered = SiteSystemValidator.modelCovered(by: VaultModelIndex(vaultName: manifest.name, files: core))
        var passed: [(path: String, document: SiteSystemDocument)] = []
        for path in Array(NSOrderedSet(array: sites)) as? [String] ?? sites
        where SiteSystemValidator.isSitePath(path) {
            let url = directory.appendingPathComponent(path)
            // A plain file: never a link out of the folder, never a directory.
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                issues.append("listed site document missing: \(path)"); continue
            }
            // Refused unread when it is over the bound.
            if let size = values?.fileSize, size > SiteSystemValidator.maximumFileBytes {
                issues.append("\(path): is \(size) bytes; a site document may be at most \(SiteSystemValidator.maximumFileBytes)"); continue
            }
            guard let data = try? Data(contentsOf: url) else {
                issues.append("listed site document missing: \(path)"); continue
            }
            let result = SiteSystemValidator.check(data, path: path, modelCovered: covered)
            issues.append(contentsOf: result.issues)
            warnings.append(contentsOf: result.warnings)
            if let document = result.document { passed.append((path, document)) }
        }
        issues.append(contentsOf: SiteSystemValidator.crossDocumentIssues(passed))
        return (issues, warnings)
    }

    /// What a folder that came off a phone is missing. A vault exported from the app carries the
    /// manifest and marks it `documents_included: false` (Plan FS), because manuals never leave the
    /// phone through the app — so the manuals it lists are *required and absent*, which is a
    /// different thing to say than "this folder is broken", and the message names the files to
    /// supply. It is still an issue and never a warning: a vault must not install claiming manuals
    /// it has not got and then answer as though it had them.
    static func notIncludedIssue(title: String, paths: [String]) -> String {
        "manual not included in this export: \(title) — add \(paths.joined(separator: " and ")) to the folder before importing"
    }

    /// The manufacturer's original beside an extracted-text document (Plan EK P3): it has to be a
    /// PDF that is actually there, and a published link has to be a link, because both are shown to
    /// a technician as the manufacturer's own copy and neither can be checked later.
    static func originalIssues(for document: VaultDocument, manifest: VaultManifest, directory: URL) -> [String] {
        var issues: [String] = []
        if let relative = manifest.documentSourceRelativePath(document) {
            let source = document.source ?? relative
            if !source.lowercased().hasSuffix(".pdf") {
                issues.append("document source must be a PDF: \(source)")
            } else if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path) {
                issues.append("document source missing: \(relative)")
            }
        }
        if let link = document.sourceUrl, !link.trimmingCharacters(in: .whitespaces).isEmpty {
            let scheme = URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased()
            if scheme != "http" && scheme != "https" {
                issues.append("document source_url must be an http(s) link: \(link)")
            }
        }
        return issues
    }

    /// Validate one procedure's step graph: entry resolves, all branch/default targets resolve,
    /// no non-terminal dead ends, and a terminal step is reachable from entry. Returns issue strings.
    static func validateProcedureGraph(_ procedure: Procedure) -> [String] {
        var issues: [String] = []
        let stepIds = Set(procedure.steps.map(\.id))

        guard let entry = procedure.entry else { return ["no entry step / empty procedure"] }
        if procedure.steps.count != stepIds.count { issues.append("duplicate step ids") }

        for step in procedure.steps {
            for branch in step.branches where !stepIds.contains(branch.next) {
                issues.append("branch '\(branch.id)' on step '\(step.id)' → unknown step '\(branch.next)'")
            }
            if let next = step.defaultNext, !stepIds.contains(next) {
                issues.append("default_next on step '\(step.id)' → unknown step '\(next)'")
            }
            if !step.terminal && step.branches.isEmpty && step.defaultNext == nil {
                issues.append("non-terminal step '\(step.id)' has no outgoing transition (dead end)")
            }
        }

        // Reachability: BFS from entry; at least one terminal must be reachable.
        var visited = Set<String>()
        var queue = [entry.id]
        var reachedTerminal = false
        while let id = queue.popLast() {
            guard visited.insert(id).inserted, let step = procedure.step(id: id) else { continue }
            if step.terminal { reachedTerminal = true }
            queue.append(contentsOf: step.branches.map(\.next))
            if let next = step.defaultNext { queue.append(next) }
        }
        if !reachedTerminal { issues.append("no terminal step is reachable from entry") }

        return issues
    }
}
