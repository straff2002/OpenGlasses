import Foundation

// MARK: - Step Type

enum StepType: String, Codable, CaseIterable {
    case prompt
    case photo
    case quickAction
    case http
    case condition
    case wait

    var displayName: String {
        switch self {
        case .prompt:      return "Ask AI"
        case .photo:       return "Take Photo"
        case .quickAction: return "Quick Action"
        case .http:        return "HTTP Request"
        case .condition:   return "Condition"
        case .wait:        return "Wait"
        }
    }

    var icon: String {
        switch self {
        case .prompt:      return "bubble.left.and.text.bubble.right"
        case .photo:       return "camera"
        case .quickAction: return "bolt"
        case .http:        return "network"
        case .condition:   return "arrow.triangle.branch"
        case .wait:        return "clock"
        }
    }
}

// MARK: - Condition Operator

enum ConditionOperator: String, Codable, CaseIterable {
    case contains
    case notContains
    case equals
    case notEquals
    case startsWith
    case isEmpty
    case isNotEmpty

    var displayName: String {
        switch self {
        case .contains:    return "contains"
        case .notContains: return "doesn't contain"
        case .equals:      return "equals"
        case .notEquals:   return "doesn't equal"
        case .startsWith:  return "starts with"
        case .isEmpty:     return "is empty"
        case .isNotEmpty:  return "is not empty"
        }
    }

