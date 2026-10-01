import Foundation

/// What the music provider needs from Home Assistant (Plan GS P1). A seam so tests never reach a
/// server: `HomeAssistantRESTClient` is the production conformance.
protocol HomeAssistantServiceCalling: Sendable {
    /// Whether a URL and token are set.
    var isConfigured: Bool { get }
    func callService(domain: String, service: String, entityId: String,
                     data: HomeAssistantServiceData) async throws
    func mediaPlayers() async throws -> [HomeAssistantMediaPlayer]
    func mediaPlayer(entityId: String) async throws -> HomeAssistantMediaPlayer?
}

/// Home Assistant's REST API for media players, on the `homeAssistantCommand` route.
///
/// Same transport rules as `HomeAssistantTool`: Medical Local Only is checked first, the address
/// goes through `EndpointPolicy` (Home Assistant is one of the documented local-network routes),
/// and failures are logged by status class only — the body is the home's own state.
struct HomeAssistantRESTClient: HomeAssistantServiceCalling {

    var baseURL: @Sendable () -> String = { Config.homeAssistantURL }
    var token: @Sendable () -> String = { Config.homeAssistantToken }

    var isConfigured: Bool { !baseURL().isEmpty && !token().isEmpty }

    func callService(domain: String, service: String, entityId: String,
                     data: HomeAssistantServiceData) async throws {
        _ = try await request(path: "/api/services/\(domain)/\(service)", method: "POST",
                              body: data.body(entityId: entityId))
    }

    func mediaPlayers() async throws -> [HomeAssistantMediaPlayer] {
        let data = try await request(path: "/api/states", method: "GET", body: nil)
        let states = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return HomeAssistantMediaPlayer.parseStates(states)
    }

    func mediaPlayer(entityId: String) async throws -> HomeAssistantMediaPlayer? {
        let data = try await request(path: "/api/states/\(entityId)", method: "GET", body: nil)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return HomeAssistantMediaPlayer.parse(json)
    }

    private func request(path: String, method: String, body: [String: Any]?) async throws -> Data {
        try MedicalEgressGuard.check(.homeAssistantCommand)
        let requestURL = try EndpointPolicy.requireOpenable(baseURL() + path, for: .homeAssistantCommand)
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            PrivacyLog.requestFailed(.homeAssistant, .http(status: http.statusCode))
            throw URLError(.badServerResponse)
        }
        return data
    }
}
