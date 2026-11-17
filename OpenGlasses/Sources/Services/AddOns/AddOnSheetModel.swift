import Foundation

/// What the install, update and edit sheets show, worked out from a review (Plan GF P2). Pure, so
/// the wording and the highlighting are tested without a view: a sheet is the trust decision, and
/// what it leaves out matters as much as what it says.
struct AddOnSheetModel: Equatable {

    enum Emphasis: Equatable {
        case normal
        /// New in this version: highlighted.
        case added
        /// Gone in this version.
        case removed
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let text: String
        let emphasis: Emphasis
    }

    enum Badge: Equatable {
        /// Signed by the vendor. Never shown for anything else.
        case reviewed
        /// Signed by the enrolled organisation.
        case organisation
        case builtByAssistant
        /// A file shaped like one an assistant built, received from someone else: a note, never
        /// trust (anyone can write such an id).
        case builtByAnotherAssistant
        case editedOnPhone

        var text: String {
            switch self {
            case .reviewed: return String(localized: "Reviewed")
            case .organisation: return String(localized: "From your organisation")
            case .builtByAssistant: return String(localized: "Built by your assistant")
            case .builtByAnotherAssistant: return String(localized: "Built by an assistant on another phone")
            case .editedOnPhone: return String(localized: "Edited on this phone")
            }
        }
    }

    /// The Tested panel: what the assistant's one test of the add-on did.
    struct Tested: Equatable {
        let question: String
        let answer: String
        let domains: String
        let time: String
        let source: String
        /// Spoken by VoiceOver as one element.
        var accessibilityText: String {
            String(localized: "Tested. Asked: \(question). It answered: \(answer). Contacted \(domains). Took \(time).")
        }
    }

    let title: String
    let name: String
    let version: String
    let icon: String?
    let byline: String
    let summary: String
    let badges: [Badge]
    /// Shown above everything when a signature did not verify.
    let notice: String?
    let changes: [Row]
    let skills: [Row]
    let permissions: [Row]
    let confirmTitle: String
    /// Only for an add-on the assistant built and tested.
    let tested: Tested?
    /// Under the buttons' meaning: cancelling a built add-on deletes it.
    let cancelNote: String?

