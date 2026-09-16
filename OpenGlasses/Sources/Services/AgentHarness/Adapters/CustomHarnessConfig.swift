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

    /// Plan CN: body key carrying a base64 JPEG of the wearer's view. **Empty by default, meaning
    /// never attach.** An arbitrary user-configured endpoint must not start receiving multi-megabyte
    /// bodies because a setting elsewhere got flipped — opting in is naming the field.
    var imageField: String = ""

    /// Dot-paths into the responses (e.g. "data.run.id"). See `JSONPath`.
    var idPath: String = "id"
    var statusPath: String = "status"

    // MARK: - Result mapping (Plan FE P0)
    //
    // Dot-paths read from the **same** status response, so richer reporting costs no extra
    // requests. Every one defaults to empty, and an empty path means the endpoint does not report
    // that field — which is *unknown*, never "none". Nothing is guessed: we only claim what a
    // path the user named actually returned. See `docs/agent-harness-wire-contract.md`.

    /// The agent's closing words (string).
    var finalTextPath: String = ""
    /// Arrays of paths the run created / modified (arrays of strings).
    var filesCreatedPath: String = ""
    var filesModifiedPath: String = ""
    /// Commands the run executed (array of strings).
    var commandsRunPath: String = ""
    /// Whether the run pushed (bool, or 0/1, or "true"/"false").
    var pushedPath: String = ""
    /// URL of a pull request the run opened (string; must parse as http(s)).
    var prURLPath: String = ""
    /// The endpoint's own error message for a failed run (string).
    var errorPath: String = ""

    // MARK: - Explicit agent selection (Plan FE P1)
    //
    // One endpoint in front of several coding agents needs to be told which one. This is a
    // **configured request value** — a field name and the value to send in it — and nothing else:
    // it is not persona routing, not wake-word routing, and no spoken phrase can change it. Both
    // empty by default, and the pair only rides the start body when both are set.

    /// Body key naming which agent the endpoint should run (e.g. "agent").
    var agentField: String = ""
    /// The value sent in `agentField` (e.g. "reviewer").
    var agentValue: String = ""

    // MARK: - Questions and replies (Plan FE P1)
    //
    // Reading a pending question, and answering it. All optional: an endpoint that maps none of
    // these can still be polled, it simply never asks anything and can never be answered — which
    // is reported honestly rather than papered over with a silent boolean.

    /// POST endpoint that carries a reply; `{id}` is substituted with the run id. Empty ⇒ this
    /// endpoint cannot be answered, and saying so is the correct behaviour.
    var inputURLTemplate: String = ""
    /// Body key carrying the wearer's words (free-text answers). The decision, question id,
    /// revision and reply id ride the reserved keys in `reservedReplyKeys`.
    var inputField: String = "reply"

    /// Dot-paths into the status response describing the question the run is waiting on.
    /// Without `questionPromptPath` a waiting run is announced with a generic line; without
    /// `questionIDPath` the identity is derived from `(run, wording, arrival order)`.
    var questionPromptPath: String = ""
    var questionIDPath: String = ""
    var questionRevisionPath: String = ""
    /// Which kind of answer is wanted. Anything unmapped or unrecognised is read as an
    /// **approval** — the shape that goes through the consent prompt (see `AgentQuestion.kind`).
    var questionKindPath: String = ""

    // MARK: - Delivery acknowledgement (Plan FE P4)

    /// POST endpoint told when a result revision finished playing to the wearer; `{id}` is the run
    /// id. Empty by default, meaning nothing is ever sent — an endpoint that does not ask to be
    /// told is not told, and no acknowledgement traffic appears because a feature shipped.
    ///
    /// What the acknowledgement means is stated in the wire contract and nowhere else is it
    /// allowed to mean more: audio for that revision ran to its end on this device.
    var ackURLTemplate: String = ""

    /// Minimum viable config: a parseable, transport-secure start URL. The auth token rides every
    /// request, so `http://` is refused except to loopback (a local bridge in development) — BM P5.
    var isConfigured: Bool {
        let trimmed = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return Self.isTransportSecure(url)
    }

    /// Why the start URL is refused, for the settings UI — or `nil` when it's empty or acceptable.
    var transportIssue: String? {
        let trimmed = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), !Self.isTransportSecure(url) else { return nil }
        return "Use https — over http the auth token is sent in cleartext (http is allowed only for localhost)."
    }

    /// https anywhere; http only to loopback hosts.
    static func isTransportSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            let host = url.host?.lowercased() ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
        default:
            return false
        }
    }
}

