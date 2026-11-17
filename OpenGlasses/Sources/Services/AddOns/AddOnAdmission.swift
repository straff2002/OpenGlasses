import Foundation

/// Where an installed add-on came from. **Store metadata, never a field in the file**: the file
/// stays a plain `avenkin.addon/1` document wherever it travels, and what this phone knows about
/// its history stays on this phone.
enum AddOnOrigin: Codable, Equatable, Sendable {
    /// The wearer installed it from a link, a QR code, a file or the gallery.
    case installed(via: AddOnInstallSource)
    /// The assistant built it on this phone at the wearer's request and the wearer approved it on
    /// the sheet (the self-built add-on flow). Shown as "Built by your assistant".
    case selfBuilt(SelfBuiltAddOnProvenance)

    var isSelfBuilt: Bool {
        if case .selfBuilt = self { return true }
        return false
    }
}

/// How an installed add-on reached the phone.
enum AddOnInstallSource: String, Codable, Equatable, Sendable {
    /// `openglasses://install-addon?url=…`, by a link or a scanned code.
    case link
    /// A file opened from Files, AirDrop or Mail.
    case file
    /// The add-on gallery.
    case gallery
    /// Referenced by the organisation's profile and installed at enrolment.
    case organisation
}

/// The record of a self-built add-on's making: which authoring session produced it, the goal the
/// wearer asked for in their own words, and when it was approved. Kept only on this phone.
struct SelfBuiltAddOnProvenance: Codable, Equatable, Sendable {
    let sessionID: String
    let goal: String
    let builtAt: Date
}

/// An add-on file that has been resolved, decoded and validated and may be offered on the sheet.
/// Nothing here has been written anywhere.
struct AddOnCandidate: Equatable, Sendable {
    let manifest: RecipeAddOnManifest
    /// The exact add-on file bytes — what is stored, run and exported.
    let fileBytes: Data
    /// The signed envelope the file arrived in, kept only when its signature verified, so an
    /// export carries the signature and a later launch can check it again.
    let envelopeBytes: Data?
    let trust: AddOnTrustClass
    /// It arrived signed but the signature did not verify; it is offered as a community add-on
    /// and the sheet says why it lost its badge.
    let signatureFailure: AddOnSignature.Failure?

    /// The sheet's permission lines, the fixed "can never reach…" line last.
    var permissionLines: [AddOnPermissionSummary.Line] {
        AddOnPermissionSummary.lines(for: manifest.permissions)
    }

    /// "Reviewed" is shown only for a vendor signature.
    var isReviewed: Bool { trust == .vendorSigned }

    /// The domain of `author.web`, which is all the sheet shows of it.
    var authorDomain: String? {
        guard let web = manifest.author.web, let host = URL(string: web)?.host?.lowercased() else { return nil }
        return host
    }
}

/// Admission for an add-on that arrived by link, file or the assistant: resolve its signature,
/// decode and validate it, apply the organisation's policy and the app's own limits, and say
/// whether it is a new install, an update (with its diff) or refused. Pure over its inputs.
enum AddOnAdmission {

    /// What admission knows about the phone. Production values come from `AddOnLiveContext`.
    struct Context: Sendable {
        var vendorKeys: [String: String] = AddOnSignature.productionVendorKeys
        /// The organisations the phone is enrolled with: id → administrator public key (base64).
        var trustedOrganisations: [String: String] = [:]
        var policy: AddOnPolicy = .unmanaged
        /// The app's own tool names, for the definition screen's collision check.
        var nativeToolNames: Set<String> = []
        /// This build's number, for an add-on's `minAppBuild`.
        var currentBuild: Int = 0
    }

    /// What is already installed under the same id.
    struct Installed: Equatable, Sendable {
        let version: String
        let manifest: RecipeAddOnManifest?
    }

    enum Outcome: Equatable, Sendable {
        case install(AddOnCandidate)
        case update(AddOnCandidate, diff: AddOnUpdateDiff?)
        /// Plain-words reasons, first the headline.
        case refused([String])

        var candidate: AddOnCandidate? {
            switch self {
            case .install(let c), .update(let c, _): return c
            case .refused: return nil
            }
        }
    }

