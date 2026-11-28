import Foundation

/// Why Meta's Display refused a send, as a closed vocabulary the support report can keep.
///
/// The SDK reports most refusals as `DisplayError.displayError(String)`, and the report could only
/// say `unknown(displayError)` (build 799: every whole-page picture on the lens was refused and
/// resent as text, and nothing said why). The message is the SDK's own text with a variable tail,
/// so it is never logged as written: its known prefix picks the `kind`, and only a code from Meta's
/// fixed set (`DISPLAY_ERROR_CODE_*`, or a plain number after `code=`) is kept beside it. Anything
/// else is `unrecognised`, with the message's length, so two different messages still differ.
/// Pure and SDK-free; `MetaDisplayBackend` reads the SDK error into it.
struct DisplayRefusalReason: Equatable {
    enum Kind: String, CaseIterable {
        /// "Display request rejected: …" — the glasses said no to the request.
        case requestRejected
        /// "DisplayChannel: Received error event: code=…"
        case errorEvent
        /// "DisplayChannel: Channel error: …"
        case channelError
        /// "DisplayChannel: DWA error: code=…" — the glasses-side app.
        case glassesAppError
        /// The request never left the phone ("Transport send failed…", "Failed to send DWA request…").
        case sendFailed
        /// The view could not be encoded ("Failed to serialize display payload").
        case serializeFailed
        /// The glasses answered with something the SDK could not read.
        case responseUnreadable
        /// A picture's header could not be fetched ("DisplayImageResolver: image header fetch failed").
        case imageFetchFailed
        /// "Display: Failed to start listening on display channel"
        case listenFailed
        /// "… recoverable cold-start error …"
        case coldStart
        /// `DisplayError.deviceDisconnected`
        case deviceDisconnected
        /// `DisplayError.invalidVideoURL`
        case invalidVideoURL
        /// A message this build does not know.
        case unrecognised
    }

    let kind: Kind
    /// A code from Meta's fixed set, or a number; nil when the message carried none we keep.
    let code: String?
    /// For `unrecognised` only: the message's length in characters.
    let length: Int?

    init(kind: Kind, code: String? = nil, length: Int? = nil) {
        self.kind = kind
        self.code = code
        self.length = length
    }

    /// Meta's display error codes as the SDK names them (`DISPLAY_ERROR_CODE_` dropped), plus the
    /// lower-case forms its payloads use. Nothing outside this set is ever kept from a message.
    static let knownCodes: [String: String] = [
        "DISPLAY_ERROR_CODE_ALREADY_ACTIVE": "ALREADY_ACTIVE",
        "DISPLAY_ERROR_CODE_CAPABILITY_NOT_ACTIVE": "CAPABILITY_NOT_ACTIVE",
        "DISPLAY_ERROR_CODE_NOT_ACTIVE": "NOT_ACTIVE",
        "DISPLAY_ERROR_CODE_RENDER_FAILED": "RENDER_FAILED",
        "DISPLAY_ERROR_CODE_VIDEO_FAILED": "VIDEO_FAILED",
        "DISPLAY_ERROR_CODE_UNKNOWN": "UNKNOWN",
        "rendering_failed": "rendering_failed",
        "serialization_failed": "serialization_failed",
    ]

    /// Ordered: the first prefix (or fragment) that matches wins.
    private static let prefixes: [(String, Kind)] = [
        ("Display request rejected", .requestRejected),
        ("DisplayChannel: Received error event", .errorEvent),
        ("DisplayChannel: Channel error", .channelError),
        ("DisplayChannel: DWA error", .glassesAppError),
        ("DisplayChannel: Failed to send DWA request", .sendFailed),
        ("Transport send failed for display request", .sendFailed),
        ("DisplayChannel: Failed to serialize", .serializeFailed),
        ("Failed to serialize display payload", .serializeFailed),
        ("DisplayChannel: Failed to parse", .responseUnreadable),
        ("Failed to parse display response", .responseUnreadable),
        ("DisplayImageResolver: image header fetch failed", .imageFetchFailed),
        ("Display: Failed to start listening on display channel", .listenFailed),
    ]

    /// Read the SDK's message without keeping it.
    init(sdkMessage raw: String) {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: Kind
        if let match = Self.prefixes.first(where: { message.hasPrefix($0.0) }) {
            kind = match.1
        } else if message.contains("recoverable cold-start error") {
            kind = .coldStart
        } else {
            kind = .unrecognised
        }
        self.init(kind: kind, code: Self.code(in: message),
                  length: kind == .unrecognised ? message.count : nil)
    }

    /// A known code named anywhere in the message, else the digits after `code=` (six at most).
    static func code(in message: String) -> String? {
        // Longest names first, so `…_CODE_NOT_ACTIVE` never wins inside `…_CAPABILITY_NOT_ACTIVE`.
        for name in knownCodes.keys.sorted(by: { $0.count > $1.count }) where message.contains(name) {
            return knownCodes[name]
        }
        guard let range = message.range(of: "code=") else { return nil }
        let digits = message[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        return String(digits)
    }

    /// The report's and the log's word for it: `kind`, `kind.CODE`, or `unrecognised.len<n>`.
    var token: String {
        if let code { return "\(kind.rawValue).\(code)" }
        if let length { return "\(kind.rawValue).len\(length)" }
        return kind.rawValue
    }
}