    var needsValue: Bool {
        switch self {
        case .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }

    func evaluate(_ lhs: String, against rhs: String) -> Bool {
        switch self {
        case .contains:    return lhs.localizedCaseInsensitiveContains(rhs)
        case .notContains: return !lhs.localizedCaseInsensitiveContains(rhs)
        case .equals:      return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
        case .notEquals:   return lhs.localizedCaseInsensitiveCompare(rhs) != .orderedSame
        case .startsWith:  return lhs.lowercased().hasPrefix(rhs.lowercased())
        case .isEmpty:     return lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .isNotEmpty:  return !lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Data Model

struct Playbook: Codable, Identifiable {
    var id: String
    var name: String
    var icon: String
    var steps: [PlaybookStep]
    /// Reference material (manual text, procedures, specs) used as RAG context.
    var referenceText: String
    var createdAt: Date

    init(id: String? = nil, name: String, icon: String = "list.clipboard", steps: [PlaybookStep] = [], referenceText: String = "") {
        self.id = id ?? name.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        self.name = name
        self.icon = icon
        self.steps = steps
        self.referenceText = referenceText
        self.createdAt = Date()
    }
}

enum StepStatus: String, Codable {
    case pending
    case completed
    case failed
    case skipped
}

struct PlaybookStep: Codable, Identifiable {
    var id: String
    var title: String
    /// For .prompt/.photo steps: the prompt text sent to AI.
    /// For other types: human-readable description.
    var detail: String
    var isCompleted: Bool
    var notes: String
    var status: StepStatus
    var stepResult: String?

    // MARK: - Workflow fields
    var type: StepType
    /// Variable name (no braces) to store this step's result in. Empty = don't save.
    var outputVar: String

    // Quick action
    var quickActionId: String

    // HTTP
    var httpMethod: String
    var httpURL: String
    var httpBody: String

    // Condition
    /// Variable name (no braces) to evaluate, e.g. "summary"
    var conditionVariable: String
    var conditionOperator: ConditionOperator
    var conditionValue: String
    /// 0-based step index to jump to if true. -1 = advance normally.
    var conditionThenStep: Int
    /// 0-based step index to jump to if false. -1 = advance normally.
    var conditionElseStep: Int

    // Wait
    var waitSeconds: Int

    init(
        id: String? = nil,
        title: String,
        detail: String = "",
        isCompleted: Bool = false,
        notes: String = "",
        status: StepStatus = .pending,
        stepResult: String? = nil,
        type: StepType = .prompt,
        outputVar: String = "",
        quickActionId: String = "",
        httpMethod: String = "GET",
        httpURL: String = "",
        httpBody: String = "",
        conditionVariable: String = "",
        conditionOperator: ConditionOperator = .contains,
        conditionValue: String = "",
        conditionThenStep: Int = -1,
        conditionElseStep: Int = -1,
        waitSeconds: Int = 5
    ) {
        self.id = id ?? String(UUID().uuidString.prefix(8)).lowercased()
        self.title = title
        self.detail = detail
        self.isCompleted = isCompleted
        self.notes = notes
        self.status = status
        self.stepResult = stepResult
        self.type = type
        self.outputVar = outputVar
        self.quickActionId = quickActionId
        self.httpMethod = httpMethod
        self.httpURL = httpURL
        self.httpBody = httpBody
        self.conditionVariable = conditionVariable
        self.conditionOperator = conditionOperator
        self.conditionValue = conditionValue
        self.conditionThenStep = conditionThenStep
        self.conditionElseStep = conditionElseStep
        self.waitSeconds = waitSeconds
    }

    // MARK: - Backward-compatible decoder

    enum CodingKeys: String, CodingKey {
        case id, title, detail, isCompleted, notes, status, stepResult
        case type, outputVar
        case quickActionId
        case httpMethod, httpURL, httpBody
        case conditionVariable, conditionOperator, conditionValue, conditionThenStep, conditionElseStep
        case waitSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        title         = try c.decodeIfPresent(String.self,     forKey: .title)             ?? ""
        detail        = try c.decodeIfPresent(String.self,     forKey: .detail)            ?? ""
        isCompleted   = try c.decodeIfPresent(Bool.self,       forKey: .isCompleted)       ?? false
        notes         = try c.decodeIfPresent(String.self,     forKey: .notes)             ?? ""
        status        = try c.decodeIfPresent(StepStatus.self, forKey: .status)            ?? .pending
        stepResult    = try c.decodeIfPresent(String.self,     forKey: .stepResult)
        type              = try c.decodeIfPresent(StepType.self,          forKey: .type)              ?? .prompt
        outputVar         = try c.decodeIfPresent(String.self,            forKey: .outputVar)         ?? ""
        quickActionId     = try c.decodeIfPresent(String.self,            forKey: .quickActionId)     ?? ""
        httpMethod        = try c.decodeIfPresent(String.self,            forKey: .httpMethod)        ?? "GET"
        httpURL           = try c.decodeIfPresent(String.self,            forKey: .httpURL)           ?? ""
        httpBody          = try c.decodeIfPresent(String.self,            forKey: .httpBody)          ?? ""
        conditionVariable = try c.decodeIfPresent(String.self,            forKey: .conditionVariable) ?? ""
        conditionOperator = try c.decodeIfPresent(ConditionOperator.self, forKey: .conditionOperator) ?? .contains
        conditionValue    = try c.decodeIfPresent(String.self,            forKey: .conditionValue)    ?? ""
        conditionThenStep = try c.decodeIfPresent(Int.self,               forKey: .conditionThenStep) ?? -1
        conditionElseStep = try c.decodeIfPresent(Int.self,               forKey: .conditionElseStep) ?? -1
        waitSeconds       = try c.decodeIfPresent(Int.self,               forKey: .waitSeconds)       ?? 5
    }
}

// MARK: - Active Session

struct PlaybookSession: Codable {
    var playbookId: String
    var currentStepIndex: Int
    var startedAt: Date
    /// Variables captured from step outputs during this session.
    var variables: [String: String]

    init(playbookId: String, currentStepIndex: Int, startedAt: Date, variables: [String: String] = [:]) {
        self.playbookId = playbookId
        self.currentStepIndex = currentStepIndex
        self.startedAt = startedAt
        self.variables = variables
    }

    enum CodingKeys: String, CodingKey {
        case playbookId, currentStepIndex, startedAt, variables
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playbookId       = try c.decode(String.self, forKey: .playbookId)
        currentStepIndex = try c.decode(Int.self,    forKey: .currentStepIndex)
        startedAt        = try c.decode(Date.self,   forKey: .startedAt)
        variables        = try c.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
    }
}

// MARK: - Store

@MainActor
class PlaybookStore: ObservableObject {
    @Published var playbooks: [Playbook] = []
    @Published var activeSession: PlaybookSession?

    private let storageKey = "playbooks"
    private let sessionKey = "playbookSession"

    init() {
        load()
        loadSession()
        if playbooks.isEmpty {
            playbooks = Self.defaults
            save()
        }
    }

    // MARK: - Variable Interpolation

    /// Replaces {{varName}} tokens in text with values from the variables dictionary.
    static func interpolate(_ text: String, variables: [String: String]) -> String {
        var result = text
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    // MARK: - CRUD

    func add(_ playbook: Playbook) {
        playbooks.append(playbook)
        save()
    }

    func update(_ playbook: Playbook) {
        if let idx = playbooks.firstIndex(where: { $0.id == playbook.id }) {
            playbooks[idx] = playbook
            save()
        }
    }

    func delete(id: String) {
        playbooks.removeAll { $0.id == id }
        if activeSession?.playbookId == id {
            activeSession = nil
            saveSession()
        }
        save()
    }

    func playbook(byId id: String) -> Playbook? {
        playbooks.first { $0.id == id }
    }

    func playbook(byName name: String) -> Playbook? {
        playbooks.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    // MARK: - Session Management

    func startPlaybook(_ id: String) -> String {
        guard let pb = playbook(byId: id) else { return "Playbook '\(id)' not found." }
        guard !pb.steps.isEmpty else { return "Playbook '\(pb.name)' has no steps." }

        if let idx = playbooks.firstIndex(where: { $0.id == id }) {
            for i in playbooks[idx].steps.indices {
                playbooks[idx].steps[i].isCompleted = false
                playbooks[idx].steps[i].notes = ""
                playbooks[idx].steps[i].status = .pending
                playbooks[idx].steps[i].stepResult = nil
            }
            save()
        }

        activeSession = PlaybookSession(playbookId: id, currentStepIndex: 0, startedAt: Date())
        saveSession()
        let step = pb.steps[0]
        return "Started '\(pb.name)'. \(describeStep(step, index: 0, total: pb.steps.count, variables: [:]))"
    }

    func nextStep() -> String {
        guard var session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }

        markCurrentStepComplete()

        var nextIdx = session.currentStepIndex + 1

        // Auto-evaluate and skip through any condition steps
        while nextIdx < pb.steps.count {
            let step = pb.steps[nextIdx]
            guard step.type == .condition else { break }

            let varValue = session.variables[step.conditionVariable] ?? ""
            let passed = step.conditionOperator.evaluate(varValue, against: step.conditionValue)
            let branch = passed ? "then" : "else"
            let jumpTo = passed ? step.conditionThenStep : step.conditionElseStep

            if let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) {
                playbooks[pbIdx].steps[nextIdx].status = .completed
                playbooks[pbIdx].steps[nextIdx].isCompleted = true
                playbooks[pbIdx].steps[nextIdx].stepResult = "→ \(branch) branch"
            }
            save()

            nextIdx = jumpTo == -1 ? nextIdx + 1 : jumpTo
        }

        if nextIdx >= pb.steps.count {
            return finishPlaybook()
        }

        session.currentStepIndex = nextIdx
        activeSession = session
        saveSession()

        let step = pb.steps[nextIdx]
        return describeStep(step, index: nextIdx, total: pb.steps.count, variables: session.variables)
    }

    func previousStep() -> String {
        guard var session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }

        let prevIdx = session.currentStepIndex - 1
        guard prevIdx >= 0 else { return "Already at the first step." }

        session.currentStepIndex = prevIdx
        activeSession = session
        saveSession()

        let step = pb.steps[prevIdx]
        return "Back to \(describeStep(step, index: prevIdx, total: pb.steps.count, variables: session.variables))"
    }

    func currentStatus() -> String {
        guard let session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }
        let idx = session.currentStepIndex
        let step = pb.steps[idx]
        let completed = pb.steps.filter(\.isCompleted).count
        let elapsed = Int(Date().timeIntervalSince(session.startedAt) / 60)
        return "'\(pb.name)' — step \(idx + 1) of \(pb.steps.count): \(step.title). \(completed) completed, \(elapsed) min elapsed."
    }

    func addNoteToCurrentStep(_ note: String) -> String {
        guard let session = activeSession else { return "No active playbook." }
        guard let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) else { return "Playbook not found." }
        let stepIdx = session.currentStepIndex
        guard stepIdx < playbooks[pbIdx].steps.count else { return "Invalid step." }

        let existing = playbooks[pbIdx].steps[stepIdx].notes
        playbooks[pbIdx].steps[stepIdx].notes = existing.isEmpty ? note : existing + "; " + note
        save()
        return "Note added to step \(stepIdx + 1)."
    }

    // MARK: - Variables

    /// Manually store a variable value (called by LLM after processing step output).
    func storeVariable(name: String, value: String) -> String {
        guard activeSession != nil else { return "No active playbook." }
        activeSession?.variables[name] = value
        saveSession()
        return "Stored {{\(name)}} = \(value.prefix(100))"
    }

    // MARK: - Adaptive Replanning

    func addResultToCurrentStep(_ result: String, success: Bool) -> String {
        guard let session = activeSession else { return "No active playbook." }
        guard let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) else { return "Playbook not found." }
        let stepIdx = session.currentStepIndex
        guard stepIdx < playbooks[pbIdx].steps.count else { return "Invalid step." }

        playbooks[pbIdx].steps[stepIdx].stepResult = result
        playbooks[pbIdx].steps[stepIdx].status = success ? .completed : .failed
        if success { playbooks[pbIdx].steps[stepIdx].isCompleted = true }

        // Store output variable if configured
        let step = playbooks[pbIdx].steps[stepIdx]
        if !step.outputVar.isEmpty {
            activeSession?.variables[step.outputVar] = result
            saveSession()
        }

        save()
        return "Step \(stepIdx + 1) \(success ? "succeeded" : "failed"): \(result)"
    }

