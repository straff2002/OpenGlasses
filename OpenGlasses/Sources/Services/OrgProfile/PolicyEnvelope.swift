import Foundation

/// Plan CT PR 2 — the standing envelope: what the enrolled organisation profile does to this
/// device, held in memory and consulted by every `Config` accessor a profile may touch.
///
/// **Clamp on read, never on write.** The person's own stored value is never overwritten by a
/// ceiling; the getter returns the clamped value instead. So removing the profile restores the
/// person's value with nothing to put back, and every existing read site — `VaultLinkInstallPolicy`,
/// the sign-off step, the delivery policy, the job-file check, the tool gates — gets the clamped
/// value with no change of its own. While a key is locked its setter is refused as well, so a
/// disabled control that writes its (clamped) value back on the way out cannot overwrite the
/// person's preference with the organisation's.
///
/// The envelope is installed from a profile that has just been verified — at enrolment, and at
/// launch from the stored document, which is **re-verified** there rather than trusted from
/// storage — so a getter never pays for a signature check. An empty envelope is an unmanaged phone.
///
/// Thread-safe: `Config` is read from every isolation domain.
enum PolicyEnvelope {

    private static let lock = NSLock()
    // Guarded by `lock`; every access below takes it.
    nonisolated(unsafe) private static var result = ProfileApplier.Result()
    nonisolated(unsafe) private static var organization: String?
    nonisolated(unsafe) private static var withheldLicence: String?

    /// The organisation whose profile is in force, or nil on an unmanaged phone.
    static var organizationName: String? {
        lock.lock(); defer { lock.unlock() }
        return organization
    }

    /// Whether any profile is in force.
    static var isManaged: Bool { organizationName != nil }

    /// The applier result in force. Empty on an unmanaged phone.
    static var current: ProfileApplier.Result {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Put a verified profile's result in force and tell the app its policy changed.
    static func install(_ newResult: ProfileApplier.Result, organizationName: String) {
        lock.lock()
        result = newResult
        organization = organizationName
        lock.unlock()
        NotificationCenter.default.post(name: .orgPolicyDidChange, object: nil)
    }

    /// Lift every bound: the phone is unmanaged again.
    static func clear() {
        lock.lock()
        result = ProfileApplier.Result()
        organization = nil
        lock.unlock()
        NotificationCenter.default.post(name: .orgPolicyDidChange, object: nil)
    }

    /// The licence code the enrolled profile brought, while its lease is not in force (Plan CT
    /// PR 2b). The entitlement provider skips exactly this code, so the organisation's pack and the
    /// vaults its licence unlocks lock through the gates that already exist — and nothing the
    /// person bought themselves is touched. Nil whenever the lease is live.
    static var withheldLicenceCode: String? {
        lock.lock(); defer { lock.unlock() }
        return withheldLicence
    }

    /// Withhold the profile's licence (lease not in force), or stop withholding it (nil).
    static func withholdLicence(_ code: String?) {
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let changed = withheldLicence != trimmed
        withheldLicence = trimmed
        lock.unlock()
        if changed { NotificationCenter.default.post(name: .orgPolicyDidChange, object: nil) }
    }

    /// Whether a control for `key` must render locked, with the organisation named as the reason.
    static func isLocked(_ key: SettingKey) -> Bool {
        current.isLocked(key)
    }

    // MARK: - Typed reads for Config

    static func bool(_ key: SettingKey, stored: Bool) -> Bool {
        guard case .bool(let value) = current.effectiveValue(key, stored: .bool(stored)) else { return stored }
        return value
    }

    static func string(_ key: SettingKey, stored: String) -> String {
        guard case .string(let value) = current.effectiveValue(key, stored: .string(stored)) else { return stored }
        return value
    }

    static func strings(_ key: SettingKey, stored: [String]) -> [String] {
        guard case .strings(let value) = current.effectiveValue(key, stored: .strings(stored)) else { return stored }
        return value
    }
}

extension Notification.Name {
    /// The organisation policy in force changed — a profile was applied, replaced or removed.
    /// Anything that cached a clamped value at launch (the live privacy filter, a running server)
    /// re-reads `Config` when this arrives.
    static let orgPolicyDidChange = Notification.Name("orgPolicyDidChange")
}
