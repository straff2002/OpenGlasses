import Foundation

/// A person parsed from a badge — OCR fields, QR-payload fields, or the merge of both.
struct BadgeContact: Equatable {
    var name: String?
    var title: String?
    var organization: String?
    var phone: String?
    var email: String?
    var website: String?

    var isEmpty: Bool {
        name == nil && title == nil && organization == nil
            && phone == nil && email == nil && website == nil
    }

}

/// Outcome of reconciling the OCR parse with a QR payload.
struct BadgeReconciliation: Equatable {
    let contact: BadgeContact
    /// The QR payload's identity was accepted (its name is plausible and, when OCR
    /// also read a name, the two agree).
    let qrTrusted: Bool
    /// Both sources produced a person name and they clearly disagree — the QR is
    /// probably not the wearer's card (organiser vCard, sponsor card, lead-scan app).
    let namesDisagreed: Bool
    /// A payload that was *not* accepted as the person's identity, preserved as
    /// context — an organiser/event vCard still says where the meeting happened.
    /// Nil when the payload was trusted (its fields are in `contact`) or absent.
    let context: BadgeContact?

    init(contact: BadgeContact, qrTrusted: Bool, namesDisagreed: Bool, context: BadgeContact? = nil) {
        self.contact = contact
        self.qrTrusted = qrTrusted
        self.namesDisagreed = namesDisagreed
        self.context = context
    }
}

/// Reconciles the two badge sources (Plan CG). A QR payload is machine-authored but
/// not necessarily *about the wearer* — organiser vCards, registration blobs, and
/// sponsor cards all ride badge QRs. So the payload only wins when its name is
/// person-shaped and consistent with what's printed on the badge; otherwise the
/// printed (OCR) identity wins and the payload's contact details are dropped with it
/// — if the card isn't the person, their phone/email aren't either.
enum BadgeReconciler {

    static func reconcile(ocr: BadgeFields?, payload: BadgeContact?) -> BadgeReconciliation {
        let ocrContact = BadgeContact(name: ocr?.name, title: ocr?.title, organization: ocr?.organization)

        guard let original = payload, !original.isEmpty else {
            return BadgeReconciliation(contact: ocrContact, qrTrusted: false, namesDisagreed: false)
        }

        // A QR name that isn't person-shaped voids the payload's claim to identity —
        // but the payload itself survives as context (it names the event/organiser).
        var qr = original
        if let qrName = qr.name, !isPlausiblePersonName(qrName) {
            qr.name = nil
        }

        switch (ocrContact.name, qr.name) {
        case (nil, nil):
            // Neither source identifies a person. A website-only payload (bare URL)
            // is neutral enough to carry directly; anything richer is context only.
            let websiteOnly = original.name == nil && original.email == nil
                && original.phone == nil && original.website != nil
            return BadgeReconciliation(contact: BadgeContact(website: websiteOnly ? original.website : nil),
                                       qrTrusted: false, namesDisagreed: false,
                                       context: websiteOnly ? nil : original)

        case (_?, nil):
            // Printed name only — the payload can't be tied to this person as identity
            // or contact details, but it's kept as where/what context.
            return BadgeReconciliation(contact: ocrContact, qrTrusted: false, namesDisagreed: false,
                                       context: original)

        case (nil, _?):
            // QR only: plausible person card, OCR read nothing usable.
            return BadgeReconciliation(contact: qr, qrTrusted: true, namesDisagreed: false)

        case (let ocrName?, let qrName?):
            if namesAgree(ocrName, qrName) {
                // Same person: the payload's clean spelling and fields win; OCR fills gaps.
                var contact = qr
                contact.title = contact.title ?? ocrContact.title
                contact.organization = contact.organization ?? ocrContact.organization
                return BadgeReconciliation(contact: contact, qrTrusted: true, namesDisagreed: false)
            }
            // Different person: trust what's printed big on the badge; the other card
            // becomes context (often the organiser — i.e., the event you met at).
            return BadgeReconciliation(contact: ocrContact, qrTrusted: false, namesDisagreed: true,
                                       context: original)
        }
    }

    // MARK: - Name plausibility

    /// Vocabulary that marks a "name" as event/organiser material, not a person.
    private static let nonPersonWords: Set<String> = [
        "registration", "register", "conference", "event", "expo", "summit",
        "ticket", "admission", "info", "desk", "booth", "sponsor", "organizer",
        "organiser", "staff", "visitor", "attendee", "exhibitor", "press", "vip",
        "welcome", "badge", "pass", "entry"
    ]

