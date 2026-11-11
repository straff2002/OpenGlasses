import Foundation

// Plan KT §9.1 — does the wearer have a Google calendar in iOS Calendar? No Google sign-in and no
// Google API: iOS Calendar syncs a Google account added in Settings, and My Day already reads every
// calendar EventKit shows. This only notices whether one is there, so the page can say how to add
// one. It is a hint, never a gate — a Google calendar subscribed some other way still works.

/// What `EKSource` says about one calendar account, copied out of EventKit.
struct CalendarSourceRecord: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case local
        case exchange
        case calDAV
        case mobileMe
        case subscribed
        case birthdays
        case unknown
    }

    /// The account's name as iOS Calendar shows it: "iCloud", "Gmail", or an address.
    let title: String
    let kind: Kind
}

enum GoogleCalendarPresence {

    /// Email domains whose CalDAV accounts are known not to be Google's.
    static let nonGoogleDomains: [String] = [
        "icloud.com", "me.com", "mac.com", "yahoo.com", "ymail.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "aol.com", "fastmail.com", "fastmail.fm", "gmx.com", "gmx.de",
        "zoho.com", "proton.me", "protonmail.com",
    ]

    /// Present when any CalDAV account looks like Google's.
    static func isPresent(in sources: [CalendarSourceRecord]) -> Bool {
        sources.contains(where: looksLikeGoogle)
    }

    /// A CalDAV account titled "Gmail" or "Google…", or with a Gmail address, or with any other
    /// address on a domain not known to belong to someone else — which is how a Google Workspace
    /// account added to iOS Calendar is titled. Titles vary by iOS version and language; the
    /// device pass checks this, and the line it drives stays dismissible either way.
    static func looksLikeGoogle(_ source: CalendarSourceRecord) -> Bool {
        guard source.kind == .calDAV else { return false }
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.contains("gmail") || title.contains("google") { return true }
        guard let at = title.lastIndex(of: "@") else { return false }
        let domain = String(title[title.index(after: at)...])
        guard domain.contains("."), !title.contains(" ") else { return false }
        if domain == "googlemail.com" { return true }
        return !nonGoogleDomains.contains(domain)
    }
}
