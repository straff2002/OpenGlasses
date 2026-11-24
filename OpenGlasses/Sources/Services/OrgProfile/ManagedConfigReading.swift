import Foundation

/// Plan ND — what an MDM's Managed App Configuration says, read without trusting it.
///
/// iOS keeps the dictionary an MDM pushes under `com.apple.configuration.managed`. Plan CT decided
/// its shape and deferred the reader: the dictionary carries **the same signed profile** every other
/// path does, inline or as its HTTPS address, under `orgProfile` — never raw settings, so there is
/// one trust path and one verification. ND adds one optional key, `activationKey`: the company's
/// short key, the same one a person would type, so the company's sealed credentials and manuals open
/// on a phone nobody typed anything into. Everything else in the dictionary is ignored, by name.
///
/// Pure: the caller hands over the dictionary; `ManagedConfigIngress` observes it and
/// `ManagedConfigEnrolment` acts on what it reads.
enum ManagedConfigReading {

    /// The dictionary iOS writes for a managed app.
    static let dictionaryKey = "com.apple.configuration.managed"
    static let profileKey = ProfileSource.managedConfigProfileKey
    static let activationKeyKey = "activationKey"

    /// The longest inline profile the reader accepts, the same bound the profile fetch holds a
    /// downloaded document to.
    static let maximumInlineBytes = 256 * 1024

    enum Problem: Equatable, Sendable {
        /// `orgProfile` is there but is not text.
        case profileNotText
        /// `orgProfile` is text, but neither an `https` address nor a signed document.
        case profileUnreadable
        /// `activationKey` is there but is not a key (`ActivationKey.read`).
        case activationKeyUnreadable
    }

    struct Reading: Equatable, Sendable {
        /// The signed profile to verify, or its address. Nil when the dictionary names none.
        var delivery: ProfileDelivery?
        var activationKey: ActivationKey?
        /// Keys the dictionary carries that this build does not read, sorted. Named once in the log.
        var ignoredKeys: [String] = []
        var problems: [Problem] = []

        /// The MDM delivered something this build can act on.
        var namesAProfile: Bool { delivery != nil }
    }

    static func read(_ dictionary: [String: Any]?) -> Reading {
        var reading = Reading()
        guard let dictionary else { return reading }
        reading.ignoredKeys = dictionary.keys.filter { $0 != profileKey && $0 != activationKeyKey }.sorted()

        if let raw = dictionary[profileKey] {
            if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = httpsAddress(trimmed) {
                    reading.delivery = .pointer(url)
                } else if !trimmed.isEmpty, trimmed.utf8.count <= maximumInlineBytes, !trimmed.contains("://") {
                    // A signed document; `ProfileVerification` decides whether it is one.
                    reading.delivery = .inline(trimmed)
                } else {
                    reading.problems.append(.profileUnreadable)
                }
            } else {
                reading.problems.append(.profileNotText)
            }
        }

        if let raw = dictionary[activationKeyKey] {
            if let text = raw as? String, case .key(let key) = ActivationKey.read(text) {
                reading.activationKey = key
            } else {
                reading.problems.append(.activationKeyUnreadable)
            }
        }
        return reading
    }

    /// An address the profile may be fetched from: `https`, a host, no credentials, no fragment.
    private static func httpsAddress(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url
    }
}

/// Plan ND — when a profile the MDM took away really is gone.
///
/// An empty read of the managed dictionary can be a sync in progress rather than a decision: leaving
/// on one would erase a fleet's manuals over a hiccup (Plan CT's trap: "treating a failed fetch as a
/// revocation"). So the phone leaves only once `orgProfile` has been absent at two reads at least
/// `confirmationInterval` apart, or at reads in two different launches.
struct ManagedConfigAbsence: Codable, Equatable, Sendable {
    static let confirmationInterval: TimeInterval = 10 * 60

    /// When `orgProfile` was first seen missing, and in which launch. Nil while it is present.
    var firstMissingAt: Date?
    var firstMissingLaunch: String?

    /// Record one read. Returns true when the absence is confirmed and the phone should leave.
    mutating func observe(profilePresent: Bool, now: Date, launchId: String) -> Bool {
        guard !profilePresent else {
            firstMissingAt = nil
            firstMissingLaunch = nil
            return false
        }
        guard let first = firstMissingAt else {
            firstMissingAt = now
            firstMissingLaunch = launchId
            return false
        }
        if let launch = firstMissingLaunch, launch != launchId { return true }
        // A clock wound back behind the first read confirms nothing.
        guard now >= first else { return false }
        return now.timeIntervalSince(first) >= Self.confirmationInterval
    }
}
