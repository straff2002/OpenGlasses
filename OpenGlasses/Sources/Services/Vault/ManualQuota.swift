import Foundation

/// Limits are policy derived from live evidence, never a persisted entitlement or usage counter.
struct ManualLimits: Equatable, Sendable {
    let manuals: Int
    let pagesPerManual: Int?
    let totalPages: Int?
    /// How fast the shelf may turn over (Plan JK §8). Nil for every holder without the personal
    /// limits: an unlimited grant has no new-manual allowance.
    let additions: AdditionAllowance?

    init(manuals: Int, pagesPerManual: Int?, totalPages: Int?, additions: AdditionAllowance? = nil) {
        self.manuals = manuals
        self.pagesPerManual = pagesPerManual
        self.totalPages = totalPages
        self.additions = additions
    }

    /// New manuals per rolling window. A returning manual is free; the first distinct manuals of a
    /// subscription are free; an unread addition removed within `undoWindow` is given back.
    struct AdditionAllowance: Equatable, Sendable {
        let newPerWindow: Int
        let window: TimeInterval
        let freeFirst: Int
        let undoWindow: TimeInterval

        static let personal = AdditionAllowance(newPerWindow: 3, window: 30 * 86_400, freeFirst: 5, undoWindow: 86_400)
    }

    /// Provisional envelope after the 7,595-page / five-slot 9,459-page phone measurement.
    /// Broader hardware qualification remains outstanding.
    static let personal = ManualLimits(manuals: 5, pagesPerManual: 8_000, totalPages: 10_000, additions: .personal)

    static func resolve(_ evidence: FieldAssistEntitlementEvidenceSet, now: Date) -> ManualLimits? {
        FieldAssistCapability.capabilities(for: evidence, now: now).contains(.personalManuals) ? .personal : nil
    }
}

enum ManualQuota {
    struct Item: Equatable, Sendable {
        let id: String
        let pages: Int?
    }
    enum Measure: String, Equatable, Sendable { case manuals, pagesPerManual, totalPages }
    enum Verdict: Equatable, Sendable {
        case allowed
        case unavailable
        case wouldExceed(measure: Measure, held: Int, adding: Int, limit: Int)

        var message: String? {
            switch self {
            case .allowed: return nil
            case .unavailable: return "Manual usage could not be verified. Unlock the phone and try again. You can still remove a manual."
            case .wouldExceed(let measure, let held, let adding, let limit):
                let unit = measure == .manuals ? "manuals" : "pages"
                return "My Manuals allows \(limit) \(unit)\(measure == .pagesPerManual ? " per manual" : ""). You have \(held); this change adds \(adding). Remove some content to make room."
            }
        }
    }

    /// Replacements are addressed by identity, so a reindex or retry never consumes another slot.
    static func decide(limits: ManualLimits?, held: [Item], replacing: Set<String> = [], adding: [Item]) -> Verdict {
        guard let limits else { return .allowed }
        guard Set(held.map(\.id)).count == held.count, Set(adding.map(\.id)).count == adding.count,
              adding.allSatisfy({ $0.pages.map { $0 > 0 } ?? false }),
              held.allSatisfy({ $0.pages.map { $0 > 0 } ?? false }) else { return .unavailable }
        let previous = Dictionary(uniqueKeysWithValues: held.map { ($0.id, $0) })
        guard adding.allSatisfy({ previous[$0.id] == nil || replacing.contains($0.id) }) else { return .unavailable }
        let retained = held.filter { !replacing.contains($0.id) }
        let nextCount = retained.count + adding.count
        if nextCount > limits.manuals && nextCount > held.count {
            return .wouldExceed(measure: .manuals, held: held.count, adding: nextCount - held.count, limit: limits.manuals)
        }
        if let cap = limits.pagesPerManual {
            for item in adding {
                let pages = item.pages ?? 0
                let before = previous[item.id]?.pages ?? 0
                if pages > cap && pages > before {
                    return .wouldExceed(measure: .pagesPerManual, held: before, adding: pages - before, limit: cap)
                }
            }
        }
        let oldPages = held.reduce(0) { $0 + ($1.pages ?? 0) }
        let nextPages = (retained + adding).reduce(0) { $0 + ($1.pages ?? 0) }
        if let cap = limits.totalPages, nextPages > cap && nextPages > oldPages {
            return .wouldExceed(measure: .totalPages, held: oldPages, adding: nextPages - oldPages, limit: cap)
        }
        return .allowed
    }
}

/// Source authority is decided before loading any personal store, including when a job has ended.
enum ManualSource {
    enum Selection: Equatable { case session, library, denied(String) }
    static func resolve(fieldActive: Bool, restricted: Bool, medical: Bool, sessionAvailable: Bool,
                        ownManuals: Bool, libraryAvailable: Bool) -> Selection {
        if medical { return .denied("Personal manuals are unavailable in medical mode.") }
        if fieldActive || restricted {
            return sessionAvailable ? .session : .denied("Start a Field Assist session to use its manuals.")
        }
        guard ownManuals else { return .denied("My Manuals needs an active subscription. Your files remain on this phone.") }
        return libraryAvailable ? .library : .denied("You have no manuals yet. Add one in Settings → Everyday → My Manuals.")
    }
}
