import Foundation
#if canImport(OpenGlasses)
@testable import OpenGlasses
#endif

/// What the device qualification app (`Scripts/local-model-qualification`, Plan MQ P3) needs from
/// the app that it cannot build on a phone without the whole app: each offered tool's declared
/// description and parameters, from the real `NativeToolRegistry`, and the lean on-device system
/// prompt a downloaded model is given, from the real prompt builder, with the compact job tier of
/// the Lennox example vault fitted to each candidate model's budget.
///
/// `LocalModelQualificationFixtureTests` builds it from the app and fails when the committed file
/// differs (and writes the new one, to review and commit), so the phone runs the app's own words.
/// The app turns each tool into its template spec and schema root with the shipped
/// `OnDeviceToolSchema`, and appends the shipped `LLMService.localNativeToolGuide` per case, so
/// nothing here is a second copy of a rule. The date line is a placeholder filled at run time.
///
/// The prompts carry the example vault's text, which is committed and public. No user data.
struct LocalModelQualificationFixture {

    static let fileName = "qualification-fixture.json"
    static let version = 1
    static let dateTimePlaceholder = "{{DATE_TIME}}"

    /// A tool as the registry declares it.
    struct Tool {
        let description: String
        let parameters: [String: Any]
    }

    /// The system prompts one model is given.
    struct Prompts: Equatable {
        /// No job open: the everyday group.
        let everyday: String
        /// The job open, the unit and four readings: the Field Assist group.
        let job: String
        /// The same with a procedure running and thirty conversation turns, the tier filled to its
        /// budget: the long-prompt cases.
        let longJob: String
    }

    let version: Int
    /// The corpus these were built for (its header's `body-sha256`).
    let corpusBodySha256: String
    /// `Config.assistantName` when the prompts were built.
    let assistantName: String
    let tools: [String: Tool]
    /// By model id.
    let prompts: [String: Prompts]

    // MARK: - Use

    enum Variant: String { case everyday, job, longJob }

    static func variant(for testCase: LocalToolEval.Case) -> Variant {
        if testCase.group == .everyday { return .everyday }
        return testCase.category == .longPrompt ? .longJob : .job
    }

    /// The system prompt for one case: the model's prompt for the case's state, the date filled in,
    /// and the shipped native tool guide for the tools the case offers — what `sendLocal` builds.
    func systemPrompt(for testCase: LocalToolEval.Case, modelID: String, dateTimeLine: String) -> String? {
        guard let prompts = prompts[modelID] else { return nil }
        let base: String
        switch Self.variant(for: testCase) {
        case .everyday: base = prompts.everyday
        case .job: base = prompts.job
        case .longJob: base = prompts.longJob
        }
        return base.replacingOccurrences(of: Self.dateTimePlaceholder, with: dateTimeLine)
            + LLMService.localNativeToolGuide(toolNames: testCase.offered)
    }

    /// The template spec for `name` (`OnDeviceToolSchema.localToolSpec`), as `sendLocal` builds it.
    func toolSpec(_ name: String, limits: OnDeviceToolSchema.Limits = .standard) -> [String: Any]? {
        tools[name].map {
            OnDeviceToolSchema.localToolSpec(name: name, description: $0.description, parameters: $0.parameters,
                                             limits: limits)
        }
    }

    /// The schema root for `name`, as the loop's coercion and the graders read it.
    func schemaRoot(_ name: String) -> OnDeviceToolSchema.Node? {
        tools[name].map { OnDeviceToolSchema.root(toolName: name, parameters: $0.parameters) }
    }

    // MARK: - The file

    /// Sorted keys, two-space indent, one trailing newline: the same bytes every time.
    func encoded() throws -> Data {
        var tools: [String: Any] = [:]
        for (name, tool) in self.tools { tools[name] = ["description": tool.description, "parameters": tool.parameters] }
        var prompts: [String: Any] = [:]
        for (id, p) in self.prompts { prompts[id] = ["everyday": p.everyday, "job": p.job, "longJob": p.longJob] }
        let object: [String: Any] = ["version": version, "corpusBodySha256": corpusBodySha256,
                                     "assistantName": assistantName, "dateTimePlaceholder": Self.dateTimePlaceholder,
                                     "tools": tools, "prompts": prompts]
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    static func decode(_ data: Data) -> LocalModelQualificationFixture? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int,
              let corpus = object["corpusBodySha256"] as? String,
              let name = object["assistantName"] as? String,
              let rawTools = object["tools"] as? [String: [String: Any]],
              let rawPrompts = object["prompts"] as? [String: [String: String]] else { return nil }
        var tools: [String: Tool] = [:]
        for (toolName, raw) in rawTools {
            guard let description = raw["description"] as? String,
                  let parameters = raw["parameters"] as? [String: Any] else { return nil }
            tools[toolName] = Tool(description: description, parameters: parameters)
        }
        var prompts: [String: Prompts] = [:]
        for (id, raw) in rawPrompts {
            guard let everyday = raw["everyday"], let job = raw["job"], let long = raw["longJob"] else { return nil }
            prompts[id] = Prompts(everyday: everyday, job: job, longJob: long)
        }
        return LocalModelQualificationFixture(version: version, corpusBodySha256: corpus, assistantName: name,
                                              tools: tools, prompts: prompts)
    }

    /// `prompt` with its date line replaced by the placeholder.
    static func withDatePlaceholder(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: #"CURRENT DATE & TIME: [^\n]*"#,
                                    with: "CURRENT DATE & TIME: \(dateTimePlaceholder)", options: .regularExpression)
    }
}