    init(review: AddOnInstallService.Review) {
        let candidate = review.candidate
        let manifest = candidate.manifest
        name = manifest.name
        version = manifest.version
        icon = manifest.icon
        summary = manifest.description
        let builtHere = review.origin.isSelfBuilt
        let builtElsewhere = !builtHere && SelfBuiltIdentity.isSelfBuiltID(manifest.id)
            && manifest.author.name == SelfBuiltIdentity.authorName
        switch (builtHere, builtElsewhere, candidate.authorDomain) {
        case (true, _, let domain?):
            byline = String(localized: "Built by your assistant · data from \(domain)")
        case (true, _, nil):
            byline = String(localized: "Built by your assistant")
        case (false, true, let domain?):
            byline = String(localized: "Built by an assistant on another phone · data from \(domain)")
        case (false, true, nil):
            byline = String(localized: "Built by an assistant on another phone")
        case (false, false, let domain?):
            byline = String(localized: "By \(manifest.author.name) · \(domain)")
        case (false, false, nil):
            byline = String(localized: "By \(manifest.author.name)")
        }

        var badges: [Badge] = []
        switch candidate.trust {
        case .vendorSigned: badges.append(.reviewed)
        case .organisationSigned: badges.append(.organisation)
        case .community: break
        }
        if builtHere { badges.append(.builtByAssistant) }
        if builtElsewhere { badges.append(.builtByAnotherAssistant) }
        if case .edit = review.kind { badges.append(.editedOnPhone) }
        self.badges = badges

        notice = candidate.signatureFailure == nil ? nil
            : String(localized: "Its signature didn't check out, so it is treated like any add-on nobody has reviewed.")

        let diff: AddOnUpdateDiff?
        switch review.kind {
        case .install:
            title = String(localized: "Install \(manifest.name)?")
            confirmTitle = String(localized: "Install")
            diff = nil
        case .update(let d):
            title = String(localized: "Update \(manifest.name)?")
            confirmTitle = String(localized: "Update")
            diff = d
        case .edit(let d):
            title = String(localized: "Save your changes to \(manifest.name)?")
            confirmTitle = String(localized: "Save")
            diff = d
        }
        changes = diff.map(Self.changeRows) ?? []

        let addedSkills = Set(diff?.skillsAdded ?? [])
        let changedSkills = Set(diff?.skillsChanged ?? [])
        var skillRows = manifest.skills.map { skill -> Row in
            let emphasis: Emphasis = addedSkills.contains(skill.name) || changedSkills.contains(skill.name) ? .added : .normal
            return Row(id: "skill-\(skill.name)", text: skill.description, emphasis: emphasis)
        }
        for removed in diff?.skillsRemoved ?? [] {
            skillRows.append(Row(id: "skill-removed-\(removed)",
                                 text: String(localized: "No longer: \(removed)"), emphasis: .removed))
        }
        skills = skillRows

        let addedKinds = Set((diff?.permissionsAdded ?? []).map(\.rawValue))
        let networkGrew = !(diff?.domainsAdded.isEmpty ?? true)
        permissions = AddOnPermissionSummary.lines(for: manifest.permissions).map { line in
            let grew = (line.kind == .network && networkGrew) || addedKinds.contains(line.kind.rawValue)
            return Row(id: "permission-\(line.kind.rawValue)", text: line.text, emphasis: grew ? .added : .normal)
        }

        if let summary = review.tested {
            let domains = summary.domainsContacted.isEmpty
                ? String(localized: "nothing")
                : summary.domainsContacted.formatted(.list(type: .and))
            let answer = summary.spokenAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            tested = Tested(question: summary.sampleQuestion,
                            answer: answer.isEmpty ? String(localized: "(nothing)") : answer,
                            domains: domains, time: summary.elapsedText, source: summary.sourceText)
            cancelNote = String(localized: "Cancel deletes this add-on and its test. Nothing is installed unless you tap \(confirmTitle).")
        } else {
            tested = nil
            cancelNote = nil
        }
    }

    /// The update's own list: what it adds (highlighted) and what it gives up.
    static func changeRows(_ diff: AddOnUpdateDiff) -> [Row] {
        var rows: [Row] = []
        for domain in diff.domainsAdded {
            rows.append(Row(id: "domain+\(domain)", text: String(localized: "Now connects to: \(domain)"), emphasis: .added))
        }
        for permission in diff.permissionsAdded {
            rows.append(Row(id: "permission+\(permission.rawValue)",
                            text: String(localized: "New: \(AddOnUpdateDiff.text(for: permission))"), emphasis: .added))
        }
        for skill in diff.skillsAdded {
            rows.append(Row(id: "skill+\(skill)", text: String(localized: "New skill: \(skill)"), emphasis: .added))
        }
        for skill in diff.skillsChanged {
            rows.append(Row(id: "skill~\(skill)", text: String(localized: "Changed skill: \(skill)"), emphasis: .added))
        }
        for domain in diff.domainsRemoved {
            rows.append(Row(id: "domain-\(domain)", text: String(localized: "No longer connects to: \(domain)"), emphasis: .removed))
        }
        for permission in diff.permissionsRemoved {
            rows.append(Row(id: "permission-\(permission.rawValue)",
                            text: String(localized: "No longer: \(AddOnUpdateDiff.text(for: permission))"), emphasis: .removed))
        }
        for skill in diff.skillsRemoved {
            rows.append(Row(id: "skill-\(skill)", text: String(localized: "Skill removed: \(skill)"), emphasis: .removed))
        }
        return rows
    }
}
