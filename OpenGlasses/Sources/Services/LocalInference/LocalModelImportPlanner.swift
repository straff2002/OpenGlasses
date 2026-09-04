import Foundation

/// Turning a parsed repository reference into an exact, verifiable set of files
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Import parsing").
///
/// Three rules shape everything here:
///
///  1. **Resolve to an exact revision before a plan exists.** A branch name is not installable
///     metadata, so the planner asks the repository what `main` currently *is* and pins the answer.
///  2. **Structured metadata only.** The two network seams return JSON from the repository's own
///     API. Nothing scrapes HTML, follows a model card link, or executes a repository script —
///     Plan DZ's non-goal list is explicit about that.
///  3. **A quantization label is display text.** It comes from the filename, so it is a caption,
///     never evidence about what the file contains. Nothing in this file infers a capability, a
///     context length or an architecture from a name.

// MARK: - Remote metadata shapes

/// What the repository says about itself at one moment. `revision` is the whole reason to ask.
struct LocalModelRepositoryMetadata: Equatable, Sendable {
    /// Exact immutable revision the default branch points at right now.
    let revision: String
    /// SPDX-ish licence identifier from the model card, when it declares one.
    let licenseIdentifier: String?
    /// Whether the repository requires accepting terms or credentials to download. The first
    /// importer is public-only, so a gated repository is refused rather than half-supported.
    let isGated: Bool
    let isPrivate: Bool
}

/// One file in the repository at that revision.
struct LocalModelRemoteFile: Equatable, Sendable {
    let path: String
    let byteCount: Int64
    /// SHA-256 as recorded by the repository's large-file store. `nil` for a file it does not
    /// track that way — such a file can be listed but can never be installed, because there is
    /// nothing to verify the download against.
    let sha256: String?
}

/// The two network seams, injected so every enumeration, grouping and refusal rule is exercised
/// headlessly against fixtures.
protocol LocalModelRepositoryMetadataFetching: Sendable {
    func metadata(for reference: LocalModelRepositoryReference) async throws -> LocalModelRepositoryMetadata
    func files(for reference: LocalModelRepositoryReference,
               revision: String) async throws -> [LocalModelRemoteFile]
}

// MARK: - Faults

/// Why an import cannot proceed past enumeration. Separate from `LocalModelImportRejection`, which
/// is about the string; these are about what the repository turned out to contain.
enum LocalModelImportFault: Error, Equatable, Sendable {
    /// The repository did not name an exact revision, or named one that is not a full commit hash.
    case revisionNotResolved
    /// Gated or private. The first importer supports anonymous public repositories only.
    case repositoryNotPublic
    /// No `.gguf` file at that revision.
    case noEligibleFiles
    /// Every eligible file is missing the size or digest that installation requires.
    case noVerifiableFiles
    /// A listed path is not contained beneath the model root once normalized.
    case pathOutsideModelRoot
    /// The chosen candidate is not one this offer enumerated.
    case unknownSelection
}

// MARK: - Candidates

/// One installable choice: a single `.gguf` file, or the complete set of shards of one.
///
/// Shards are grouped because offering one shard of three would install a model that can never
/// load — and because the *grouping* rule is the only part of a filename this file is willing to
/// act on, since it decides completeness rather than capability.
struct LocalModelImportCandidate: Equatable, Sendable, Identifiable {
    /// Stable within an offer: the group's base name, which is also the file name for a single
    /// unsharded file.
    let id: String
    /// Files that must all be installed together, in listing order.
    let files: [LocalModelRemoteFile]
    /// Display-only quantization caption parsed from the file name, e.g. `Q4_K_M`. Never trust
    /// evidence: a repack under a different name must not change what the app believes.
    let quantizationLabel: String?
    let role: LocalModelFile.Role

    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    /// Whether this candidate can be installed at all. Missing size or digest is not a warning:
    /// there would be nothing to verify the bytes against, and an unverifiable install is exactly
    /// what the integrity rules exist to prevent.
    var isInstallable: Bool {
        !files.isEmpty && files.allSatisfy { $0.byteCount > 0 && ($0.sha256?.isEmpty == false) }
    }

    /// Model files, in the descriptor's shape. Empty when the candidate is not installable, so an
    /// unverifiable candidate cannot leak into a descriptor by a caller forgetting to check.
    func modelFiles() -> [LocalModelFile] {
        guard isInstallable else { return [] }
        return files.compactMap { file in
            guard case .contained(let normalized) = LocalModelPath.normalize(file.path),
                  let digest = file.sha256 else { return nil }
            return LocalModelFile(relativePath: normalized,
                                  byteCount: file.byteCount,
                                  sha256: digest.lowercased(),
                                  role: role)
        }
    }
}

