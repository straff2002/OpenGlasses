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
    static let requiredRuleThemes = ["fabricate", "cite"]

    /// Core-tier size above which the validator warns. The core is loaded whole into every turn's
    /// system prompt; content past this point belongs in the reference tier (`documents`).
    static let coreBudgetCharacters = 32_768

    /// Validate a directory laid out like a bundled vault.
    static func validate(directory: URL) -> Result {
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

        if manifest.id.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("manifest id is empty") }
        if manifest.files.isEmpty && manifest.documents.isEmpty {
            issues.append("manifest lists no files and no documents")
        }
        if manifest.promptRules.isEmpty {
            issues.append("manifest must include prompt_rules (grounding discipline)")
        } else {
            let joined = manifest.promptRules.joined(separator: " ").lowercased()
            for theme in requiredRuleThemes where !joined.contains(theme) {
                issues.append("prompt_rules should address '\(theme)' (anti-fabrication / source citation)")
            }
        }

        // Files present and non-empty.
        var coreCharacters = 0
        for file in manifest.files {
            let url = directory.appendingPathComponent(file)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                issues.append("listed file missing: \(file)"); continue
            }
            if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("listed file is empty: \(file)")
            }
            coreCharacters += contents.count
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
            let url = directory.appendingPathComponent(manifest.documentRelativePath(document))
            guard fm.fileExists(atPath: url.path) else {
                issues.append("listed document missing: \(manifest.documentRelativePath(document))"); continue
            }
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

        // Procedures decode + graph-validate.
        if let dir = manifest.proceduresDir {
            let proceduresURL = directory.appendingPathComponent(dir, isDirectory: true)
            let jsons = (try? fm.contentsOfDirectory(at: proceduresURL, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "json" } ?? []
            for url in jsons {
                guard let pdata = try? Data(contentsOf: url),
                      let procedure = try? JSONDecoder().decode(Procedure.self, from: pdata) else {
                    issues.append("procedure does not decode: \(url.lastPathComponent)"); continue
                }
                issues.append(contentsOf: validateProcedureGraph(procedure).map { "\(procedure.id): \($0)" })
            }
        }

        return Result(manifest: manifest, issues: issues, warnings: warnings)
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
