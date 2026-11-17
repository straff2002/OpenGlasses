import Foundation

/// Whether the signed-in ChatGPT account offers the model a turn is about to send.
///
/// The subscription backend serves only the models in the account's own catalog, and answers any
/// other id with a 400 ("…model is not supported when using Codex with a ChatGPT account"). A saved
/// model drops out of that catalog when the account's plan changes, when the catalog rotates a
/// family out, or when it was only ever the app's pre-discovery default
/// (`ChatGPTOAuth.defaultModel`). The same refusal has also been seen for a listed model whose own
/// allowance was used up, and it stopped once the allowance came back. Without a check every turn
/// on such a model fails the same way, so the turn sends the catalog's own default instead — for
/// that turn only: the saved setting is the wearer's and is left as it is, and every turn that
/// substitutes asks for a fresh catalog (throttled), so the saved model returns within minutes of
/// the catalog listing it again.
///
/// Whether a refusal came with the backend's usage headers at their limit is recorded too
/// (`limitReading`), so a support report can tell the two causes apart.
///
/// Pure: the catalog is a value read from `ChatGPTContextCatalog`, so every rule is a unit test.
enum ChatGPTModelAvailability {

    /// The models one account's catalog lists.
    struct Catalog: Codable, Equatable {
        /// Every model id listed, hidden ones included: a hidden model is still served.
        let ids: [String]
        /// The ids the picker offers, in catalog order — the candidates for a replacement.
        let pickable: [String]
        /// The model the catalog marks as its default, when it marks one.
        let defaultID: String?
        /// The ids whose catalog row accepts image input (`ChatGPTImageInput.rowAcceptsImages`).
        /// Optional so a snapshot stored before it existed still decodes; such a snapshot says
        /// nothing about images, and photo turns stay refused until a fresh catalog arrives.
        var imageInput: [String]?

        init(ids: [String], pickable: [String], defaultID: String?, imageInput: [String]? = nil) {
            self.ids = ids
            self.pickable = pickable
            self.defaultID = defaultID
            self.imageInput = imageInput
        }

        /// Read from the `/codex/models` payload — the same rows `ModelFetcher` parses for the
        /// picker. Nil for a payload that is not a catalog.
        init?(data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let rows = object["models"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            let ids = rows.compactMap { row -> String? in
                guard let id = row["slug"] as? String ?? row["id"] as? String ?? row["model"] as? String,
                      !id.isEmpty, seen.insert(id).inserted else { return nil }
                return id
            }
            let pickable = ModelFetcher.parseChatGPTModels(data)
            var seenImage = Set<String>()
            let imageInput = rows.compactMap { row -> String? in
                guard let id = row["slug"] as? String ?? row["id"] as? String ?? row["model"] as? String,
                      !id.isEmpty, ChatGPTImageInput.rowAcceptsImages(row),
                      seenImage.insert(id).inserted else { return nil }
                return id
            }
            self.init(ids: ids, pickable: pickable.map(\.id),
                      defaultID: pickable.first(where: \.isDefault)?.id, imageInput: imageInput)
        }
    }

    enum Decision: Equatable {
        /// Send the model as saved: the catalog lists it, or there is no catalog to judge by.
        case send
        /// The catalog does not list the saved model; send this one instead.
        case substitute(String)
    }

    /// Said once per saved model per process, ahead of the first reply that used another one.
    /// It names no model: an id read aloud is noise, and the setting is where the names are. It
    /// allows for a used-up allowance as well as a plan without the model, since the backend's
    /// refusal does not say which.
    static let substitutionNotice =
        "The model you picked isn't available on your ChatGPT account right now — it may have reached its usage limit — so I used your account's default model. You can change it in Settings."

    /// What the backend's usage headers said on a refusal. Only the verdict is kept, never a value.
    enum LimitReading: String, Equatable {
        /// At least one usage header was at 100 or more.
        case exhausted = "limitExhausted"
        /// Usage headers came, and none was at its limit.
        case belowLimit = "limitBelow"
        /// No usage header came with the refusal.
        case absent = "limitHeadersAbsent"
    }

    /// Read the usage headers the upstream client reads: `x-<limit>-primary-used-percent` and
    /// `x-<limit>-secondary-used-percent`, where the limit is `codex` by default and another name
    /// for a separately metered one. Header names are matched without regard to case; a value that
    /// is not a number is not a reading.
    static func limitReading(headers: [AnyHashable: Any]) -> LimitReading {
        var sawReading = false
        for (key, value) in headers {
            guard let name = (key as? String)?.lowercased(), name.hasPrefix("x-"),
                  name.hasSuffix("-primary-used-percent") || name.hasSuffix("-secondary-used-percent")
            else { continue }
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue
            guard let percent = text.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { continue }
            if percent >= 100 { return .exhausted }
            sawReading = true
        }
        return sawReading ? .belowLimit : .absent
    }

    /// The model a ChatGPT turn sends in place of `model`, or nil to send it as saved. A
    /// substitution also marks the stored catalog stale: the saved model may be missing only while
    /// its allowance is used up, so every turn that substitutes asks for a fresh catalog
    /// (`sendChatGPT` fetches it, at most once per `ChatGPTContextCatalog.retryAfter`) and the
    /// saved model comes back within minutes of being listed again.
    @MainActor
    static func modelForTurn(_ model: String, accountID: String?, now: Date = Date()) -> String? {
        guard case .substitute(let offered) = decide(
            model: model, catalog: ChatGPTContextCatalog.offered(accountID: accountID, now: now)) else { return nil }
        ChatGPTContextCatalog.markStale()
        return offered
    }

    /// The decision for one turn. Never blocks a turn: with no catalog, an empty one, or nothing to
    /// offer in its place, the saved model is sent and the backend has the last word.
    static func decide(model: String, catalog: Catalog?) -> Decision {
        guard let catalog, !catalog.ids.isEmpty, !catalog.ids.contains(model) else { return .send }
        if let defaultID = catalog.defaultID, catalog.ids.contains(defaultID) {
            return .substitute(defaultID)
        }
        return catalog.pickable.first.map(Decision.substitute) ?? .send
    }
}
