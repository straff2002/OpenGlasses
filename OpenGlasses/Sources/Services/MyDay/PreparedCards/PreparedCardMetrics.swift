import Foundation

// Plan KT §10 — learning what's useful, on the phone only. A closed vocabulary like
// `MyDayMetricsStore`'s: per kind, how often a card was built, shown, opened, edited, handed off,
// sent, put off, dismissed or marked not useful; where drafts came from; why a draft fell back to
// its template. No case can carry a title, a name, an address, a draft's text or a time.

enum PreparedCardMetricAction: String, CaseIterable, Sendable {
    case built
    case shown
    case opened
    case draftEdited
    case handedOff
    case sent
    case later
    case dismissed
    case notUseful
}

/// Who wrote a shown draft. P1 has templates only; the other two arrive with model drafts.
enum PreparedCardDraftOriginMetric: String, CaseIterable, Sendable {
    case template
    case onDevice
    case cloud

    init(_ origin: DraftOrigin) {
        switch origin {
        case .template: self = .template
        case .onDevice: self = .onDevice
        case .cloud: self = .cloud
        }
    }
}

enum PreparedCardMetricEvent: Equatable, Sendable {
    case card(PreparedCardKind, PreparedCardMetricAction)
    case draftOrigin(PreparedCardDraftOriginMetric)
    case validatorFallback(DraftValidationFailure)
}

protocol PreparedCardMetricsRecording: AnyObject {
    func record(_ event: PreparedCardMetricEvent)
}

struct PreparedCardMetricsSnapshot: Equatable, Sendable {
    let counts: [PreparedCardKind: [PreparedCardMetricAction: Int]]
    let draftOrigins: [PreparedCardDraftOriginMetric: Int]
    let fallbacks: [DraftValidationFailure: Int]

    func count(_ kind: PreparedCardKind, _ action: PreparedCardMetricAction) -> Int {
        counts[kind]?[action] ?? 0
    }

    func total(_ action: PreparedCardMetricAction) -> Int {
        PreparedCardKind.allCases.reduce(0) { $0 + count($1, action) }
    }
}

/// Counters in `UserDefaults`, under `preparedCardMetrics.v1.`. No event log, no export path but
/// the support report's counts.
final class PreparedCardMetricsStore: PreparedCardMetricsRecording, @unchecked Sendable {
    static let shared = PreparedCardMetricsStore()

    private enum Key {
        static let prefix = "preparedCardMetrics.v1."
        static func card(_ kind: PreparedCardKind, _ action: PreparedCardMetricAction) -> String {
            prefix + "card." + kind.rawValue + "." + action.rawValue
        }
        static func origin(_ origin: PreparedCardDraftOriginMetric) -> String {
            prefix + "origin." + origin.rawValue
        }
        static func fallback(_ reason: DraftValidationFailure) -> String {
            prefix + "fallback." + reason.rawValue
        }
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ event: PreparedCardMetricEvent) {
        let key: String
        switch event {
        case .card(let kind, let action): key = Key.card(kind, action)
        case .draftOrigin(let origin): key = Key.origin(origin)
        case .validatorFallback(let reason): key = Key.fallback(reason)
        }
        lock.lock()
        defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    func snapshot() -> PreparedCardMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var counts: [PreparedCardKind: [PreparedCardMetricAction: Int]] = [:]
        for kind in PreparedCardKind.allCases {
            var row: [PreparedCardMetricAction: Int] = [:]
            for action in PreparedCardMetricAction.allCases {
                let value = defaults.integer(forKey: Key.card(kind, action))
                if value > 0 { row[action] = value }
            }
            if !row.isEmpty { counts[kind] = row }
        }
        var origins: [PreparedCardDraftOriginMetric: Int] = [:]
        for origin in PreparedCardDraftOriginMetric.allCases {
            let value = defaults.integer(forKey: Key.origin(origin))
            if value > 0 { origins[origin] = value }
        }
        var fallbacks: [DraftValidationFailure: Int] = [:]
        for reason in DraftValidationFailure.allCases {
            let value = defaults.integer(forKey: Key.fallback(reason))
            if value > 0 { fallbacks[reason] = value }
        }
        return PreparedCardMetricsSnapshot(counts: counts, draftOrigins: origins, fallbacks: fallbacks)
    }

    /// Every counter back to zero (tests).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Key.prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The support report's **Cards** section: the switch, the kinds turned off, and the counts. Case
/// names and numbers only — never a headline, a name, an address, a draft or a time.
enum PreparedCardReport {

    static func lines(enabled: Bool, disabledKinds: Set<PreparedCardKind>, customerTextsAllowed: Bool,
                      shownNow: Int, snapshot: PreparedCardMetricsSnapshot) -> [String] {
        var lines = ["Cards: \(enabled ? "on" : "off"), \(shownNow) on the page now"]
        if !disabledKinds.isEmpty {
            lines.append("Cards off: " + disabledKinds.map(\.rawValue).sorted().joined(separator: ", "))
        }
        if !customerTextsAllowed { lines.append("Cards: customer texts off") }
        for kind in PreparedCardKind.allCases {
            guard let row = snapshot.counts[kind] else { continue }
            let parts = PreparedCardMetricAction.allCases.compactMap { action -> String? in
                guard let value = row[action] else { return nil }
                return "\(action.rawValue) \(value)"
            }
            lines.append("Cards \(kind.rawValue): " + parts.joined(separator: ", "))
        }
        if !snapshot.draftOrigins.isEmpty {
            lines.append("Card drafts: " + PreparedCardDraftOriginMetric.allCases.compactMap { origin in
                snapshot.draftOrigins[origin].map { "\(origin.rawValue) \($0)" }
            }.joined(separator: ", "))
        }
        if !snapshot.fallbacks.isEmpty {
            lines.append("Card draft fallbacks: " + DraftValidationFailure.allCases.compactMap { reason in
                snapshot.fallbacks[reason].map { "\(reason.rawValue) \($0)" }
            }.joined(separator: ", "))
        }
        return lines
    }
}
