import Foundation

/// User-supplied configuration for the Custom URL agent harness (Plan N, Phase 2). Same spirit as a
/// custom MCP server or tool: a power user points OpenGlasses at any agent endpoint they already run
/// (a self-hosted Agent SDK bridge, an internal service…) by giving its URLs, auth, and a small JSON
/// field mapping. Keychain-backed (it holds a token).
struct CustomHarnessConfig: Codable, Equatable {
    var name: String = "Custom"
    /// POST endpoint that starts a run. Required.
    var startURL: String = ""
    /// Status endpoint; `{id}` is substituted with the run id (e.g. "https://host/runs/{id}").
    var statusURLTemplate: String = ""
    /// Optional cancel endpoint; `{id}` substituted. POST.
    var cancelURLTemplate: String = ""

    /// Auth header applied to every request (header name + value). Empty ⇒ no auth header.
    var authHeader: String = "Authorization"
    var authValue: String = ""

    /// JSON body keys for the start request.
    var promptField: String = "prompt"
    var projectField: String = "project"

    /// Dot-paths into the responses (e.g. "data.run.id"). See `JSONPath`.
    var idPath: String = "id"
    var statusPath: String = "status"

    /// Minimum viable config: a parseable start URL.
    var isConfigured: Bool {
        let trimmed = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && URL(string: trimmed) != nil
    }
}

extension CustomHarnessConfig {
    /// Build the start request, or `nil` if `startURL` is invalid.
    func startRequest(prompt: String, project: String?) -> URLRequest? {
        guard let url = URL(string: startURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        var body: [String: Any] = [promptField: prompt]
        if let project, !project.isEmpty { body[projectField] = project }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return request
    }

    /// The status URL for `runID` from the template, or `nil` if no template is set.
    func statusURL(runID: String) -> URL? {
        let filled = statusURLTemplate.replacingOccurrences(of: "{id}", with: runID)
        guard !filled.isEmpty else { return nil }
        return URL(string: filled)
    }

    /// Build the status (GET) request for `runID`, or `nil` if no status template is set.
    func statusRequest(runID: String) -> URLRequest? {
        guard let url = statusURL(runID: runID) else { return nil }
        var request = URLRequest(url: url)
        applyAuth(&request)
        request.timeoutInterval = 15
        return request
    }

    /// Build the cancel (POST) request for `runID`, or `nil` if no cancel template is set.
    func cancelRequest(runID: String) -> URLRequest? {
        let filled = cancelURLTemplate.replacingOccurrences(of: "{id}", with: runID)
        guard !filled.isEmpty, let url = URL(string: filled) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(&request)
        request.timeoutInterval = 15
        return request
    }

    private func applyAuth(_ request: inout URLRequest) {
        guard !authHeader.isEmpty, !authValue.isEmpty else { return }
        request.setValue(authValue, forHTTPHeaderField: authHeader)
    }
}

/// Minimal dot-path extraction over a decoded JSON object (Plan N, Phase 2). Lets a custom endpoint's
/// response shape be mapped without code — "data.run.id" walks nested dictionaries. Pure + tested.
enum JSONPath {
    /// The value at `path` ("a.b.c") in `json`, or `nil` if any segment is missing or not a dict.
    static func value(at path: String, in json: [String: Any]) -> Any? {
        var current: Any = json
        for segment in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(segment)] else { return nil }
            current = next
        }
        return current
    }

    /// The string value at `path`, coercing a number/bool to its text form when reasonable.
    static func string(at path: String, in json: [String: Any]) -> String? {
        switch value(at: path, in: json) {
        case let s as String: return s
        case let n as Int:    return String(n)
        case let b as Bool:   return b ? "true" : "false"
        default:              return nil
        }
    }
}