extension CustomHarnessConfig {
    /// Backward-compatible decoding (Plan FE P0). The result-mapping paths were added after
    /// endpoints were already saved in the Keychain, so **every** key is optional with a default:
    /// a config written by an older build must keep decoding, because a decode failure here
    /// silently erases the user's endpoint (and its token) rather than degrading it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys, _ fallback: String) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init()
        name = string(.name, name)
        startURL = string(.startURL, startURL)
        statusURLTemplate = string(.statusURLTemplate, statusURLTemplate)
        cancelURLTemplate = string(.cancelURLTemplate, cancelURLTemplate)
        authHeader = string(.authHeader, authHeader)
        authValue = string(.authValue, authValue)
        promptField = string(.promptField, promptField)
        projectField = string(.projectField, projectField)
        imageField = string(.imageField, imageField)
        idPath = string(.idPath, idPath)
        statusPath = string(.statusPath, statusPath)
        finalTextPath = string(.finalTextPath, finalTextPath)
        filesCreatedPath = string(.filesCreatedPath, filesCreatedPath)
        filesModifiedPath = string(.filesModifiedPath, filesModifiedPath)
        commandsRunPath = string(.commandsRunPath, commandsRunPath)
        pushedPath = string(.pushedPath, pushedPath)
        prURLPath = string(.prURLPath, prURLPath)
        errorPath = string(.errorPath, errorPath)
        // Plan FE P1 keys. Same rule as above: a config written before they existed decodes with
        // these defaults and keeps its token, rather than failing and erasing the endpoint.
        agentField = string(.agentField, agentField)
        agentValue = string(.agentValue, agentValue)
        inputURLTemplate = string(.inputURLTemplate, inputURLTemplate)
        inputField = string(.inputField, inputField)
        questionPromptPath = string(.questionPromptPath, questionPromptPath)
        questionIDPath = string(.questionIDPath, questionIDPath)
        questionRevisionPath = string(.questionRevisionPath, questionRevisionPath)
        questionKindPath = string(.questionKindPath, questionKindPath)
        // Plan FE P4. Same rule again: added after configs were saved, so it decodes to its
        // default rather than failing the whole config (and taking the token with it).
        ackURLTemplate = string(.ackURLTemplate, ackURLTemplate)
    }

    // MARK: - Field collisions (Plan FE P1)

    /// Body keys the reply POST always carries. `inputField` may not be one of them: silently
    /// letting the wearer's words land on top of the question id is exactly the "configuration
    /// error, quietly overwritten" this rule exists to prevent.
    static let reservedReplyKeys = ["questionId", "questionRevision", "replyId", "decision"]

    /// Why the field mapping is refused, for the settings UI — or `nil` when it is coherent.
    ///
    /// Two body keys with the same name mean one value overwrites the other in the JSON we build,
    /// and the endpoint receives a request that quietly lost a field. That is a configuration
    /// error, so it is named in Settings and the request is refused, not sent half-formed.
    var fieldCollisionIssue: String? {
        var claimed: [String: String] = [:]
        for (label, raw) in [("Prompt field", promptField), ("Project field", projectField),
                             ("Image field", imageField), ("Agent field", agentField)] {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let other = claimed[key] {
                return "\(other) and \(label) both send “\(key)”. Give each its own body key."
            }
            claimed[key] = label
        }
        guard !inputURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let answer = inputField.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            return "Set an answer field for the input endpoint, so a typed reply has a key to ride in."
        }
        if Self.reservedReplyKeys.contains(answer) {
            return "“\(answer)” is reserved on the reply — it already carries "
                + Self.reservedReplyKeys.joined(separator: ", ") + ". Pick another answer field."
        }
        return nil
    }

    /// Whether this endpoint asked to be told about delivered results.
    var acceptsDeliveryAcks: Bool {
        !ackURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether this endpoint can be answered at all.
    var acceptsReplies: Bool {
        !inputURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && fieldCollisionIssue == nil
    }

    /// Whether any question field is mapped — the settings UI uses it to explain that an unmapped
    /// endpoint's waiting run is announced generically.
    var mapsAnyQuestionField: Bool {
        ![questionPromptPath, questionIDPath, questionRevisionPath, questionKindPath]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether any result field is mapped at all — the settings UI uses it to explain that an
    /// unmapped endpoint can only report *that* a run finished, not what it did.
    var mapsAnyResultField: Bool {
        ![finalTextPath, filesCreatedPath, filesModifiedPath, commandsRunPath,
          pushedPath, prURLPath, errorPath]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

extension CustomHarnessConfig {
    /// Build the start request, or `nil` if `startURL` is invalid.
    func startRequest(prompt: String, project: String?) -> URLRequest? {
        startRequest(prompt: prompt, project: project, attachment: nil)
    }

    func startRequest(prompt: String, project: String?, attachment: AgentTaskAttachment?) -> URLRequest? {
        // A colliding mapping would send a body with a field silently missing. Refuse instead:
        // the dispatch fails loudly and Settings says which two keys clash.
        guard fieldCollisionIssue == nil else { return nil }
        guard let url = URL(string: startURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        var body: [String: Any] = [promptField: prompt]
        if let project, !project.isEmpty { body[projectField] = project }

        // Plan FE P1: which agent this endpoint should run, when the wearer configured the pair.
        let agentKey = agentField.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = agentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agentKey.isEmpty, !agent.isEmpty { body[agentKey] = agent }

        // Plan CN: only when the user named a field for it.
        let field = imageField.trimmingCharacters(in: .whitespacesAndNewlines)
        let carriesImage = !field.isEmpty && attachment != nil
        if carriesImage, let attachment {
            body[field] = attachment.jpeg.base64EncodedString()
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // A few megabytes of base64 on cellular does not fit in 30 s, and a timeout here surfaces
        // as "couldn't start the agent" — sending the user to look in entirely the wrong place.
        request.timeoutInterval = carriesImage ? 90 : 30
        return request
    }

    /// The status URL for `runID` from the template, or `nil` if no template is set.
    func statusURL(runID: String) -> URL? {
        guard let filled = fillTemplate(statusURLTemplate, runID: runID) else { return nil }
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
        guard let filled = fillTemplate(cancelURLTemplate, runID: runID),
              let url = URL(string: filled) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(&request)
        request.timeoutInterval = 15
        return request
    }

    /// Build the reply (POST) request for `runID`, or `nil` when this endpoint cannot be answered
    /// — no input template, or a mapping collision. `nil` is reported to the wearer as an honest
    /// "this agent can't take that answer", never as a silent success (Plan FE P1).
    func inputRequest(runID: String, reply: AgentReply) -> URLRequest? {
        guard fieldCollisionIssue == nil,
              let filled = fillTemplate(inputURLTemplate, runID: runID),
              let url = URL(string: filled) else { return nil }
        let answerKey = inputField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answerKey.isEmpty else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        var body: [String: Any] = [
            "decision": reply.body.decision,
            "questionId": reply.questionID,
            "questionRevision": reply.revision,
            // Stable across retries, so an endpoint can make a re-delivery a no-op rather than
            // applying the same answer twice.
            "replyId": reply.replyID,
        ]
        // The wearer's words go across in full — the point of the typed reply is that
        // "only change the tests" survives the trip.
        if let text = reply.body.text { body[answerKey] = text }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        return request
    }

    /// Build the acknowledgement (POST) request for `runID`, or `nil` when this endpoint did not
    /// ask to be told (Plan FE P4). `nil` is not a failure: it is recorded against the delivery as
    /// `notConfigured` and nothing is spoken, because an endpoint that never wanted an
    /// acknowledgement is not a problem the wearer needs to hear about.
    ///
    /// The body carries no wearer content and no endpoint content — the run, the revision, the
    /// playback state and the stable ack id, and that is the whole of it.
    func ackRequest(runID: String, ack: AgentDeliveryAck) -> URLRequest? {
        guard let filled = fillTemplate(ackURLTemplate, runID: runID),
              let url = URL(string: filled) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ack.body)
        request.timeoutInterval = 15
        return request
    }

    /// `{id}` filled with the **percent-encoded** run id (BM P5). The id comes from the server's
    /// own response, so path/query metacharacters ("../", "?", "#") must not be able to rewrite
    /// the request URL. `nil` when the template is empty.
    private func fillTemplate(_ template: String, runID: String) -> String? {
        guard !template.isEmpty,
              let encoded = runID.addingPercentEncoding(withAllowedCharacters: Self.runIDAllowed) else { return nil }
        return template.replacingOccurrences(of: "{id}", with: encoded)
    }

    private static let runIDAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

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

    /// The string array at `path` — `nil` when the path is unset/missing (**not reported**), an
    /// empty array when the endpoint genuinely reported none. Non-string elements are coerced when
    /// they are numbers and dropped otherwise, so one odd element cannot poison the list.
    static func strings(at path: String, in json: [String: Any]) -> [String]? {
        guard !path.isEmpty, let raw = value(at: path, in: json) else { return nil }
        if let array = raw as? [Any] {
            return array.compactMap { element in
                switch element {
                case let s as String: return s
                case let n as Int:    return String(n)
                case let d as Double: return String(d)
                default:              return nil
                }
            }
        }
        // A single string where a list was expected is a list of one — endpoints do this.
        if let single = raw as? String { return [single] }
        return nil
    }

    /// The boolean at `path` — `nil` when unset/missing. Accepts a bool, 0/1, or "true"/"false"/
    /// "yes"/"no", because endpoints spell flags every way there is.
    static func bool(at path: String, in json: [String: Any]) -> Bool? {
        guard !path.isEmpty, let raw = value(at: path, in: json) else { return nil }
        switch raw {
        case let b as Bool:   return b
        case let n as Int:    return n != 0
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1":  return true
            case "false", "no", "0":  return false
            default:                  return nil
            }
        default: return nil
        }
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
