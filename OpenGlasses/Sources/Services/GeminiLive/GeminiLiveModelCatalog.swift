import Foundation

/// Asks the account which models can actually open a Live session.
///
/// `ModelService.ListModels` reports `supportedGenerationMethods` per model, and
/// `bidiGenerateContent` is the Live method — so entitlement, availability and retirement are all
/// answered by one cheap REST call with the key we already hold. The endpoint told us to make it:
/// the refusal that cost a device session ended with "Call ModelService.ListModels to see the list
/// of available models and their supported methods".
///
/// Cached per key for the session and persisted, because the answer changes on the order of weeks
/// and a wearer starting a session should not wait on a round trip to find out what to connect to.
actor GeminiLiveModelCatalog {
    static let shared = GeminiLiveModelCatalog()

    private var cache: [String: [String]] = [:]      // apiKey → live-capable model ids
    private static let defaultsKey = "geminiLiveModelsCache"

    /// API versions to ask, in order. Live models have historically appeared in `v1alpha` before
    /// `v1beta`, so a key entitled only to a preview family is still discoverable.
    private static let apiVersions = ["v1beta", "v1alpha"]

    /// Live-capable model ids for this key, or `[]` when the list could not be fetched.
    /// Never throws: a failed lookup degrades to the caller's offline fallback, and a wearer
    /// starting a session must not be blocked by a diagnostic call.
    func liveModels(apiKey: String, timeout: TimeInterval = 6) async -> [String] {
        guard !apiKey.isEmpty else { return [] }
        if let cached = cache[apiKey], !cached.isEmpty { return cached }
        if let stored = Self.storedCache()[apiKey], !stored.isEmpty {
            cache[apiKey] = stored
            return stored
        }

        for version in Self.apiVersions {
            let found = await fetch(apiKey: apiKey, version: version, timeout: timeout)
            if !found.isEmpty {
                cache[apiKey] = found
                Self.store(found, for: apiKey)
                PrivacyLog.model(.catalogDiscovered, provider: PrivacyToken("gemini"),
                                 count: found.count, detail: PrivacyToken(version))
                return found
            }
        }
        PrivacyLog.model(.catalogUnavailable, provider: PrivacyToken("gemini"))
        return []
    }

    /// Drop what we know, so a settings refresh re-asks after a key or plan change.
    func invalidate() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func fetch(apiKey: String, version: String, timeout: TimeInterval) async -> [String] {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/\(version)/models?key=\(apiKey)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }

        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("bidiGenerateContent") else { return nil }
            return GeminiLiveModelPolicy.bareId(name)
        }
    }

    private static func storedCache() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    private static func store(_ models: [String], for apiKey: String) {
        var all = storedCache()
        all[apiKey] = models
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}
