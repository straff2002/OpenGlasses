import Foundation

/// Manages downloadable language packs for on-demand localization.
///
/// Bundled languages (en, fr, es, de, ja, pl, zh-Hans, zh-Hant, uk) are built into
/// the app via Localizable.xcstrings. Additional languages can be downloaded from
/// GitHub and cached locally.
@MainActor
final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    // MARK: - Types

    struct LanguagePack: Identifiable, Codable {
        let code: String
        let name: String
        let nativeName: String
        var isDownloaded: Bool
        var stringCount: Int

        var id: String { code }
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(String) // language code
        case failed(String)      // error message
    }

    // MARK: - Published State

    @Published var downloadableLanguages: [LanguagePack] = []
    @Published var downloadState: DownloadState = .idle

    // MARK: - Constants

    /// Bundled language codes — these ship with the app in Localizable.xcstrings.
    static let bundledLanguages: Set<String> = [
        "en", "fr", "es", "es-MX", "de", "ja", "pl", "zh-Hans", "zh-Hant", "uk"
    ]

    /// Base URL for downloading translation JSON files from GitHub.
    private static let translationsBaseURL =
        "https://raw.githubusercontent.com/straff2002/OpenGlasses/main/OpenGlasses/Sources/Resources/Translations"

    /// All available downloadable languages with display metadata.
    private static let availableLanguages: [(code: String, name: String, nativeName: String, stringCount: Int)] = [
        ("ar", "Arabic", "العربية", 137),
        ("ca", "Catalan", "Català", 28),
        ("cs", "Czech", "Čeština", 137),
        ("da", "Danish", "Dansk", 34),
        ("el", "Greek", "Ελληνικά", 34),
        ("fi", "Finnish", "Suomi", 35),
        ("fr-CA", "French (Canada)", "Français (Canada)", 58),
        ("hi", "Hindi", "हिन्दी", 58),
        ("hr", "Croatian", "Hrvatski", 28),
        ("hu", "Hungarian", "Magyar", 29),
        ("id", "Indonesian", "Bahasa Indonesia", 28),
        ("it", "Italian", "Italiano", 137),
        ("ko", "Korean", "한국어", 137),
        ("ms", "Malay", "Bahasa Melayu", 28),
        ("nb", "Norwegian", "Norsk bokmål", 34),
        ("nl", "Dutch", "Nederlands", 137),
        ("pt-BR", "Portuguese (Brazil)", "Português (Brasil)", 137),
        ("pt-PT", "Portuguese (Portugal)", "Português (Portugal)", 34),
        ("ro", "Romanian", "Română", 29),
        ("ru", "Russian", "Русский", 58),
        ("sk", "Slovak", "Slovenčina", 28),
        ("sv", "Swedish", "Svenska", 39),
        ("th", "Thai", "ไทย", 137),
        ("tr", "Turkish", "Türkçe", 34),
        ("vi", "Vietnamese", "Tiếng Việt", 28),
    ]

    /// Bundled language display info.
    static let bundledLanguageInfo: [(code: String, name: String, nativeName: String)] = [
        ("en", "English", "English"),
        ("fr", "French", "Français"),
        ("es", "Spanish", "Español"),
        ("es-MX", "Spanish (Mexico)", "Español (México)"),
        ("de", "German", "Deutsch"),
        ("ja", "Japanese", "日本語"),
        ("pl", "Polish", "Polski"),
        ("zh-Hans", "Chinese (Simplified)", "简体中文"),
        ("zh-Hant", "Chinese (Traditional)", "繁體中文"),
        ("uk", "Ukrainian", "Українська"),
    ]

    // MARK: - Storage

    private let cacheDirectory: URL
    private let downloadedKey = "downloadedLanguageCodes"

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("LanguagePacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadLanguageList()
    }

    // MARK: - Public API

    /// Refresh the list of downloadable languages and their download status.
    func loadLanguageList() {
        let downloaded = downloadedLanguageCodes()
        downloadableLanguages = Self.availableLanguages.map { lang in
            LanguagePack(
                code: lang.code,
                name: lang.name,
                nativeName: lang.nativeName,
                isDownloaded: downloaded.contains(lang.code),
                stringCount: lang.stringCount
            )
        }
    }

    /// Download a language pack from GitHub.
    func downloadLanguage(_ code: String) async {
        downloadState = .downloading(code)

        let urlString = "\(Self.translationsBaseURL)/\(code).json"
        guard let url = URL(string: urlString) else {
            downloadState = .failed("Invalid URL for \(code)")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                downloadState = .failed("Language pack not available (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return
            }

            // Validate it's valid JSON
            _ = try JSONSerialization.jsonObject(with: data)

            // Save to cache
            let filePath = cacheDirectory.appendingPathComponent("\(code).json")
            try data.write(to: filePath, options: .atomic)

            // Record as downloaded
            var codes = downloadedLanguageCodes()
            codes.insert(code)
            saveDownloadedLanguageCodes(codes)

            // Update UI
            if let index = downloadableLanguages.firstIndex(where: { $0.code == code }) {
                downloadableLanguages[index].isDownloaded = true
            }
            downloadState = .idle
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    /// Remove a downloaded language pack.
    func removeLanguage(_ code: String) {
        let filePath = cacheDirectory.appendingPathComponent("\(code).json")
        try? FileManager.default.removeItem(at: filePath)

        var codes = downloadedLanguageCodes()
        codes.remove(code)
        saveDownloadedLanguageCodes(codes)

        if let index = downloadableLanguages.firstIndex(where: { $0.code == code }) {
            downloadableLanguages[index].isDownloaded = false
        }
    }

    /// Load translations for a given language code. Returns nil if not available.
    func translations(for code: String) -> [String: String]? {
        let filePath = cacheDirectory.appendingPathComponent("\(code).json")
        guard let data = try? Data(contentsOf: filePath),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict
    }

    /// Check if a language is available (bundled or downloaded).
    func isLanguageAvailable(_ code: String) -> Bool {
        Self.bundledLanguages.contains(code) || downloadedLanguageCodes().contains(code)
    }

    /// Total size of all downloaded language packs.
    func downloadedSize() -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "0 KB"
        }
        let totalBytes = files.compactMap { url -> Int? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize
        }.reduce(0, +)

        if totalBytes < 1024 {
            return "\(totalBytes) B"
        } else if totalBytes < 1024 * 1024 {
            return "\(totalBytes / 1024) KB"
        } else {
            return String(format: "%.1f MB", Double(totalBytes) / 1_048_576.0)
        }
    }

    /// Download all available languages at once.
    func downloadAll() async {
        for lang in downloadableLanguages where !lang.isDownloaded {
            await downloadLanguage(lang.code)
            if case .failed = downloadState { return }
        }
    }

    /// Remove all downloaded language packs.
    func removeAll() {
        for lang in downloadableLanguages where lang.isDownloaded {
            removeLanguage(lang.code)
        }
    }

    // MARK: - Private

    private func downloadedLanguageCodes() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: downloadedKey) ?? []
        return Set(array)
    }

    private func saveDownloadedLanguageCodes(_ codes: Set<String>) {
        UserDefaults.standard.set(Array(codes).sorted(), forKey: downloadedKey)
    }
}