    /// Person-shaped: 2–4 alphabetic tokens (interior lowercase particles allowed),
    /// no digits, and no event/organiser vocabulary anywhere.
    static func isPlausiblePersonName(_ text: String) -> Bool {
        let tokens = text.split(separator: " ")
        guard tokens.count >= 2, tokens.count <= 4 else { return false }
        for token in tokens {
            guard token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }) else { return false }
            if nonPersonWords.contains(token.lowercased()) { return false }
        }
        return true
    }

    // MARK: - Fuzzy agreement

    /// Order-insensitive token match with edit-distance tolerance, so OCR mangling
    /// ("Jane Q'Brlen-Smlth") still agrees with the clean payload spelling, and a
    /// subset agrees ("Jane Smith" vs "Jane Elizabeth Smith"). Agreement = every
    /// token of the shorter name (minus at most one) fuzzily matches a token of the
    /// longer one, with at least one match overall.
    static func namesAgree(_ a: String, _ b: String) -> Bool {
        let tokensA = normalizedTokens(a)
        let tokensB = normalizedTokens(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }

        let (short, long) = tokensA.count <= tokensB.count ? (tokensA, tokensB) : (tokensB, tokensA)
        var remaining = long
        var matched = 0
        for token in short {
            if let i = remaining.firstIndex(where: { tokensMatch(token, $0) }) {
                remaining.remove(at: i)
                matched += 1
            }
        }
        return matched >= max(1, short.count - 1) && matched >= min(short.count, 2)
    }

    private static func normalizedTokens(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func tokensMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let tolerance = max(1, min(a.count, b.count) / 3)
        guard abs(a.count - b.count) <= tolerance else { return false }
        return editDistance(a, b) <= tolerance
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        var row = Array(0...bChars.count)
        for (i, ca) in aChars.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, cb) in bChars.enumerated() {
                let insertOrDelete = min(row[j + 1], row[j]) + 1
                let substitute = previous + (ca == cb ? 0 : 1)
                previous = row[j + 1]
                row[j + 1] = min(insertOrDelete, substitute)
            }
        }
        return row[bChars.count]
    }
}

/// Parses the machine-readable payloads found in badge QR codes (Plan CG):
/// vCard, MeCard, bare URLs, and single-line plain text. Pure string code.
enum BadgePayloadParser {

    static func parse(_ payload: String) -> BadgeContact? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.uppercased().hasPrefix("BEGIN:VCARD") { return parseVCard(trimmed) }
        if trimmed.uppercased().hasPrefix("MECARD:") { return parseMeCard(trimmed) }
        if let url = asWebsite(trimmed) {
            return BadgeContact(website: url)
        }
        return nil  // opaque lead-scan blobs, ticket ids, etc. — nothing to map
    }

    // MARK: - vCard

    private static func parseVCard(_ text: String) -> BadgeContact? {
        var contact = BadgeContact()
        for line in unfoldedLines(text) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            // "TEL;TYPE=CELL" → key "TEL"; parameters are irrelevant for our fields.
            let key = line[..<colon].split(separator: ";").first.map { $0.uppercased() } ?? ""
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "FN":
                contact.name = value
            case "N":
                // "Last;First;Middle;Prefix;Suffix" — only used when FN is absent.
                if contact.name == nil {
                    let parts = value.split(separator: ";", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let ordered = [parts.count > 1 ? parts[1] : "", parts.first ?? ""]
                        .filter { !$0.isEmpty }
                    if !ordered.isEmpty { contact.name = ordered.joined(separator: " ") }
                }
            case "TITLE", "ROLE":
                if contact.title == nil { contact.title = value }
            case "ORG":
                // "Company;Department" — the company is the first component.
                contact.organization = value.split(separator: ";").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            case "TEL":
                if contact.phone == nil { contact.phone = value }
            case "EMAIL":
                if contact.email == nil { contact.email = value }
            case "URL":
                if contact.website == nil { contact.website = value }
            default:
                break
            }
        }
        return contact.isEmpty ? nil : contact
    }

    /// vCard line unfolding: a line starting with space/tab continues the previous line.
    private static func unfoldedLines(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t"), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    // MARK: - MeCard

    private static func parseMeCard(_ text: String) -> BadgeContact? {
        var contact = BadgeContact()
        let body = String(text.dropFirst("MECARD:".count))
        // Fields are ";"-separated KEY:VALUE pairs; "\;" escapes a literal semicolon.
        let fields = body
            .replacingOccurrences(of: #"\;"#, with: "\u{0}")
            .split(separator: ";")
            .map { $0.replacingOccurrences(of: "\u{0}", with: ";") }

        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].uppercased()
            let value = String(field[field.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "N":
                // "Last,First" → "First Last"; a single token stands as-is.
                let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                contact.name = parts.count >= 2 ? "\(parts[1]) \(parts[0])" : value
            case "ORG": contact.organization = value
            case "TEL": if contact.phone == nil { contact.phone = value }
            case "EMAIL": if contact.email == nil { contact.email = value }
            case "URL": if contact.website == nil { contact.website = value }
            default: break
            }
        }
        return contact.isEmpty ? nil : contact
    }

    // MARK: - URL

    private static func asWebsite(_ text: String) -> String? {
        guard !text.contains("\n"), !text.contains(" "),
              text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://"),
              URL(string: text) != nil
        else { return nil }
        return text
    }
}
