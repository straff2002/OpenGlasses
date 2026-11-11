import Foundation
import Contacts

/// Shared helper for resolving contact names to phone numbers and email addresses.
/// Used by SendMessageTool, PhoneCallTool, ContactsTool and DeliverReportTool.
enum ContactLookupHelper {

    struct ResolvedContact {
        let name: String
        let phoneNumber: String
        let phoneLabel: String
    }

    struct ResolvedEmail: Equatable {
        let name: String
        let address: String
        let label: String
    }

    /// Returns true if the string looks like a phone number (mostly digits/+)
    static func isPhoneNumber(_ str: String) -> Bool {
        let digits = str.filter { $0.isNumber || $0 == "+" }
        // If more than half the characters are digits/+, treat as a number
        return !digits.isEmpty && Double(digits.count) / Double(max(str.count, 1)) > 0.5
    }

    /// Look up a contact by name and return matching contacts with phone numbers.
    /// Returns empty array if no match or contacts access denied.
    static func resolve(name: String) -> [ResolvedContact] {
        var results: [ResolvedContact] = []
        forEachMatch(name: name) { contact, displayName in
            for phone in contact.phoneNumbers {
                let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? "")
                results.append(ResolvedContact(
                    name: displayName,
                    phoneNumber: phone.value.stringValue,
                    phoneLabel: label
                ))
            }
        }
        return results
    }

    /// Look up a contact by name and return matching contacts with email addresses.
    /// Returns empty array if no match or contacts access denied.
    static func resolveEmails(name: String) -> [ResolvedEmail] {
        var results: [ResolvedEmail] = []
        forEachMatch(name: name) { contact, displayName in
            for email in contact.emailAddresses {
                let address = (email.value as String).trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { continue }
                let label = CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "")
                results.append(ResolvedEmail(name: displayName, address: address, label: label))
            }
        }
        return results
    }

    /// Which contact a set of matches actually points at.
    ///
    /// One person with a home and a work address is still one person — the composer shows the
    /// address before anybody taps Send, so picking the first is a choice the technician can see
    /// and correct. Two people who answer to the same spoken name is a different problem, and the
    /// only safe answer there is to ask.
    enum EmailPick: Equatable {
        case none
        case one(ResolvedEmail)
        case ambiguous(names: [String])
    }

    static func pickEmail(from matches: [ResolvedEmail]) -> EmailPick {
        guard let first = matches.first else { return .none }

        var distinctNames: [String] = []
        var seen: Set<String> = []
        for match in matches where seen.insert(match.name.lowercased()).inserted {
            distinctNames.append(match.name)
        }

        return distinctNames.count == 1 ? .one(first) : .ambiguous(names: distinctNames)
    }

    // MARK: - By email address (Plan KT §9.4)

    /// A phone number on a contact found by email address, with its raw `CNLabeledValue` label
    /// (`_$!<Mobile>!$_`), so the choice between numbers is a pure rule.
    struct PhoneEntry: Equatable, Sendable {
        let number: String
        let rawLabel: String?
    }

    /// The contact an email address belongs to: a display name and its phone numbers.
    struct EmailContact: Equatable, Sendable {
        let name: String
        let phones: [PhoneEntry]

        /// The number a text should go to (`ContactLookupHelper.preferredPhone`).
        var textablePhone: String? { ContactLookupHelper.preferredPhone(phones)?.number }
    }

    /// The contact who owns `email` — so a calendar attendee, who arrives as an address, can be
    /// reached by name and by text from any calendar iOS Calendar syncs. Nil when nobody has the
    /// address, when two different people do (the only safe answer then is to not guess), or when
    /// Contacts access is not granted.
    static func resolve(email: String) -> EmailContact? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else { return nil }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch) else {
            return nil
        }
        let matches = contacts.map { contact in
            EmailContact(
                name: displayName(given: contact.givenName, family: contact.familyName,
                                  organization: contact.organizationName),
                phones: contact.phoneNumbers.map {
                    PhoneEntry(number: $0.value.stringValue, rawLabel: $0.label)
                })
        }
        return pickContact(from: matches)
    }

    /// One match, or several that are the same person, is that person; two different people
    /// sharing an address (a family inbox) is nobody, as `pickEmail` treats a shared name.
    static func pickContact(from matches: [EmailContact]) -> EmailContact? {
        guard let first = matches.first else { return nil }
        let names = Set(matches.map { $0.name.lowercased() })
        return names.count == 1 ? first : nil
    }

    /// "Given Family", else the organisation, else empty.
    static func displayName(given: String, family: String, organization: String) -> String {
        let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? organization : full
    }

    /// The number a text should go to: a mobile, then an iPhone, then any other number, in the
    /// order the contact lists them. Landline-only labels (home, work, main, fax, pager) come last
    /// and fax and pager never — they cannot take a text.
    static func preferredPhone(_ phones: [PhoneEntry]) -> PhoneEntry? {
        func rank(_ entry: PhoneEntry) -> Int? {
            switch entry.rawLabel ?? "" {
            case CNLabelPhoneNumberMobile: return 0
            case CNLabelPhoneNumberiPhone: return 1
            case CNLabelPhoneNumberHomeFax, CNLabelPhoneNumberWorkFax, CNLabelPhoneNumberOtherFax,
                 CNLabelPhoneNumberPager: return nil
            case CNLabelHome, CNLabelWork, CNLabelPhoneNumberMain: return 3
            default: return 2
            }
        }
        return phones.enumerated()
            .filter { !$0.element.number.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { offset, entry in rank(entry).map { ($0, offset, entry) } }
            .min { ($0.0, $0.1) < ($1.0, $1.1) }?.2
    }

    // MARK: - The one fetch both paths share

    /// The single trip to Contacts: authorization, keys, name predicate and the display name every
    /// caller assembles the same way. Not authorized means no matches, not an error — the tools
    /// above phrase that as "no contact I can use" rather than leaking the permission state.
    private static func forEachMatch(name: String, body: (CNContact, String) -> Void) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return }

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)

        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch) else {
            return
        }

        for contact in contacts {
            let fullName = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            body(contact, fullName.isEmpty ? name : fullName)
        }
    }
}