/// Everything a consent screen needs about an import, before any bytes move.
struct LocalModelImportOffer: Equatable, Sendable {
    let reference: LocalModelRepositoryReference
    /// The exact revision every candidate was enumerated at.
    let revision: String
    let license: LocalModelLicenseSummary
    /// Weights candidates, largest last so the cheapest option reads first.
    let weights: [LocalModelImportCandidate]
    /// Multimodal projectors found alongside the weights. Listed so the user can see they exist;
    /// the text-only runtime does not install them, and their presence claims nothing about
    /// whether this build could use them.
    let projectors: [LocalModelImportCandidate]
    /// A curated default, present only when the exact preferred file exists. `nil` means the user
    /// must choose — the plan forbids picking "something close" on their behalf.
    let defaultSelection: LocalModelImportCandidate?

    var requiresSelection: Bool { defaultSelection == nil }
}

// MARK: - Planner

/// Resolves a reference to a revision, enumerates its files, and builds descriptors from a choice.
struct LocalModelImportPlanner: Sendable {

    /// The one quantization the app will pick unaided. Chosen because it is the quality/size
    /// balance a phone can actually hold; anything else is a decision the user makes.
    static let preferredQuantizationLabel = "Q4_K_M"

    /// Context window a freshly imported model is given until something better is known.
    ///
    /// It is the conservative default the budget already applies to unknown ids, *not* the file's
    /// trained context: the runtime reads the real value out of the GGUF at load time and clamps
    /// from there. Writing a name-derived window into a descriptor would be the guess the plan
    /// forbids.
    static let importedContextTokens = LocalModelBudget.defaultContextWindow

    let fetcher: any LocalModelRepositoryMetadataFetching

    init(fetcher: any LocalModelRepositoryMetadataFetching) {
        self.fetcher = fetcher
    }

    /// Resolve and enumerate. Throws `LocalModelImportFault` on anything that makes an install
    /// impossible; a repository with unverifiable extras but at least one verifiable weights file
    /// succeeds, with the unverifiable candidates listed and marked.
    func offer(for reference: LocalModelRepositoryReference) async throws -> LocalModelImportOffer {
        let metadata = try await fetcher.metadata(for: reference)
        guard !metadata.isGated, !metadata.isPrivate else {
            throw LocalModelImportFault.repositoryNotPublic
        }
        guard LocalModelRepositoryReference.isValidRevision(metadata.revision) else {
            throw LocalModelImportFault.revisionNotResolved
        }

        let listing = try await fetcher.files(for: reference, revision: metadata.revision)
        return try Self.makeOffer(reference: reference, metadata: metadata, files: listing)
    }

    /// The pure half: grouping, classification and default selection over an already-fetched
    /// listing. Everything the exit criteria care about is testable through this entry point.
    static func makeOffer(reference: LocalModelRepositoryReference,
                          metadata: LocalModelRepositoryMetadata,
                          files: [LocalModelRemoteFile]) throws -> LocalModelImportOffer {
        let eligible = files.filter { file in
            file.path.lowercased().hasSuffix(".gguf")
        }
        guard !eligible.isEmpty else { throw LocalModelImportFault.noEligibleFiles }

        // A path that does not normalize into the model root is refused for the whole offer, not
        // silently dropped: a listing containing a traversal is a listing to walk away from.
        for file in eligible {
            guard case .contained = LocalModelPath.normalize(file.path) else {
                throw LocalModelImportFault.pathOutsideModelRoot
            }
        }

        let projectorFiles = eligible.filter { GGUFFileName.isProjector($0.path) }
        let weightsFiles = eligible.filter { !GGUFFileName.isProjector($0.path) }

        let weights = candidates(from: weightsFiles, role: .weights)
        let projectors = candidates(from: projectorFiles, role: .projector)
        guard weights.contains(where: \.isInstallable) else {
            throw LocalModelImportFault.noVerifiableFiles
        }

        // "Prefer a curated default only when the exact file is present" — one installable
        // candidate carrying exactly the preferred label, or nobody chooses but the user.
        let preferred = weights.filter {
            $0.isInstallable && $0.quantizationLabel == preferredQuantizationLabel
        }
        let defaultSelection = preferred.count == 1 ? preferred.first : nil

        return LocalModelImportOffer(
            reference: reference,
            revision: metadata.revision,
            license: LocalModelLicenseSummary.imported(identifier: metadata.licenseIdentifier,
                                                       revision: metadata.revision),
            weights: weights,
            projectors: projectors,
            defaultSelection: defaultSelection)
    }

