import Foundation

/// Semantic-version precedence for add-on files (semver 2.0.0 §11): major, minor and patch
/// numerically; a pre-release sorts before its release; build metadata is ignored. Only versions
/// `RecipeAddOnValidator.isValidVersion` accepts are compared — anything else compares as equal,
/// which every caller treats as "not newer", so a malformed version can never pass for an update.
enum AddOnVersion {

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        guard let left = Parsed(a), let right = Parsed(b) else { return .orderedSame }
        for (x, y) in zip(left.core, right.core) where x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
        switch (left.preRelease.isEmpty, right.preRelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (x, y) in zip(left.preRelease, right.preRelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (.some(m), .some(n)): return m < n ? .orderedAscending : .orderedDescending
            case (.some, .none): return .orderedAscending
            case (.none, .some): return .orderedDescending
            case (.none, .none): return x < y ? .orderedAscending : .orderedDescending
            }
        }
        if left.preRelease.count == right.preRelease.count { return .orderedSame }
        return left.preRelease.count < right.preRelease.count ? .orderedAscending : .orderedDescending
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    private struct Parsed {
        let core: [Int]
        let preRelease: [String]

        init?(_ version: String) {
            guard RecipeAddOnValidator.isValidVersion(version) else { return nil }
            let withoutBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
            let parts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
            let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            core = numbers
            preRelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        }
    }
}

/// What changes when one version of an add-on replaces another — what the update sheet shows.
///
/// Pure over two decoded files. Domains are compared as their normalised display form
/// (`AddOnDomainRule`), so `API.example.org` and `api.example.org` are one domain; a skill is
/// "changed" when anything about it differs (its description, parameters or steps), because the
/// wearer approved what it did, not just its name.
struct AddOnUpdateDiff: Equatable, Sendable {

    enum Permission: String, CaseIterable, Equatable, Sendable {
        case location, memory, display
        case credentials, parts, workRecord, office
    }

    let fromVersion: String
    let toVersion: String
    let domainsAdded: [String]
    let domainsRemoved: [String]
    let permissionsAdded: [Permission]
    let permissionsRemoved: [Permission]
    let skillsAdded: [String]
    let skillsRemoved: [String]
    let skillsChanged: [String]
    /// The add-on's name, description, author, icon, coverage or "slow" flag changed.
    let detailsChanged: Bool

    /// Whether the new version may do anything the old one could not: a new domain or a new
    /// permission. A source edit that does this goes back through the sheet.
    var permissionsGrew: Bool { !domainsAdded.isEmpty || !permissionsAdded.isEmpty }

    var isEmpty: Bool {
        domainsAdded.isEmpty && domainsRemoved.isEmpty && permissionsAdded.isEmpty
            && permissionsRemoved.isEmpty && skillsAdded.isEmpty && skillsRemoved.isEmpty
            && skillsChanged.isEmpty && !detailsChanged
    }

    init(from old: RecipeAddOnManifest, to new: RecipeAddOnManifest) {
        fromVersion = old.version
        toVersion = new.version

        let oldDomains = Self.domains(old.permissions.network)
        let newDomains = Self.domains(new.permissions.network)
        domainsAdded = newDomains.subtracting(oldDomains).sorted()
        domainsRemoved = oldDomains.subtracting(newDomains).sorted()

        let oldPermissions = Self.permissions(old.permissions)
        let newPermissions = Self.permissions(new.permissions)
        permissionsAdded = Permission.allCases.filter { newPermissions.contains($0) && !oldPermissions.contains($0) }
        permissionsRemoved = Permission.allCases.filter { oldPermissions.contains($0) && !newPermissions.contains($0) }

        let oldSkills = Dictionary(old.skills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let newSkills = Dictionary(new.skills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        skillsAdded = newSkills.keys.filter { oldSkills[$0] == nil }.sorted()
        skillsRemoved = oldSkills.keys.filter { newSkills[$0] == nil }.sorted()
        skillsChanged = newSkills.keys.filter { name in
            guard let before = oldSkills[name], let after = newSkills[name] else { return false }
            return before != after
        }.sorted()

        detailsChanged = old.name != new.name || old.description != new.description
            || old.author != new.author || old.icon != new.icon || old.coverage != new.coverage
            || old.slow != new.slow || old.mcp != new.mcp
    }

    /// Normalised domains, as the sheet names them.
    static func domains(_ entries: [String]) -> Set<String> {
        Set(entries.map { entry in
            if case .success(let rule) = AddOnDomainRule.parse(entry) { return rule.display }
            return entry.lowercased()
        })
    }

    static func permissions(_ p: RecipeAddOnManifest.Permissions) -> Set<Permission> {
        var out: Set<Permission> = []
        if p.location { out.insert(.location) }
        if p.memory { out.insert(.memory) }
        if p.display { out.insert(.display) }
        for capability in p.reserved {
            switch capability {
            case .credentials: out.insert(.credentials)
            case .parts: out.insert(.parts)
            case .workRecord: out.insert(.workRecord)
            case .office: out.insert(.office)
            }
        }
        return out
    }

    /// The plain-words line for a permission, the same wording the install sheet uses.
    static func text(for permission: Permission) -> String {
        switch permission {
        case .location: return String(localized: "Use your approximate location (about 1 km) when you ask it something")
        case .memory: return String(localized: "Save things to your memory. It can't read what's already there.")
        case .display: return String(localized: "Show cards on your phone, watch and glasses display")
        case .credentials: return AddOnReservedCapability.credentials.summaryText
        case .parts: return AddOnReservedCapability.parts.summaryText
        case .workRecord: return AddOnReservedCapability.workRecord.summaryText
        case .office: return AddOnReservedCapability.office.summaryText
        }
    }
}
