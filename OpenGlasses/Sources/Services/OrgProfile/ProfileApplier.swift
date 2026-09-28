import Foundation

/// Plan CT P1 — the pure decision of what a verified profile does to this device.
///
/// No `UserDefaults` in the decision path: the caller commits the result. The applier takes
/// **layers**, not a profile — the managed-configuration layer (no reader ships yet; tests use a
/// synthetic one) and the profile layer — and resolves them in one stated order:
///
///   managed configuration > profile > the person's own values,
///   with ceilings applied as a final clamp that nothing outranks.
///
/// Every entry it cannot use is a named `Drop`. A profile is written against one app version and
/// scanned on another, so drops are the normal case, and the report is shown to whoever holds the
/// phone at enrolment.
enum ProfileApplier {

    struct Drop: Equatable, Sendable {
        /// The key as the profile spelled it — which may not be a key this build knows.
        let key: String
        let reason: Reason

        enum Reason: Equatable, Sendable {
            case unknownKey
            /// No value, or one this build cannot read (a number, an object).
            case unreadableValue
            case wrongType(expected: SettingKey.ValueType)
            /// A ceiling that tries to move the key the way it may never move.
            case wrongDirection
            case unknownDisposition(String?)
            /// A disposition this key does not take — a ceiling on a starting value, or a
            /// starting value on a key that may only be pinned.
            case dispositionNotAllowed(ProfileDisposition)
            case invalidValue(String)
        }
    }

    enum Notice: Equatable, Sendable {
        /// `leaseDays` was outside `ConfigProfile.leaseDaysRange` and was held to it.
        case leaseClamped(requested: Int, applied: Int)
        /// An erasure window was outside `ConfigProfile.erasureDaysRange` and was ignored.
        case erasureWindowIgnored(field: String, requested: Int)
        /// A profile arrived on a device whose managed configuration already carries one. Both
        /// apply — managed configuration wins where they overlap — but it is reported, never
        /// merged silently.
        case profileUnderManagement
    }

    struct Result: Equatable, Sendable {
        /// Organisation identity, written by the winning layer and by nothing else.
        var owned: [SettingKey: ProfileValue] = [:]
        /// Bounds nothing may widen. The union of every layer's ceilings: each key may only be
        /// pinned one way, so two layers can never disagree about the value.
        var ceilings: [SettingKey: ProfileValue] = [:]
        /// Starting values to write once; the person may change them afterwards.
        var startingValues: [SettingKey: ProfileValue] = [:]
        var drops: [Drop] = []
        var notices: [Notice] = []
        /// The lease the envelope enforces, after clamping. Nil when no layer is present.
        var leaseDays: Int?
        var eraseAfterLapseDays: Int?
        var undeliveredEraseDays: Int?
        /// The AI model the winning layer names, checked (Plan CT 3a). Nil when none names one, or
        /// when the one named could not be used — that is a drop keyed `aiModel`.
        var aiModel: OrgAIModel?
        /// The presentation the winning layer names, and how its administrator gets past it
        /// (Plan CT 3b). Nil when no layer names an edition this build knows.
        var adminPolicy: AdminPolicy?

        /// The value a read of `key` must return, given what the person has stored.
        ///
        /// **Clamp on read, never on write**: the person's own value is left where it is, so
        /// removing the profile restores it for free, and a setter that runs under a ceiling writes
        /// a preference this will not return until the ceiling lifts.
        func effectiveValue(_ key: SettingKey, stored: ProfileValue) -> ProfileValue {
            if let owned = owned[key] { return owned }
            if let ceiling = ceilings[key] { return ceiling }
            return stored
        }

        /// Whether the control for `key` renders locked, with the organisation named as the reason.
        func isLocked(_ key: SettingKey) -> Bool {
            owned[key] != nil || ceilings[key] != nil
        }
    }

    /// Resolve the layers into one result.
    ///
    /// - Parameter resolvableVaultIds: the vault ids the registry can resolve right now. Until
    ///   enrolment installs packs (PR 3), a default vault naming anything else is a named drop —
    ///   a default pointing at a vault that is not there is a broken home screen.
    static func apply(
        profile: ConfigProfile?,
        managed: ConfigProfile? = nil,
        resolvableVaultIds: Set<String>
    ) -> Result {
        var result = Result()
        if profile != nil, managed != nil { result.notices.append(.profileUnderManagement) }

        // Lowest precedence first, so the managed layer overwrites where both set a value.
        for layer in [profile, managed].compactMap({ $0 }) {
            apply(layer, into: &result, resolvableVaultIds: resolvableVaultIds)
        }
        return result
    }

