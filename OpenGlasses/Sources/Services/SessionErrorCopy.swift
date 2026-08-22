import Foundation

/// Which error to show when a mode-specific one and a general one both exist.
///
/// Device-traced 2026-08-23: in a live session the transcript overlay showed *only* the session's
/// own error, so anything written to the app-level error was invisible — and the camera button,
/// which exists only in a live session, reports its failures there. Tapping it did nothing,
/// visibly: the reason was captured and discarded by the display layer. That is the same failure
/// as the Live close reason earlier in the day, one layer up.
enum SessionErrorCopy {

    /// The session's error wins when present — it is the more specific one — but its absence must
    /// not hide a general error. Falling back is what makes an app-level failure visible in a mode
    /// that has its own error channel.
    static func text(sessionError: String?, appError: String?) -> String? {
        if let sessionError, !sessionError.trimmingCharacters(in: .whitespaces).isEmpty {
            return sessionError
        }
        if let appError, !appError.trimmingCharacters(in: .whitespaces).isEmpty {
            return appError
        }
        return nil
    }
}
