import Foundation
import UIKit

/// Compose and send emails, WhatsApp messages, and Telegram messages.
/// Uses URL schemes to open the appropriate app with pre-filled content.
struct MultiChannelMessageTool: NativeTool {
    let name = "send_via"
    let description = "Opens WhatsApp, Telegram, or Email with a pre-filled message for the user to review and send — it cannot send automatically. For iMessage/SMS, use 'send_message' instead."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "channel": [
                "type": "string",
                "description": "Channel: 'email', 'whatsapp', 'telegram'"
            ],
            "to": [
                "type": "string",
                "description": "Recipient — email address, phone number (+1234567890), or contact name"
            ],
            "body": [
                "type": "string",
                "description": "Message body text"
            ],
            "subject": [
                "type": "string",
                "description": "Email subject line (email only)"
            ]
        ],
        "required": ["channel", "body"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.messaging) else {
            return AIFeatureGate.disabledMessage(.messaging)
        }
        guard let channel = args["channel"] as? String else {
            return "No channel specified. Use 'email', 'whatsapp', or 'telegram'."
        }
        guard let body = args["body"] as? String, !body.isEmpty else {
            return "No message body provided."
        }

        let to = args["to"] as? String ?? ""
        let subject = args["subject"] as? String ?? ""

        switch channel.lowercased() {
        case "email":
            return await sendEmail(to: to, subject: subject, body: body)
        case "whatsapp":
            return await sendWhatsApp(to: to, body: body)
        case "telegram":
            return await sendTelegram(to: to, body: body)
        default:
            return "Unknown channel '\(channel)'. Use 'email', 'whatsapp', or 'telegram'."
        }
    }

    // MARK: - Email

    private func sendEmail(to: String, subject: String, body: String) async -> String {
        var components = URLComponents(string: "mailto:\(to)")
        var queryItems: [URLQueryItem] = []
        if !subject.isEmpty {
            queryItems.append(URLQueryItem(name: "subject", value: subject))
        }
        if !body.isEmpty {
            queryItems.append(URLQueryItem(name: "body", value: body))
        }
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let url = components?.url else {
            return "Couldn't compose email URL."
        }

        let success = await openURL(url)
        if success {
            let recipient = to.isEmpty ? "a new email" : to
            return "Opening Mail to compose email to \(recipient). Please review and send."
        }
        return "Couldn't open Mail. Make sure the Mail app is configured."
    }

    // MARK: - WhatsApp

    private func sendWhatsApp(to: String, body: String) async -> String {
        guard let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "Couldn't encode message."
        }

        let url: URL?
        if !to.isEmpty {
            // Resolve contact name to phone number if needed
            let phone: String
            if ContactLookupHelper.isPhoneNumber(to) {
                phone = to.filter { $0.isNumber || $0 == "+" }
            } else {
                let matches = ContactLookupHelper.resolve(name: to)
                guard let first = matches.first else {
                    return "No contact found matching '\(to)'. Provide a phone number with country code (e.g. +1234567890)."
                }
                phone = first.phoneNumber.filter { $0.isNumber || $0 == "+" }
            }
            url = URL(string: "whatsapp://send?phone=\(phone)&text=\(encodedBody)")
        } else {
            url = URL(string: "whatsapp://send?text=\(encodedBody)")
        }

        guard let whatsappURL = url else {
            return "Couldn't compose WhatsApp URL."
        }

        let success = await openURL(whatsappURL)
        if success {
            return "Opening WhatsApp\(to.isEmpty ? "" : " to \(to)"). Please review and send."
        }
        return "WhatsApp doesn't appear to be installed."
    }

    // MARK: - Telegram

    private func sendTelegram(to: String, body: String) async -> String {
        guard let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "Couldn't encode message."
        }

        let url: URL?
        if !to.isEmpty && to.hasPrefix("@") {
            // Telegram username
            url = URL(string: "tg://resolve?domain=\(to.dropFirst())&text=\(encodedBody)")
        } else if !to.isEmpty {
            url = URL(string: "tg://msg?to=\(to)&text=\(encodedBody)")
        } else {
            url = URL(string: "tg://msg?text=\(encodedBody)")
        }

        guard let telegramURL = url else {
            return "Couldn't compose Telegram URL."
        }

        let success = await openURL(telegramURL)
        if success {
            return "Opening Telegram\(to.isEmpty ? "" : " to \(to)"). Please review and send."
        }
        return "Telegram doesn't appear to be installed."
    }

    // MARK: - Helpers

    private func openURL(_ url: URL) async -> Bool {
        return await MainActor.run {
            guard UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }
    }
}
