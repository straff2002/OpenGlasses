import Foundation
import UIKit

/// Opens the Messages app with a pre-filled recipient and message body.
/// Automatically resolves contact names to phone numbers.
struct SendMessageTool: NativeTool {
    let name = "send_message"
    let description = "Opens Messages with a pre-filled SMS/iMessage for the user to review and send — it cannot send automatically. Accepts a phone number OR a contact name (auto-looked-up in Contacts); if multiple matches are found, returns options for the user to choose."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "to": [
                "type": "string",
                "description": "Phone number (e.g. '+1234567890') or contact name (e.g. 'Mom', 'John'). Names are auto-resolved from Contacts."
            ],
            "body": [
                "type": "string",
                "description": "The message text to send"
            ]
        ],
        "required": ["to", "body"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.messaging) else {
            return AIFeatureGate.disabledMessage(.messaging)
        }
        guard let to = args["to"] as? String, !to.isEmpty else {
            return "No recipient provided."
        }
        guard let body = args["body"] as? String, !body.isEmpty else {
            return "No message body provided."
        }

        // Determine if 'to' is a phone number or a name
        let phoneNumber: String
        let displayName: String

        if ContactLookupHelper.isPhoneNumber(to) {
            // It's already a phone number
            phoneNumber = to
            displayName = to
        } else {
            // It's a name — look up in Contacts
            let matches = ContactLookupHelper.resolve(name: to)

            if matches.isEmpty {
                return "No contact found matching '\(to)'. Please provide a phone number instead, or check the name."
            } else if matches.count == 1 {
                phoneNumber = matches[0].phoneNumber
                displayName = matches[0].name
            } else {
                // Multiple matches — check if they're all the same person (multiple numbers)
                let uniqueNames = Set(matches.map { $0.name })
                if uniqueNames.count == 1 && matches.count <= 3 {
                    // Same person, multiple numbers — use the first (usually mobile)
                    let mobileMatch = matches.first { $0.phoneLabel.lowercased().contains("mobile") || $0.phoneLabel.lowercased().contains("iphone") }
                    let chosen = mobileMatch ?? matches[0]
                    phoneNumber = chosen.phoneNumber
                    displayName = chosen.name
                } else {
                    // Different people — list options
                    var options: [String] = []
                    for (i, match) in matches.prefix(5).enumerated() {
                        let label = match.phoneLabel.isEmpty ? "" : " (\(match.phoneLabel))"
                        options.append("\(i + 1). \(match.name)\(label): \(match.phoneNumber)")
                    }
                    return "Multiple contacts match '\(to)'. Which one?\n\(options.joined(separator: "\n"))\nPlease specify the full name or provide the phone number directly."
                }
            }
        }

        // Clean number for URL
        let cleanedNumber = phoneNumber.filter { $0.isNumber || $0 == "+" }

        guard let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "sms:\(cleanedNumber)&body=\(encodedBody)") else {
            return "Couldn't compose the message."
        }

        await MainActor.run {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }

        return "Opening Messages to \(displayName) (\(phoneNumber)). Please confirm and send."
    }
}
