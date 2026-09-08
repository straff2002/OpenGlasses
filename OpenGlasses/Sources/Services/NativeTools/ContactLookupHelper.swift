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