    func replaceRemainingSteps(_ newSteps: [PlaybookStep]) -> String {
        guard let session = activeSession else { return "No active playbook." }
        guard let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) else { return "Playbook not found." }

        let keepCount = session.currentStepIndex + 1
        let kept = Array(playbooks[pbIdx].steps.prefix(keepCount))
        playbooks[pbIdx].steps = kept + newSteps
        save()
        return "Replanned: kept \(keepCount) steps, added \(newSteps.count) new steps. Total: \(playbooks[pbIdx].steps.count) steps."
    }

    func insertSteps(_ steps: [PlaybookStep], after index: Int) -> String {
        guard let session = activeSession else { return "No active playbook." }
        guard let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) else { return "Playbook not found." }
        let insertAt = min(index + 1, playbooks[pbIdx].steps.count)
        playbooks[pbIdx].steps.insert(contentsOf: steps, at: insertAt)
        save()
        return "Inserted \(steps.count) step(s) after step \(index + 1). Total: \(playbooks[pbIdx].steps.count) steps."
    }

    func removeStep(at index: Int) -> String {
        guard let session = activeSession else { return "No active playbook." }
        guard let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) else { return "Playbook not found." }
        guard index >= 0, index < playbooks[pbIdx].steps.count else { return "Invalid step index." }
        if index <= session.currentStepIndex { return "Cannot remove a step that has already been reached." }
        let removed = playbooks[pbIdx].steps.remove(at: index)
        save()
        return "Removed step '\(removed.title)'. Total: \(playbooks[pbIdx].steps.count) steps."
    }

    func skipCurrentStep(reason: String) -> String {
        guard var session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }
        guard let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) else { return "Playbook not found." }

        playbooks[pbIdx].steps[session.currentStepIndex].status = .skipped
        playbooks[pbIdx].steps[session.currentStepIndex].stepResult = reason

        let nextIdx = session.currentStepIndex + 1
        if nextIdx >= pb.steps.count {
            save()
            return finishPlaybook()
        }

        session.currentStepIndex = nextIdx
        activeSession = session
        saveSession()
        save()

        let step = playbooks[pbIdx].steps[nextIdx]
        return "Skipped (reason: \(reason)). Now on \(describeStep(step, index: nextIdx, total: playbooks[pbIdx].steps.count, variables: session.variables))"
    }

    func finishPlaybook() -> String {
        guard let session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }

        markCurrentStepComplete()

        let completed = pb.steps.filter(\.isCompleted).count
        let elapsed = Int(Date().timeIntervalSince(session.startedAt) / 60)
        var summary = "Finished '\(pb.name)'. \(completed)/\(pb.steps.count) steps completed in \(elapsed) min."

        let stepsWithNotes = pb.steps.filter { !$0.notes.isEmpty }
        if !stepsWithNotes.isEmpty {
            summary += " Notes: " + stepsWithNotes.map { "\($0.title): \($0.notes)" }.joined(separator: ". ")
        }

        activeSession = nil
        saveSession()
        return summary
    }

    // MARK: - HTTP Execution

    /// Executes the current step as an HTTP request, stores the result, and returns the response text.
    func executeHTTPStep() async -> String {
        guard let session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }
        let stepIdx = session.currentStepIndex
        guard stepIdx < pb.steps.count else { return "Invalid step." }
        let step = pb.steps[stepIdx]
        guard step.type == .http else { return "Current step is not an HTTP step." }

        let urlString = Self.interpolate(step.httpURL, variables: session.variables)
        guard let url = URL(string: urlString) else {
            _ = addResultToCurrentStep("Invalid URL: \(urlString)", success: false)
            return "Invalid URL: \(urlString)"
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = step.httpMethod
        if !step.httpBody.isEmpty, step.httpMethod != "GET", step.httpMethod != "DELETE" {
            request.httpBody = Self.interpolate(step.httpBody, variables: session.variables).data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            let success = (200..<300).contains(statusCode)
            let resultText = "HTTP \(statusCode): \(body.prefix(500))"
            _ = addResultToCurrentStep(resultText, success: success)
            return resultText
        } catch {
            let resultText = "HTTP error: \(error.localizedDescription)"
            _ = addResultToCurrentStep(resultText, success: false)
            return resultText
        }
    }

    // MARK: - System Prompt Context

    func playbookContext() -> String? {
        guard let session = activeSession, let pb = playbook(byId: session.playbookId) else { return nil }
        let idx = session.currentStepIndex
        guard idx < pb.steps.count else { return nil }

        let step = pb.steps[idx]
        let remaining = pb.steps.count - idx - 1
        let vars = session.variables

        var context = "ACTIVE PLAYBOOK: \(pb.name)\n"
        context += "Step \(idx + 1) of \(pb.steps.count): \(step.title) [\(step.type.displayName)]"

        if !step.detail.isEmpty {
            context += "\nDetail: \(Self.interpolate(step.detail, variables: vars))"
        }

        // Step type-specific context
        switch step.type {
        case .http:
            let url = Self.interpolate(step.httpURL, variables: vars)
            context += "\nHTTP \(step.httpMethod) \(url)"
            if !step.httpBody.isEmpty {
                context += "\nBody: \(Self.interpolate(step.httpBody, variables: vars))"
            }
        case .quickAction:
            context += "\nQuick Action ID: \(step.quickActionId)"
        case .condition:
            let lhs = vars[step.conditionVariable] ?? "(no value)"
            context += "\nCondition: {{\(step.conditionVariable)}} (\"\(lhs)\") \(step.conditionOperator.displayName)"
            if step.conditionOperator.needsValue { context += " \"\(step.conditionValue)\"" }
        case .wait:
            context += "\nWait: \(step.waitSeconds) seconds"
        case .prompt, .photo:
            break
        }

        // Available variables
        if !vars.isEmpty {
            context += "\n\nVariables:\n"
            context += vars.map { "  {{\($0.key)}} = \"\($0.value.prefix(200))\"" }.joined(separator: "\n")
        }

        // Step progress
        let stepSummaries = pb.steps.enumerated().map { offset, s in
            let icon: String
            switch s.status {
            case .completed: icon = "✓"
            case .failed:    icon = "✗"
            case .skipped:   icon = "⊘"
            case .pending:   icon = offset == idx ? "→" : "○"
            }
            var line = "  \(icon) Step \(offset + 1): \(s.title) [\(s.type.displayName)]"
            if let result = s.stepResult, !result.isEmpty { line += " — \(result)" }
            return line
        }.joined(separator: "\n")

        context += "\n\nProgress:\n\(stepSummaries)"
        if remaining > 0 { context += "\nRemaining: \(remaining) steps" }

        if !pb.referenceText.isEmpty {
            context += "\n\nREFERENCE MATERIAL:\n\(pb.referenceText)"
        }

        context += """

        \nPLAYBOOK INSTRUCTIONS:
        - Guide the user through the current step.
        - When they confirm completion, call the playbook tool with action "next".
        - For HTTP steps: call the playbook tool with action "execute_http" to run the request automatically.
        - For Quick Action steps: call the quick_action tool with the configured action ID, then call "next".
        - For Wait steps: wait the specified seconds, then call "next".
        - Condition steps are evaluated automatically when you call "next" — no action needed.
        - Use {{variable}} tokens in prompts to reference captured values from previous steps.
        - Call "store_variable" with name and value to save AI-generated content for later steps.
        - Add notes to steps if the user mentions anything noteworthy.
        - Use "add_result" to record step outcomes, especially failures.
        - Use "replan" to adjust remaining steps if something unexpected happens.
        """

        return context
    }

    // MARK: - Helpers

    private func describeStep(_ step: PlaybookStep, index: Int, total: Int, variables: [String: String]) -> String {
        let prefix = "Step \(index + 1) of \(total): \(step.title)."
        switch step.type {
        case .prompt:
            let text = Self.interpolate(step.detail, variables: variables)
            return text.isEmpty ? prefix : "\(prefix) \(text)"
        case .photo:
            let text = Self.interpolate(step.detail, variables: variables)
            return "\(prefix) Take a photo\(text.isEmpty ? "" : ", then: \(text)")"
        case .quickAction:
            return "\(prefix) Run quick action: \(step.quickActionId)"
        case .http:
            return "\(prefix) HTTP \(step.httpMethod) \(Self.interpolate(step.httpURL, variables: variables))"
        case .condition:
            return "\(prefix) Evaluating condition on {{\(step.conditionVariable)}}..."
        case .wait:
            return "\(prefix) Wait \(step.waitSeconds) second\(step.waitSeconds == 1 ? "" : "s")."
        }
    }

    private func markCurrentStepComplete() {
        guard let session = activeSession else { return }
        if let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) {
            let stepIdx = session.currentStepIndex
            if stepIdx < playbooks[pbIdx].steps.count {
                playbooks[pbIdx].steps[stepIdx].isCompleted = true
                if playbooks[pbIdx].steps[stepIdx].status == .pending {
                    playbooks[pbIdx].steps[stepIdx].status = .completed
                }
                save()
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(playbooks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Playbook].self, from: data) {
            playbooks = decoded
        }
    }

    private func saveSession() {
        if let session = activeSession, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
    }

    private func loadSession() {
        if let data = UserDefaults.standard.data(forKey: sessionKey),
           let decoded = try? JSONDecoder().decode(PlaybookSession.self, from: data) {
            activeSession = decoded
        }
    }

    // MARK: - Defaults

    static let defaults: [Playbook] = [
        Playbook(
            name: "Site Visit",
            icon: "building.2",
            steps: [
                PlaybookStep(title: "Start Recording", detail: "Begin ambient transcription to capture the full site discussion. Say 'start transcription' or use the ambient captions tool."),
                PlaybookStep(title: "Walkthrough", detail: "Walk the site with the client. Discuss scope of work, concerns, measurements, and timelines. The transcription is running — just talk naturally."),
                PlaybookStep(title: "Photo Documentation", detail: "Take photos of key areas discussed — problem spots, measurements, finishes, materials.", type: .photo),
                PlaybookStep(title: "Confirm Details", detail: "Review what was discussed. Confirm scope, timeline, budget expectations, and next steps with the client."),
                PlaybookStep(title: "Generate Emails", detail: "Stop transcription. Say 'summarize the site visit and draft two emails: one for the homeowner confirming what we discussed, and one for my team with the action items and technical details. Use the email addresses from the reference material.'"),
                PlaybookStep(title: "Review & Send", detail: "Review the drafted emails, make any edits, then say 'send the homeowner email' and 'send the team email' to open them in Mail.")
            ],
            referenceText: """
            SITE VISIT CONFIG — Edit these to match your project:

            Homeowner email: client@example.com
            Homeowner name: [Client Name]

            Team email: team@yourcompany.com
            Team lead: [Your Name]
            Company: [Your Company]

            HOMEOWNER EMAIL TONE: Professional, reassuring, plain language. Summarize what was discussed, confirm next steps and timeline. No jargon.

            TEAM EMAIL TONE: Technical, action-oriented. Include measurements, materials needed, issues found, photos referenced, and task assignments.
            """
        ),
        Playbook(
            name: "Meeting Agenda",
            icon: "person.3",
            steps: [
                PlaybookStep(title: "Introductions", detail: "Welcome everyone, state meeting purpose"),
                PlaybookStep(title: "Review previous action items", detail: "Check status of items from last meeting"),
                PlaybookStep(title: "Main topics", detail: "Discuss agenda items"),
                PlaybookStep(title: "Action items", detail: "Assign tasks with owners and deadlines"),
                PlaybookStep(title: "Wrap up", detail: "Summarize decisions and next steps")
            ]
        ),
        Playbook(
            name: "Vehicle Inspection",
            icon: "car",
            steps: [
                PlaybookStep(title: "Tires", detail: "Check pressure and tread depth on all four tires"),
                PlaybookStep(title: "Fluids", detail: "Check oil, coolant, brake fluid, washer fluid levels"),
                PlaybookStep(title: "Lights", detail: "Test headlights, tail lights, turn signals, brake lights"),
                PlaybookStep(title: "Mirrors", detail: "Adjust side mirrors and rear-view mirror"),
                PlaybookStep(title: "Seatbelt", detail: "Verify seatbelt clicks and retracts properly"),
                PlaybookStep(title: "Dashboard", detail: "Check for warning lights, verify fuel level")
            ]
        ),
        Playbook(
            name: "Recipe Template",
            icon: "fork.knife",
            steps: [
                PlaybookStep(title: "Gather ingredients", detail: "Check all ingredients are available and measured"),
                PlaybookStep(title: "Prep", detail: "Wash, chop, and prepare all ingredients"),
                PlaybookStep(title: "Cook", detail: "Follow cooking instructions"),
                PlaybookStep(title: "Plate", detail: "Arrange on plates and garnish"),
                PlaybookStep(title: "Clean up", detail: "Wash dishes and clean workspace")
            ]
        ),
        Playbook(
            name: "Patient Encounter",
            icon: "stethoscope",
            steps: [
                PlaybookStep(title: "Chief Complaint", detail: "Greet the patient and establish the chief complaint. Say 'start transcription' to begin ambient documentation. Ask: What brings you in today? Duration, onset, severity."),
                PlaybookStep(title: "History of Present Illness", detail: "Explore the HPI using OLDCARTS: Onset, Location, Duration, Character, Aggravating/Alleviating factors, Radiation, Timing, Severity. Note relevant negatives."),
                PlaybookStep(title: "Review of Systems", detail: "Conduct targeted ROS based on the chief complaint. Cover constitutional, relevant organ systems, and pertinent positives/negatives."),
                PlaybookStep(title: "Physical Exam", detail: "Perform and narrate exam findings. Document skin lesions, wounds, or rashes with photos. Describe morphology, distribution, and measurements aloud.", type: .photo),
                PlaybookStep(title: "Assessment & Differential", detail: "State your working diagnosis and differential. Say 'what are the differentials for [finding]?' if you want AI-assisted differential generation."),
                PlaybookStep(title: "Plan", detail: "Dictate the plan: diagnostics ordered (labs, imaging, biopsy), prescriptions, referrals, follow-up timeline, and patient education points."),
                PlaybookStep(title: "Generate Note", detail: "Say 'summarize this encounter as a SOAP note' to generate a structured clinical note from the transcription. Review for accuracy before finalizing.")
            ],
            referenceText: """
            CLINICAL ENCOUNTER CONFIG — Edit to match your practice:

            Provider: [Your Name], [Credentials]
            Specialty: [Your Specialty]
            Clinic: [Practice Name]
            EMR: [System Name] (for note formatting preferences)

            NOTE FORMAT: SOAP (Subjective, Objective, Assessment, Plan)
            TERMINOLOGY: Use standard medical terminology. ICD-10 codes where applicable.
            MEDICATIONS: Include dose, route, frequency, duration, and quantity with refills.
            FOLLOW-UP: Always specify timeframe and conditions for earlier return.
            """
        ),
        Playbook(
            name: "Skin Check",
            icon: "eye",
            steps: [
                PlaybookStep(title: "Patient History", detail: "Ask about skin cancer history (personal and family), sun exposure habits, prior biopsies, changing lesions, and Fitzpatrick skin type."),
                PlaybookStep(title: "Scalp & Face", detail: "Examine scalp, forehead, ears, nose, lips, and periorbital areas. Note ABCDEs for pigmented lesions.", type: .photo, outputVar: "scalp_findings"),
                PlaybookStep(title: "Neck & Upper Extremities", detail: "Check neck, shoulders, arms, hands, and nails. Document actinic keratoses, nevi, and suspicious lesions.", type: .photo, outputVar: "upper_findings"),
                PlaybookStep(title: "Trunk", detail: "Examine chest, abdomen, and back. Pay attention to areas of chronic sun exposure.", type: .photo, outputVar: "trunk_findings"),
                PlaybookStep(title: "Lower Extremities", detail: "Check legs, feet, soles, and toenails. Note any stasis changes, melanonychia, or acral lesions.", type: .photo, outputVar: "lower_findings"),
                PlaybookStep(title: "Document & Plan", detail: "Summarize findings. Say 'generate a skin check note listing all documented lesions with locations and descriptions.' Schedule biopsies or follow-ups.")
            ],
            referenceText: """
            LESION DOCUMENTATION TEMPLATE:
            Location: [Anatomical site]
            Size: [cm × cm]
            Type: [macule/papule/plaque/nodule/patch/vesicle]
            Color: [flesh/pink/red/brown/black/multicolored]
            Border: [well-defined/irregular/notched]
            Surface: [smooth/rough/scaly/crusted/ulcerated]
            Assessment: [benign/atypical/suspicious — recommend monitoring/biopsy/excision]

            ABCDE CRITERIA:
            A — Asymmetry
            B — Border irregularity
            C — Color variation (>2 colors)
            D — Diameter >6mm
            E — Evolution (changing)
            """
        )
    ]
}