    /// Admit the bytes as they arrived (a bare file or a signed envelope).
    static func review(_ data: Data, installed: (String) -> Installed?, context: Context) -> Outcome {
        guard data.count <= AddOnSignature.maxEnvelopeBytes else {
            return .refused([String(localized: "This add-on file is too large.")])
        }
        let resolution: AddOnSignature.Resolution
        do {
            resolution = try AddOnSignature.resolve(data, vendorKeys: context.vendorKeys,
                                                    trustedOrganisations: context.trustedOrganisations)
        } catch {
            return .refused([String(localized: "This isn't an add-on file: its signature wrapper is damaged.")])
        }
        guard resolution.fileBytes.count <= AddOnSignature.maxFileBytes else {
            return .refused([String(localized: "This add-on file is too large.")])
        }
        let report = RecipeAddOnValidator.validate(resolution, nativeToolNames: context.nativeToolNames)
        guard let manifest = report.manifest else {
            return .refused([String(localized: "This isn't an add-on file.")] + report.issues.map(\.description))
        }
        guard report.issues.isEmpty else {
            return .refused([String(localized: "This add-on can't be installed: it breaks the add-on rules.")]
                            + report.issues.map(\.description))
        }
        if let refusal = refusal(for: manifest, trust: resolution.trust, context: context) {
            return .refused([refusal])
        }
        let candidate = AddOnCandidate(
            manifest: manifest,
            fileBytes: resolution.fileBytes,
            envelopeBytes: resolution.wasSigned && resolution.failure == nil ? data : nil,
            trust: resolution.trust,
            signatureFailure: resolution.failure)
        guard let existing = installed(manifest.id) else { return .install(candidate) }
        guard AddOnVersion.isNewer(manifest.version, than: existing.version) else {
            if AddOnVersion.compare(manifest.version, existing.version) == .orderedSame {
                return .refused([String(localized: "Version \(manifest.version) of \(manifest.name) is already installed.")])
            }
            return .refused([String(localized: "This is an older version of \(manifest.name) (\(manifest.version)) than the one installed (\(existing.version)).")])
        }
        return .update(candidate, diff: existing.manifest.map { AddOnUpdateDiff(from: $0, to: manifest) })
    }

    /// Why an otherwise valid add-on may not be installed here, or nil.
    static func refusal(for manifest: RecipeAddOnManifest, trust: AddOnTrustClass, context: Context) -> String? {
        if let reason = context.policy.refusal(for: trust) { return message(for: reason) }
        if manifest.mcp != nil {
            return String(localized: "Add-ons that connect a server aren't supported in this version of the app.")
        }
        if let needed = manifest.minAppBuild, needed > context.currentBuild {
            return String(localized: "\(manifest.name) needs a newer version of the app.")
        }
        return nil
    }

    static func message(for refusal: AddOnPolicy.Refusal) -> String {
        switch refusal {
        case .addOnsDisabled:
            return String(localized: "Your organisation has turned add-ons off on this phone.")
        case .communityNotAllowed:
            return String(localized: "Your organisation allows only signed add-ons on this phone.")
        case .notSignedByOrganisation:
            return String(localized: "Your organisation allows only its own add-ons on this phone.")
        case .otherOrganisation:
            return String(localized: "This add-on belongs to another organisation.")
        }
    }
}

/// A change to an installed add-on's source, typed on the phone (Settings → Add-ons → Source).
/// Pure: the edited text is validated as a community file — an edit drops any signature — with
/// the same id; growing permissions sends it back through the sheet.
enum AddOnSourceEdit {

    enum Outcome: Equatable, Sendable {
        /// The text is the installed file, byte for byte.
        case unchanged
        /// Not saveable; plain words first, then the validator's located issues.
        case invalid([String])
        /// Saveable. `needsApproval` when it may now do something the installed version could not
        /// (a new domain or a new permission): the sheet is shown again before it is saved.
        case saveable(AddOnCandidate, diff: AddOnUpdateDiff, needsApproval: Bool)
    }

    static func review(_ text: String, installedBytes: Data, installed: RecipeAddOnManifest,
                       context: AddOnAdmission.Context) -> Outcome {
        let data = Data(text.utf8)
        if data == installedBytes { return .unchanged }
        guard data.count <= AddOnSignature.maxFileBytes else {
            return .invalid([String(localized: "The add-on is too large.")])
        }
        // An edited file is never an envelope: whatever was signed, this text is the wearer's.
        guard !AddOnSignature.looksLikeEnvelope(data) else {
            return .invalid([String(localized: "Paste the add-on itself, not a signed copy.")])
        }
        let report = RecipeAddOnValidator.validate(data: data, nativeToolNames: context.nativeToolNames,
                                                   trust: .community)
        guard let manifest = report.manifest, report.issues.isEmpty else {
            return .invalid([String(localized: "This can't be saved yet.")] + report.issues.map(\.description))
        }
        guard manifest.id == installed.id else {
            return .invalid([String(localized: "The id can't change in an edit. Install it as a new add-on instead.")])
        }
        if let refusal = AddOnAdmission.refusal(for: manifest, trust: .community, context: context) {
            return .invalid([refusal])
        }
        let candidate = AddOnCandidate(manifest: manifest, fileBytes: data, envelopeBytes: nil,
                                       trust: .community, signatureFailure: nil)
        let diff = AddOnUpdateDiff(from: installed, to: manifest)
        return .saveable(candidate, diff: diff, needsApproval: diff.permissionsGrew)
    }
}
