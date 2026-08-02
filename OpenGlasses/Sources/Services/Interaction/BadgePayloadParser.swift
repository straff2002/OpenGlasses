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

    /// Merge QR-payload fields over OCR heuristics: the payload is machine-authored
    /// ground truth, the OCR parse is a guess — payload wins wherever both speak.
    /// Pass `ocr: nil` when the OCR parse fell below its confidence floor.
    static func merged(ocr: BadgeFields?, payload: BadgeContact?) -> BadgeContact {
        var contact = payload ?? BadgeContact()
        contact.name = contact.name ?? ocr?.name
        contact.title = contact.title ?? ocr?.title
        contact.organization = contact.organization ?? ocr?.organization
        return contact
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
