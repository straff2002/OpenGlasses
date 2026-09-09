import Foundation

/// Converts between currencies using the free Frankfurter API.
struct CurrencyTool: NativeTool {
    let name = "convert_currency"
    let description = "Convert an amount between currencies using live exchange rates. No API key needed."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "amount": [
                "type": "number",
                "description": "The amount to convert"
            ],
            "from": [
                "type": "string",
                "description": "Source currency code, e.g. 'USD', 'EUR', 'GBP'"
            ],
            "to": [
                "type": "string",
                "description": "Target currency code, e.g. 'EUR', 'JPY', 'GBP'"
            ]
        ],
        "required": ["amount", "from", "to"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard MedicalEgressGuard.allows(.currencyRates) else { return MedicalEgressRefusal.userMessage }
        let amount: Double
        if let a = args["amount"] as? Double {
            amount = a
        } else if let a = args["amount"] as? Int {
            amount = Double(a)
        } else {
            return "Missing or invalid amount."
        }

        guard let from = (args["from"] as? String)?.uppercased(), !from.isEmpty else {
            return "Missing source currency code."
        }
        guard let to = (args["to"] as? String)?.uppercased(), !to.isEmpty else {
            return "Missing target currency code."
        }

        if from == to {
            return "\(formatAmount(amount)) \(from) = \(formatAmount(amount)) \(to) (same currency)"
        }

        let urlString = "https://api.frankfurter.dev/v1/latest?base=\(from)&symbols=\(to)"
        guard let url = URL(string: urlString) else {
            return "Couldn't build currency conversion request."
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return "Currency conversion service is temporarily unavailable. Check that \(from) and \(to) are valid currency codes."
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Double],
              let rate = rates[to] else {
            return "Couldn't parse exchange rate data for \(from) to \(to)."
        }

        let converted = amount * rate
        return "\(formatAmount(amount)) \(from) = \(formatAmount(converted)) \(to) (rate: \(String(format: "%.4f", rate)))"
    }

    private func formatAmount(_ value: Double) -> String {
        if value == value.rounded() && value < 1_000_000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
