import Foundation

/// Converts between currencies using the free Frankfurter API, falling back to AllRatesToday's
/// keyless ECB table when Frankfurter is unreachable, answers non-200 or returns a body without the
/// requested rate. Only a well-formed three-letter code ever leaves the device, and each source gets
/// `perSourceTimeout`, so the wearer waits no longer than the single-source tool did.
struct CurrencyTool: NativeTool {
    /// Session the rate requests go through. Tests inject a stubbed one.
    var session: URLSession? = nil

    /// Two sources in turn share the 10 s the single source used to have.
    static let perSourceTimeout: TimeInterval = 5

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

        guard let rawFrom = args["from"] as? String, !rawFrom.isEmpty else {
            return "Missing source currency code."
        }
        guard let rawTo = args["to"] as? String, !rawTo.isEmpty else {
            return "Missing target currency code."
        }
        guard let from = Self.currencyCode(rawFrom) else { return Self.notACode(rawFrom) }
        guard let to = Self.currencyCode(rawTo) else { return Self.notACode(rawTo) }

        if from == to {
            return "\(formatAmount(amount)) \(from) = \(formatAmount(amount)) \(to) (same currency)"
        }

        guard let rate = await fetchRate(from: from, to: to) else {
            return "Currency conversion service is temporarily unavailable. Check that \(from) and \(to) are valid currency codes."
        }

        let converted = amount * rate
        return "\(formatAmount(amount)) \(from) = \(formatAmount(converted)) \(to) (rate: \(String(format: "%.4f", rate)))"
    }

    /// Frankfurter first, AllRatesToday second. Each source is a 200 whose JSON `rates[to]` is a
    /// number; anything else (network error, other status, unparsable body, missing code) moves on
    /// to the next. `nil` when neither answered.
    func fetchRate(from: String, to: String) async -> Double? {
        let sources = [
            "https://api.frankfurter.dev/v1/latest?base=\(from)&symbols=\(to)",
            "https://allratestoday.com/api/open/latest/\(from)"
        ]
        for urlString in sources {
            guard let url = URL(string: urlString) else { continue }
            if let rate = await fetchRate(url: url, code: to) { return rate }
        }
        return nil
    }

    /// A three-letter ISO 4217-shaped code, uppercased, or nil. The code goes into a query string
    /// and a URL path, so anything else is refused before a request is built.
    static func currencyCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    private static func notACode(_ raw: String) -> String {
        "\"\(raw)\" isn't a currency code. Use a three-letter code such as USD, EUR or GBP."
    }

    private func fetchRate(url: URL, code: String) async -> Double? {
        let request = URLRequest(url: url, timeoutInterval: Self.perSourceTimeout)
        guard let (data, response) = try? await (session ?? .shared).data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Any] else {
            return nil
        }
        return rates[code] as? Double
    }

    private func formatAmount(_ value: Double) -> String {
        if value == value.rounded() && value < 1_000_000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