    private static func apply(_ layer: ConfigProfile, into result: inout Result,
                              resolvableVaultIds: Set<String>) {
        let lease = min(max(layer.leaseDays, ConfigProfile.leaseDaysRange.lowerBound),
                        ConfigProfile.leaseDaysRange.upperBound)
        if lease != layer.leaseDays {
            result.notices.append(.leaseClamped(requested: layer.leaseDays, applied: lease))
        }
        result.leaseDays = lease
        let eraseAfterLapse = window(layer.eraseAfterLapseDays, field: "eraseAfterLapseDays", into: &result)
        let undelivered = window(layer.undeliveredEraseDays, field: "undeliveredEraseDays", into: &result)
        result.eraseAfterLapseDays = eraseAfterLapse
        result.undeliveredEraseDays = undelivered ?? ConfigProfile.defaultUndeliveredEraseDays
        if let raw = layer.edition {
            if let edition = ProfileEdition(rawValue: raw) {
                var credentials = AdminCredentials()
                if let verifier = layer.adminPasscode {
                    switch AdminSecrets.resolve(verifier) {
                    case .success(let passcode): credentials.passcode = passcode
                    case .failure(let reason): result.drops.append(Drop(key: "adminPasscode", reason: reason))
                    }
                }
                if let card = layer.adminCard {
                    switch AdminSecrets.resolveCard(card) {
                    case .success(let digest): credentials.cardDigest = digest
                    case .failure(let reason): result.drops.append(Drop(key: "adminCard", reason: reason))
                    }
                }
                result.adminPolicy = AdminPolicy(edition: edition, credentials: credentials)
            } else {
                result.drops.append(Drop(key: "edition",
                                         reason: .invalidValue("\u{201C}\(raw)\u{201D} is not an edition this version of the app knows")))
            }
        } else {
            // A passcode or card opens what an edition hides; with no edition there is nothing to open.
            for (key, present) in [("adminPasscode", layer.adminPasscode != nil), ("adminCard", layer.adminCard != nil)]
            where present {
                result.drops.append(Drop(key: key, reason: .invalidValue("it only applies with an edition")))
            }
        }
        if let spec = layer.aiModel {
            switch OrgAIModel.resolve(spec) {
            case .success(let model): result.aiModel = model
            case .failure(let reason): result.drops.append(Drop(key: "aiModel", reason: reason))
            }
        }

        for name in layer.settings.keys.sorted() {
            guard let raw = layer.settings[name] else { continue }
            guard let key = SettingKey(rawValue: name) else {
                result.drops.append(Drop(key: name, reason: .unknownKey))
                continue
            }
            guard let value = raw.value else {
                result.drops.append(Drop(key: name, reason: .unreadableValue))
                continue
            }

            switch key.kind {
            case .profileOwned(let type):
                guard value.valueType == type else {
                    result.drops.append(Drop(key: name, reason: .wrongType(expected: type)))
                    continue
                }
                if let problem = key.contentProblem(value, resolvableVaultIds: resolvableVaultIds) {
                    result.drops.append(Drop(key: name, reason: .invalidValue(problem)))
                    continue
                }
                result.owned[key] = value

            case .ceiling(let pinnedTo):
                guard let disposition = readDisposition(raw, name: name, into: &result) else { continue }
                guard disposition == .ceiling else {
                    result.drops.append(Drop(key: name, reason: .dispositionNotAllowed(disposition)))
                    continue
                }
                guard case .bool(let flag) = value else {
                    result.drops.append(Drop(key: name, reason: .wrongType(expected: .bool)))
                    continue
                }
                guard flag == pinnedTo else {
                    result.drops.append(Drop(key: name, reason: .wrongDirection))
                    continue
                }
                result.ceilings[key] = value

            case .startingValue(let type):
                guard let disposition = readDisposition(raw, name: name, into: &result) else { continue }
                guard disposition == .default else {
                    result.drops.append(Drop(key: name, reason: .dispositionNotAllowed(disposition)))
                    continue
                }
                guard value.valueType == type else {
                    result.drops.append(Drop(key: name, reason: .wrongType(expected: type)))
                    continue
                }
                if let problem = key.contentProblem(value, resolvableVaultIds: resolvableVaultIds) {
                    result.drops.append(Drop(key: name, reason: .invalidValue(problem)))
                    continue
                }
                result.startingValues[key] = value
            }
        }
    }

    private static func readDisposition(_ raw: RawSetting, name: String,
                                        into result: inout Result) -> ProfileDisposition? {
        guard let text = raw.disposition, let disposition = ProfileDisposition(rawValue: text) else {
            result.drops.append(Drop(key: name, reason: .unknownDisposition(raw.disposition)))
            return nil
        }
        return disposition
    }

    private static func window(_ days: Int?, field: String, into result: inout Result) -> Int? {
        guard let days else { return nil }
        guard ConfigProfile.erasureDaysRange.contains(days) else {
            result.notices.append(.erasureWindowIgnored(field: field, requested: days))
            return nil
        }
        return days
    }
}
