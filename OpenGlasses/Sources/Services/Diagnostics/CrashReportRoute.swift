import Foundation

/// Where the report after a crash goes, and what it carries. Pure, so each rule is a test.
///
/// Every other support report follows `SupportReportRecipient`: on an organisation's phone it
/// never reaches the developer. The crash report — the one the banner after a crash opens — has
/// the owner's own rule (2026-11-26):
///
/// 1. **An organisational support email is set → it goes there**, with the report's normal
///    contents under the usual rules. A personal phone with an address set is the same.
/// 2. **Otherwise → the developer, on every phone.** Never the office that receives job reports,
///    and never "no address": a crash is the developer's to fix, and the office cannot.
/// 3. **An organisation phone's report to the developer carries the technical layer only**: the
///    crash and its frames, the last screens, the app's event log, the build and the phone's
///    state. No conversation, job, transcript, document title or name — nothing the
///    organisation's own report rules keep in-house.
///
/// This does not reopen the flood the general rule closed: a crash is rare, and the banner offers
/// each one once.
enum CrashReportRoute: Equatable {

    enum Contents: Equatable {
        /// The day of the crash with the troubleshooting layer, as Settings' report sends it.
        case normal
        /// The crash, the last screens, the app's events, the build and the phone — nothing else.
        case technicalOnly
    }

    case send(to: String, contents: Contents)

    var recipient: String {
        switch self { case .send(let to, _): return to }
    }

    var contents: Contents {
        switch self { case .send(_, let contents): return contents }
    }

    static func resolve(configured: String, organisationPhone: Bool) -> CrashReportRoute {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if SupportReportRecipient.isPlausible(trimmed) {
            return .send(to: trimmed, contents: .normal)
        }
        return .send(to: DiagnosticsReportBuilder.supportEmail,
                     contents: organisationPhone ? .technicalOnly : .normal)
    }
}

/// Which crash note, if any, the banner offers now. Pure.
///
/// One banner per note: once offered it is never offered again, whatever was tapped. A note that
/// reached the phone more than `offerWindow` after the crash is kept for the report but not
/// offered — a banner days late is noise.
enum CrashBannerPolicy {
    static let offerWindow: TimeInterval = 24 * 60 * 60

    static func noteToOffer(_ records: [CrashNoteStore.Record]) -> CrashNote? {
        records
            .filter { $0.offeredAt == nil && $0.receivedAt.timeIntervalSince($0.note.at) <= offerWindow }
            .max { $0.note.at < $1.note.at }?
            .note
    }

    /// "Avenkin closed unexpectedly at 9:45 pm. Send a report so we can fix it?"
    static func message(for note: CrashNote) -> String {
        let time = note.at.formatted(date: .omitted, time: .shortened)
        return String(localized: "Avenkin closed unexpectedly at \(time). Send a report so we can fix it?")
    }
}
