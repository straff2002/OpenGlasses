import Foundation

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

struct PlaybookStep: Codable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var isCompleted: Bool
    var notes: String

    init(id: String? = nil, title: String, detail: String = "", isCompleted: Bool = false, notes: String = "") {
        self.id = id ?? UUID().uuidString.prefix(8).lowercased().description
        self.title = title
        self.detail = detail
        self.isCompleted = isCompleted
        self.notes = notes
    }
}

// MARK: - Active Session

struct PlaybookSession: Codable {
    var playbookId: String
    var currentStepIndex: Int
    var startedAt: Date
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

        // Reset step completion
        if let idx = playbooks.firstIndex(where: { $0.id == id }) {
            for i in playbooks[idx].steps.indices {
                playbooks[idx].steps[i].isCompleted = false
                playbooks[idx].steps[i].notes = ""
            }
            save()
        }

        activeSession = PlaybookSession(playbookId: id, currentStepIndex: 0, startedAt: Date())
        saveSession()
        let step = pb.steps[0]
        return "Started '\(pb.name)'. Step 1 of \(pb.steps.count): \(step.title). \(step.detail)"
    }

    func nextStep() -> String {
        guard var session = activeSession, let pb = playbook(byId: session.playbookId) else {
            return "No active playbook."
        }

        // Mark current step complete
        markCurrentStepComplete()

        let nextIdx = session.currentStepIndex + 1
        if nextIdx >= pb.steps.count {
            return finishPlaybook()
        }

        session.currentStepIndex = nextIdx
        activeSession = session
        saveSession()

        let step = pb.steps[nextIdx]
        return "Step \(nextIdx + 1) of \(pb.steps.count): \(step.title). \(step.detail)"
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
        return "Back to step \(prevIdx + 1) of \(pb.steps.count): \(step.title). \(step.detail)"
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

    private func markCurrentStepComplete() {
        guard let session = activeSession else { return }
        if let pbIdx = playbooks.firstIndex(where: { $0.id == session.playbookId }) {
            let stepIdx = session.currentStepIndex
            if stepIdx < playbooks[pbIdx].steps.count {
                playbooks[pbIdx].steps[stepIdx].isCompleted = true
                save()
            }
        }
    }

    // MARK: - System Prompt Context

    /// Returns the active playbook context for injection into the system prompt.
    /// Nil if no playbook is active.
    func playbookContext() -> String? {
        guard let session = activeSession, let pb = playbook(byId: session.playbookId) else { return nil }
        let idx = session.currentStepIndex
        guard idx < pb.steps.count else { return nil }

        let step = pb.steps[idx]
        let completedSteps = pb.steps.enumerated()
            .filter { $0.element.isCompleted }
            .map { "Step \($0.offset + 1) ✓" }
            .joined(separator: ", ")
        let remaining = pb.steps.count - idx - 1

        var context = """
        ACTIVE PLAYBOOK: \(pb.name)
        Step \(idx + 1) of \(pb.steps.count): \(step.title)
        """

        if !step.detail.isEmpty {
            context += "\nDetail: \(step.detail)"
        }

        if !completedSteps.isEmpty {
            context += "\nCompleted: \(completedSteps)"
        }
        if remaining > 0 {
            context += "\nRemaining: \(remaining) steps"
        }

        if !pb.referenceText.isEmpty {
            context += "\n\nREFERENCE MATERIAL:\n\(pb.referenceText)"
        }

        context += """

        \nPLAYBOOK INSTRUCTIONS:
        - Guide the user through the current step conversationally.
        - When they confirm completion (\"done\", \"next\", \"check\"), call the playbook tool with action \"next\".
        - If they ask questions, reference the material above.
        - If they say \"skip\" or \"go back\", use the appropriate playbook action.
        - Add notes to steps if the user mentions anything noteworthy (measurements, observations, issues).
        """

        return context
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
        )
    ]
}