    /// Group shards, caption quantizations, and sort smallest-first.
    private static func candidates(from files: [LocalModelRemoteFile],
                                   role: LocalModelFile.Role) -> [LocalModelImportCandidate] {
        var groups: [String: [LocalModelRemoteFile]] = [:]
        var order: [String] = []
        for file in files {
            let key = GGUFFileName.groupKey(for: file.path)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        return order.map { key in
            let members = (groups[key] ?? []).sorted { $0.path < $1.path }
            return LocalModelImportCandidate(
                id: key,
                files: members,
                quantizationLabel: GGUFFileName.quantizationLabel(for: members.first?.path ?? key),
                role: role)
        }
        .sorted { ($0.byteCount, $0.id) < ($1.byteCount, $1.id) }
    }

    /// Build the descriptor an install plan is made from.
    ///
    /// Capabilities are `.text` and nothing else. A GGUF that loads is a text model as far as this
    /// build is concerned; `.vision` needs the multimodal phase and `.toolFriendly` needs the
    /// tool-call conformance fixture the plan requires before a badge is granted.
    static func descriptor(for candidate: LocalModelImportCandidate,
                           in offer: LocalModelImportOffer,
                           displayName: String? = nil) throws -> LocalModelDescriptor {
        guard offer.weights.contains(candidate) || offer.projectors.contains(candidate) else {
            throw LocalModelImportFault.unknownSelection
        }
        guard candidate.isInstallable else { throw LocalModelImportFault.noVerifiableFiles }
        let files = candidate.modelFiles()
        guard files.count == candidate.files.count else { throw LocalModelImportFault.pathOutsideModelRoot }

        let weightsBytes = candidate.byteCount
        return LocalModelDescriptor(
            id: LocalModelID.gguf(repositoryID: offer.reference.repositoryID, fileGroup: candidate.id),
            displayName: displayName ?? "\(offer.reference.repository) · \(candidate.quantizationLabel ?? candidate.id)",
            runtime: .llamaCpp,
            repositoryID: offer.reference.repositoryID,
            revision: offer.revision,
            files: files,
            quantization: candidate.quantizationLabel,
            capabilities: [.text],
            contextLength: importedContextTokens,
            estimatedWeightsBytes: weightsBytes,
            estimatedWorkingBytes: LocalModelBudget.workingSetBytes(for: .llamaCpp),
            minimumHeadroomBytes: weightsBytes + LocalModelBudget.workingSetBytes(for: .llamaCpp),
            license: offer.license)
    }
}

// MARK: - Identity

extension LocalModelID {
    /// A GGUF model's id: the repository plus the file group inside it, because one repository
    /// publishes a dozen quantizations of the same weights and each is a separate installation.
    ///
    /// `#` cannot appear in a repository name, so the join is unambiguous, and `storageComponent`
    /// percent-encodes it before it reaches a directory name.
    static func gguf(repositoryID: String, fileGroup: String) -> LocalModelID {
        LocalModelID("\(repositoryID)#\(fileGroup)")
    }
}

// MARK: - Licence

extension LocalModelLicenseSummary {
    /// Licences the app can describe from an identifier alone.
    ///
    /// Everything outside this table stays `.unverified` and says so. Summarizing a licence the
    /// app has not read would be the same category of claim as inventing a digest.
    static let describedIdentifiers: [String: (name: String, summary: String, requiresAcceptance: Bool)] = [
        "apache-2.0": ("Apache License 2.0",
                       "Permissive: use, modify and redistribute, keeping the notices and stating "
                           + "changes. Includes a patent grant.",
                       false),
        "mit": ("MIT License",
                "Permissive: use, modify and redistribute, keeping the copyright notice.",
                false),
        "bsd-3-clause": ("BSD 3-Clause License",
                         "Permissive: redistribute with the notice, without using the authors' "
                             + "names to endorse derived work.",
                         false),
        "cc-by-4.0": ("Creative Commons Attribution 4.0",
                      "Permissive with attribution: credit the author and note any changes.",
                      false),
        "cc-by-sa-4.0": ("Creative Commons Attribution-ShareAlike 4.0",
                         "Attribution plus share-alike: derived work carries the same licence.",
                         false),
    ]

