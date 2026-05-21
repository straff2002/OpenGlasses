import Foundation

/// Returns a structured hint for the LLM to translate text inline.
/// The LLM does the actual translation in its response.
struct TranslationTool: NativeTool {
    let name = "translate"
    let description = "Translate text between languages. Works with text from camera captures — can translate foreign signs, menus, labels, and documents seen through the glasses."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": [
                "type": "string",
                "description": "The text to translate"
            ],
            "to_language": [
                "type": "string",
                "description": "Target language, e.g. 'Spanish', 'French', 'Japanese'"
            ],
            "from_language": [
                "type": "string",
                "description": "Source language (optional, auto-detected if omitted)"
            ]
        ],
        "required": ["text", "to_language"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return "No text provided to translate."
        }
        guard let toLang = args["to_language"] as? String, !toLang.isEmpty else {
            return "No target language specified."
        }

        let fromLang = args["from_language"] as? String

        if let fromLang {
            return "Translate the following from \(fromLang) to \(toLang): \"\(text)\""
        }
        return "Translate to \(toLang): \"\(text)\""
    }
}

struct TranslateSignMenuTool: NativeTool {
    let name = "translate_sign_menu"
    let description = "Translate signs, menus, labels, and storefront text from camera view. Returns a strict translation task for the assistant."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "target_language": [
                "type": "string",
                "description": "Target language. Defaults to English."
            ],
            "text": [
                "type": "string",
                "description": "Optional source text when already extracted. If omitted, read from current camera image."
            ]
        ],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let target = (args["target_language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLanguage = (target?.isEmpty == false) ? target! : "English"
        let extractedText = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let extractedText, !extractedText.isEmpty {
            return "Translate this sign/menu text to \(targetLanguage). Keep line order. Return ORIGINAL first, then TRANSLATION. Text: \"\(extractedText)\""
        }

        return "Read all visible sign/menu text from the current image. Translate to \(targetLanguage). Return ORIGINAL first, then TRANSLATION. If any text is unclear, mark it as [unclear]."
    }
}

final class AskLocalPhraseTool: NativeTool, @unchecked Sendable {
    let name = "ask_local_phrase"
    let description = "Generate practical traveler phrases in the local language with pronunciation and a polite variant."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "intent": [
                "type": "string",
                "description": "What the user wants to say, e.g. 'Where is platform 4?'"
            ],
            "target_language": [
                "type": "string",
                "description": "Optional language override. If omitted, inferred from current country."
            ],
            "tone": [
                "type": "string",
                "description": "Optional tone: polite or casual.",
                "enum": ["polite", "casual"]
            ]
        ],
        "required": ["intent"]
    ]

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let intent = (args["intent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !intent.isEmpty else {
            return "No intent provided. Tell me what you want to say."
        }

        let explicitLanguage = (args["target_language"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tone = ((args["tone"] as? String) ?? "polite").lowercased()

        let resolvedLanguage: String
        if let explicitLanguage, !explicitLanguage.isEmpty {
            resolvedLanguage = explicitLanguage
        } else if let countryCode = await currentCountryCode(),
                  let inferred = Self.languageByCountry[countryCode] {
            resolvedLanguage = inferred
        } else {
            resolvedLanguage = "local language"
        }

        if tone == "casual" {
            return "Convert this traveler intent into natural \(resolvedLanguage). Intent: \"\(intent)\". Return: 1) local phrase, 2) pronunciation, 3) concise English meaning."
        }

        return "Convert this traveler intent into polite natural \(resolvedLanguage). Intent: \"\(intent)\". Return: 1) local phrase, 2) pronunciation, 3) concise English meaning, 4) shorter backup phrase."
    }

    private func currentCountryCode() async -> String? {
        guard let location = await MainActor.run(body: { locationService.currentLocation }) else { return nil }
        return await GeocodingHelper.countryCode(for: location)
    }

    private static let languageByCountry: [String: String] = [
        "JP": "Japanese",
        "KR": "Korean",
        "CN": "Mandarin Chinese",
        "TW": "Mandarin Chinese",
        "TH": "Thai",
        "VN": "Vietnamese",
        "ID": "Indonesian",
        "MY": "Malay",
        "PH": "Filipino",
        "FR": "French",
        "ES": "Spanish",
        "IT": "Italian",
        "DE": "German",
        "PT": "Portuguese",
        "BR": "Portuguese",
        "NL": "Dutch",
        "TR": "Turkish",
        "GR": "Greek",
        "PL": "Polish",
        "CZ": "Czech",
        "HU": "Hungarian",
        "RO": "Romanian",
    ]
}
