import Foundation

/// What a native tool sends off the device that the model wrote (Plan LT §2).
///
/// MCP calls have been screened by `EgressScreen` since Plan R, because what an MCP server receives
/// is whatever the model put in the arguments. A native tool that sends a model-written query to a
/// third party — a web search, a places search, a news search — is the same shape and was not
/// screened at all: it is `readOnly`, so the effect-class floor never asked either. A tool that
/// declares one of these is screened by `NativeToolRouter` before it is authorized, exactly like an
/// MCP call, and its outbound text is what the private-span rule (`PrivateSpanCheck`) reads.
///
/// `NativeEgressProfileGuardTests` scrapes `Services/NativeTools` for tools that reach the network
/// and fails on one that declares no profile and has no justified exemption, so a new networked
/// tool has to say here what it sends and to whom.
struct NativeEgressProfile: Equatable, Sendable {

    /// The argument keys whose values leave the device.
    let argumentKeys: [String]
    /// The route the text travels on, where the app owns the transport. `nil` for a request made by
    /// a system framework (MapKit's search is Apple's own request, as `NetworkRoute` records).
    let route: NetworkRoute?
    /// The opening of the spoken ask, ending where the outbound text goes: "Search the web for".
    let askVerb: String

    /// The values under `argumentKeys`, as an argument dictionary, for `EgressScreen`.
    func outboundArguments(from args: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in argumentKeys {
            if let value = args[key] { out[key] = value }
        }
        return out
    }

    /// Every string under `argumentKeys`, in key order.
    func outboundText(from args: [String: Any]) -> [String] {
        argumentKeys.flatMap { key in args[key].map(Self.strings(in:)) ?? [] }
    }

    /// Every string leaf of a JSON-shaped value, in a stable order.
    static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String:
            return [s]
        case let dict as [String: Any]:
            return dict.sorted { $0.key < $1.key }.flatMap { strings(in: $0.value) }
        case let array as [Any]:
            return array.flatMap { strings(in: $0) }
        default:
            return []
        }
    }

    // MARK: - The first set

    /// `web_search`: the query goes to whichever search backend is configured.
    static let webSearch = NativeEgressProfile(argumentKeys: ["query"], route: .webSearch,
                                               askVerb: String(localized: "Search the web for"))
    /// `find_nearby`: the query goes to Apple Maps.
    static let findNearby = NativeEgressProfile(argumentKeys: ["query"], route: nil,
                                                askVerb: String(localized: "Search Maps for"))
    /// `get_news`: the topic goes to the news search.
    static let news = NativeEgressProfile(argumentKeys: ["topic"], route: .newsHeadlines,
                                          askVerb: String(localized: "Look up news about"))
}