    /// Summary for an imported repository. Unknown or absent identifiers are `.unverified` with
    /// acceptance required, which is the honest reading of "nobody here has read these terms".
    static func imported(identifier: String?, revision: String) -> LocalModelLicenseSummary {
        guard let identifier = identifier?.lowercased(),
              let described = describedIdentifiers[identifier] else {
            return LocalModelLicenseSummary(
                displayName: identifier.map { $0.uppercased() } ?? "Unknown licence",
                summary: "This model's terms have not been reviewed in the app. Read them on the "
                    + "repository page before installing.",
                requiresAcceptance: true,
                revision: nil)
        }
        return LocalModelLicenseSummary(displayName: described.name,
                                        summary: described.summary,
                                        requiresAcceptance: described.requiresAcceptance,
                                        revision: revision)
    }
}

// MARK: - File names

/// The only place a GGUF *file name* is read, and only for two decisions: which files belong
/// together, and what caption to show.
///
/// Neither decision is a claim about the file's contents. Architecture, context length, chat
/// template and capabilities all come from the file's own metadata at load time
/// (`GGUFMetadataValidator`), never from here.
enum GGUFFileName {

    /// Quantization captions, longest first so `Q4_K_M` wins over `Q4_K` and `IQ4_XS` over `Q4`.
    static let knownLabels: [String] = [
        "IQ1_S", "IQ1_M", "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M", "IQ3_XXS", "IQ3_XS", "IQ3_S",
        "IQ3_M", "IQ4_XS", "IQ4_NL",
        "Q2_K_L", "Q2_K_S", "Q2_K",
        "Q3_K_L", "Q3_K_M", "Q3_K_S", "Q3_K",
        "Q4_K_M", "Q4_K_S", "Q4_K", "Q4_0", "Q4_1",
        "Q5_K_M", "Q5_K_S", "Q5_K", "Q5_0", "Q5_1",
        "Q6_K_L", "Q6_K",
        "Q8_0", "Q8_K",
        "BF16", "FP16", "F16", "FP32", "F32",
    ]

    /// A projector file by the `mmproj` naming convention.
    ///
    /// Used for exactly one thing: keeping a projector out of the weights list, so a text-only
    /// install cannot pick one by accident. It never grants `.vision` and never claims the
    /// projector matches anything — that is the multimodal phase's evidence to produce.
    static func isProjector(_ path: String) -> Bool {
        fileName(path).lowercased().contains("mmproj")
    }

    /// Key that groups a sharded model's parts (`…-00001-of-00003.gguf`) under one candidate. An
    /// unsharded file is its own group.
    static func groupKey(for path: String) -> String {
        let name = fileName(path)
        guard let range = shardSuffixRange(in: name) else { return name }
        return String(name[name.startIndex..<range.lowerBound]) + ".gguf"
    }

    /// The `-NNNNN-of-NNNNN.gguf` tail, when present.
    private static func shardSuffixRange(in name: String) -> Range<String.Index>? {
        guard name.lowercased().hasSuffix(".gguf") else { return nil }
        let stem = String(name.dropLast(5))
        // `-00001-of-00003`: two fixed-width numbers joined by `-of-`.
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[parts.count - 2] == "of",
              parts[parts.count - 1].count == 5, parts[parts.count - 1].allSatisfy(\.isNumber),
              parts[parts.count - 3].count == 5, parts[parts.count - 3].allSatisfy(\.isNumber)
        else { return nil }
        let tailLength = parts[parts.count - 3].count + 1 + 2 + 1 + parts[parts.count - 1].count + 1
        guard stem.count >= tailLength else { return nil }
        let start = name.index(name.startIndex, offsetBy: stem.count - tailLength)
        return start..<name.endIndex
    }

    /// Display caption, or nil when the name carries no recognised quantization token.
    static func quantizationLabel(for path: String) -> String? {
        let upper = fileName(path).uppercased()
        for label in knownLabels where containsToken(label, in: upper) { return label }
        return nil
    }

    /// Token match on `-`, `.` or `_` boundaries, so `Q4_0` in `MODELQ4_0X` is not a caption.
    private static func containsToken(_ token: String, in name: String) -> Bool {
        var searchRange = name.startIndex..<name.endIndex
        while let found = name.range(of: token, range: searchRange) {
            let beforeOK = found.lowerBound == name.startIndex
                || isBoundary(name[name.index(before: found.lowerBound)])
            let afterOK = found.upperBound == name.endIndex || isBoundary(name[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.upperBound < name.endIndex else { return false }
            searchRange = found.upperBound..<name.endIndex
        }
        return false
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == "-" || character == "." || character == "_"
    }

    private static func fileName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }
}
