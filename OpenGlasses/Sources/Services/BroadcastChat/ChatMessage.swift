import Foundation

/// One chat message from the platform the broadcast is streaming to (Plan CI).
///
/// Always plain text by construction: the parser strips control characters and caps length, so
/// nothing downstream (TTS, HUD) ever sees raw wire bytes.
struct ChatMessage: Equatable {
    /// Name to speak — the platform display name when present (may be UTF-8), else the login.
    let user: String
    /// Lowercase account/login name.
    let login: String
    /// The message text, sanitised (control characters removed, length capped).
    let text: String
    /// Badge names in wire order, e.g. `["broadcaster", "subscriber"]`.
    let badges: [String]
    /// Whether this was a `/me` action message.
    let isAction: Bool
    /// `text` with the platform's emote tokens removed (whitespace collapsed). Empty for an
    /// emote-only message — the policy uses this to drop emote spam.
    let textWithoutEmotes: String
}

/// A classified line from the Twitch IRC-over-WebSocket connection.
enum TwitchIRCLine: Equatable {
    /// A chat message in the joined channel.
    case privateMessage(ChatMessage)
    /// Server keepalive — the connection must answer with `PONG :token` or get dropped.
    case ping(token: String)
    /// Anything else (JOIN acks, capability acks, notices) — ignored by readback.
    case other
}

/// Parses raw Twitch IRC lines (IRCv3 tags + PRIVMSG) into `ChatMessage`s (Plan CI P1).
///
/// Pure and defensive: every field of the line is attacker-controlled (any viewer can type into
/// chat, and tags carry user-chosen display names), so parsing never traps — malformed tags,
/// out-of-range emote indices, control characters, and megabyte lines all degrade to safe plain
/// text or `.other`. This is the only place wire bytes are touched; everything downstream works
/// on `ChatMessage`.
enum TwitchChatMessageParser {

    /// Longest message text kept after sanitising — far above Twitch's own 500-char cap, but a
    /// hard bound so a hostile server can't feed us megabyte lines.
    static let maxTextLength = 600

    /// Classify one IRC line (without trailing CRLF).
    static func parse(line: String) -> TwitchIRCLine {
        var rest = Substring(line)

        // Tags: "@key=value;key=value " — optional, before everything else.
        var tags: [String: String] = [:]
        if rest.first == "@" {
            guard let space = rest.firstIndex(of: " ") else { return .other }
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                if let eq = pair.firstIndex(of: "=") {
                    tags[String(pair[..<eq])] = unescapeTagValue(pair[pair.index(after: eq)...])
                } else {
                    tags[String(pair)] = ""
                }
            }
            rest = rest[rest.index(after: space)...].drop(while: { $0 == " " })
        }

        // Prefix: ":nick!user@host " — optional.
        var login = ""
        if rest.first == ":" {
            guard let space = rest.firstIndex(of: " ") else { return .other }
            let prefix = rest[rest.index(after: rest.startIndex)..<space]
            login = String(prefix.prefix(while: { $0 != "!" && $0 != "@" })).lowercased()
            rest = rest[rest.index(after: space)...].drop(while: { $0 == " " })
        }

        // Command.
        let command = rest.prefix(while: { $0 != " " })
        rest = rest.dropFirst(command.count).drop(while: { $0 == " " })

        switch command.uppercased() {
        case "PING":
            var token = rest
            if token.first == ":" { token = token.dropFirst() }
            return .ping(token: String(token))

        case "PRIVMSG":
            // Params: "#channel :message text"
            guard let colon = rest.firstIndex(of: ":") else { return .other }
            var body = String(rest[rest.index(after: colon)...])

            // "/me" arrives as CTCP ACTION: \u{1}ACTION <text>\u{1}
            var isAction = false
            if body.hasPrefix("\u{1}ACTION ") {
                isAction = true
                body = String(body.dropFirst("\u{1}ACTION ".count))
                if body.hasSuffix("\u{1}") { body = String(body.dropLast()) }
            }

            // Emote ranges index the *pre-sanitised* body by unicode scalar, so compute the
            // emote-stripped variant first, then sanitise both.
            let withoutEmotes = removingEmoteRanges(from: body, emotesTag: tags["emotes"] ?? "")
            let text = sanitize(body)
            guard !text.isEmpty, !login.isEmpty else { return .other }

            let displayName = sanitize(tags["display-name"] ?? "")
            let badges = (tags["badges"] ?? "")
                .split(separator: ",")
                .compactMap { $0.split(separator: "/").first.map(String.init) }

            return .privateMessage(ChatMessage(
                user: displayName.isEmpty ? login : displayName,
                login: login,
                text: text,
                badges: badges,
                isAction: isAction,
                textWithoutEmotes: sanitize(withoutEmotes)))

        default:
            return .other
        }
    }

    // MARK: - Pieces (internal for tests)

    /// IRCv3 tag-value unescaping: `\:` → `;`, `\s` → space, `\\` → `\`, `\r`/`\n` → CR/LF,
    /// a dangling `\` is dropped, and any other escaped character passes through unchanged.
    static func unescapeTagValue(_ value: Substring) -> String {
        var out = String()
        out.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else { out.append(ch); continue }
            switch iterator.next() {
            case ":": out.append(";")
            case "s": out.append(" ")
            case "\\": out.append("\\")
            case "r": out.append("\r")
            case "n": out.append("\n")
            case let other?: out.append(other)
            case nil: break   // dangling escape at end — drop
            }
        }
        return out
    }

    /// Remove the unicode-scalar ranges named by a Twitch `emotes=` tag
    /// (`"25:0-4,12-16/1902:6-10"`). Invalid, reversed, overlapping, or out-of-bounds ranges are
    /// skipped — the tag is wire input and must never trap.
    static func removingEmoteRanges(from text: String, emotesTag: String) -> String {
        guard !emotesTag.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        var keep = [Bool](repeating: true, count: scalars.count)
        for emote in emotesTag.split(separator: "/") {
            guard let colon = emote.firstIndex(of: ":") else { continue }
            for range in emote[emote.index(after: colon)...].split(separator: ",") {
                let bounds = range.split(separator: "-")
                guard bounds.count == 2,
                      let start = Int(bounds[0]), let end = Int(bounds[1]),
                      start >= 0, start <= end, start < scalars.count else { continue }
                for i in start...min(end, scalars.count - 1) { keep[i] = false }
            }
        }
        var out = String.UnicodeScalarView()
        for (scalar, kept) in zip(scalars, keep) where kept { out.append(scalar) }
        return String(out)
    }

    /// Plain text for TTS/HUD: control characters removed, whitespace collapsed to single
    /// spaces, trimmed, and hard-capped at `maxTextLength`.
    static func sanitize(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(min(text.count, maxTextLength + 1))
        var lastWasSpace = true   // leading whitespace collapses away
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar.value == 0x7F {
                continue
            }
            if scalar.properties.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
            if out.count > maxTextLength { break }
        }
        var trimmed = out.trimmingCharacters(in: .whitespaces)
        if trimmed.count > maxTextLength { trimmed = String(trimmed.prefix(maxTextLength)) }
        return trimmed
    }
}
