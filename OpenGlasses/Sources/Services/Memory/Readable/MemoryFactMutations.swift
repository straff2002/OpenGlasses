import Foundation

/// The stores a fact can live in. Optional so a caller wires what it has; a fact whose store is
/// absent cannot be changed and says so rather than reporting success.
@MainActor
struct MemoryFactStores {
    var semantic: SemanticMemoryStore?
    var brain: BrainStore?
    var agentDocuments: AgentDocumentStore?
    var objects: ObjectMemoryStore?
    var savedPlaces: SavedLocationStore?
    var conversations: ConversationStore?

    init(semantic: SemanticMemoryStore? = nil, brain: BrainStore? = nil,
         agentDocuments: AgentDocumentStore? = nil, objects: ObjectMemoryStore? = nil,
         savedPlaces: SavedLocationStore? = nil, conversations: ConversationStore? = nil) {
        self.semantic = semantic
        self.brain = brain
        self.agentDocuments = agentDocuments
        self.objects = objects
        self.savedPlaces = savedPlaces
        self.conversations = conversations
    }

    /// Whether the authoritative row for `id` can still be read. The re-read every forget and
    /// correction is verified against (Plan DX rule 6).
    func exists(_ id: MemoryFactID) -> Bool {
        switch id.store {
        case .semantic: return semantic?.entry(id: id.recordID) != nil
        case .diary: return semantic?.diaryEntry(id: id.recordID) != nil
        case .brainEdge: return brain?.edge(id: id.recordID) != nil
        case .brainNeed: return brain?.need(id: id.recordID) != nil
        case .projectNote: return brain?.projectMemory(id: id.recordID) != nil
        case .agentNote:
            let text = agentDocuments?.content(for: .memory) ?? ""
            return text.components(separatedBy: "\n").contains { AgentNoteLine.recordID(for: $0) == id.recordID }
        case .object: return objects?.find(id.recordID) != nil
        case .savedPlace: return savedPlaces?.place(recordID: id.recordID) != nil
        }
    }

    /// The agent-notes line a fact id names, raw, if it is still there.
    func noteLine(_ id: MemoryFactID) -> String? {
        guard id.store == .agentNote else { return nil }
        return agentDocuments?.content(for: .memory).components(separatedBy: "\n")
            .first { AgentNoteLine.recordID(for: $0) == id.recordID }
    }
}

// MARK: - Forget

/// What forgetting one fact will touch, shown to the wearer before anything is removed.
struct MemoryForgetPlan: Equatable {
    let fact: MemoryFact
    /// Lines of the assistant's own notes that mention the fact. Text matching over prose the
    /// model wrote, so they are listed for the wearer to see first.
    let noteLines: [String]
    /// Whether a copy may have gone to a connected gateway, which this phone cannot delete.
    let gatewayCopyPossible: Bool
    /// The conversation the fact was said in, when it is known and still exists. Transcripts are
    /// not memory; the wearer is offered — never forced — the chance to delete it as well.
    let conversationThreadID: String?
}

/// What forgetting one fact did.
struct MemoryForgetResult: Equatable {
    let receipts: [ErasureReceipt]
    /// A re-read confirmed the authoritative row is gone. Nothing else counts as success.
    let verified: Bool
    /// A copy on a connected gateway is queued for deletion and not confirmed.
    let remotePending: Bool
    let removedNoteLines: Int
    let conversationThreadID: String?

    /// One or two plain sentences for the wearer, content-free apart from saying where a copy
    /// may remain.
    var summary: String {
        guard verified else {
            return String(localized: "I couldn't forget that — it's still saved. Try again from Memory on your phone.",
                          comment: "Said or shown when a fact could not be removed from memory.")
        }
        var text = String(localized: "Forgotten.", comment: "Said or shown after a fact was removed from memory.")
        if remotePending {
            text += " " + String(localized: "A copy sent to your connected gateway is queued for deletion and isn't confirmed yet.",
                                 comment: "Added after forgetting a fact that may also be stored on a connected gateway.")
        }
        if conversationThreadID != nil {
            text += " " + String(localized: "It's still in the conversation where you said it. Delete that conversation to remove it there.",
                                 comment: "Added after forgetting a fact that came from a conversation which still exists.")
        }
        return text
    }
}

/// Forget one fact everywhere this phone holds it (Plan GG P1), through the subject-erasure walk:
/// staged exports first, then the authoritative row (with its embedding, or a relation with its
/// own retired history), then matching lines of the assistant's notes the wearer saw, then a
/// queued deletion request for a gateway copy. Success is reported only after a re-read confirms
/// the row is gone.
@MainActor
final class MemoryFactForgetter {

    let stores: MemoryFactStores
    private let coordinator: SubjectErasureCoordinator
    /// Derived views to drop before the source goes — a live session's snapshot of memory, and
    /// any other projection that would otherwise outlive the fact.
    private let invalidations: [@MainActor () -> Void]

    init(stores: MemoryFactStores, coordinator: SubjectErasureCoordinator,
         invalidations: [@MainActor () -> Void] = []) {
        self.stores = stores
        self.coordinator = coordinator
        self.invalidations = invalidations
    }

    func plan(for fact: MemoryFact) -> MemoryForgetPlan {
        let lines = (stores.agentDocuments?.content(for: .memory) ?? "").components(separatedBy: "\n")
        let thread = fact.sourceRef.flatMap { ref in
            stores.conversations?.threads.contains { $0.id == ref } == true ? ref : nil
        }
        return MemoryForgetPlan(
            fact: fact,
            noteLines: MemoryNoteMatcher.lines(lines, mentioning: fact),
            gatewayCopyPossible: fact.id.store == .semantic,
            conversationThreadID: thread)
    }

    func forget(_ plan: MemoryForgetPlan, removeNoteLines: Bool) async -> MemoryForgetResult {
        let id = plan.fact.id
        guard fact(id, isSupportedBy: stores) else {
            return MemoryForgetResult(receipts: [], verified: false, remotePending: false,
                                      removedNoteLines: 0, conversationThreadID: nil)
        }
        invalidations.forEach { $0() }

        var gatewayKey: String?
        if id.store == .semantic, let entry = stores.semantic?.entry(id: id.recordID) {
            gatewayKey = entry.keyName
        }
        var lines = removeNoteLines ? plan.noteLines : []
        if let own = stores.noteLine(id) { lines.append(own) }

        var receipts = await coordinator.erase(.memoryFact(MemoryFactErasure(
            id: id, noteLines: lines, gatewayKey: gatewayKey)))

        // Saved places are not part of the subject walk (they are never about anyone else), so
        // the one place that can hold them is removed here and accounted for alongside.
        if id.store == .savedPlace {
            let removed = stores.savedPlaces?.delete(recordID: id.recordID) == true ? 1 : 0
            receipts.append(stores.savedPlaces == nil
                ? .unsupported(.savedLocations, "no saved-location store was supplied")
                : .complete(.savedLocations, removed: removed))
        }

        let verified = !stores.exists(id)
        let removedLines = receipts.first { $0.store == .agentDocuments }?.removed ?? 0
        PrivacyLog.store(.semanticMemory, verified ? .cleared : .writeFailed,
                         detail: PrivacyToken("factForget.\(id.store.rawValue)"))
        return MemoryForgetResult(
            receipts: receipts,
            verified: verified,
            remotePending: receipts.contains { $0.remotePending },
            removedNoteLines: id.store == .agentNote ? max(0, removedLines - 1) : removedLines,
            conversationThreadID: verified ? plan.conversationThreadID : nil)
    }

    /// Delete the conversation a forgotten fact came from — only ever on the wearer's own say-so,
    /// after the fact itself is gone (Plan GG decision 3). Goes through the same walk as any
    /// thread erasure, so its recall-index rows go first.
    @discardableResult
    func deleteConversation(_ threadID: String) async -> Bool {
        _ = await coordinator.erase(.conversationThread(id: threadID))
        return stores.conversations?.threads.contains { $0.id == threadID } == false
    }

    private func fact(_ id: MemoryFactID, isSupportedBy stores: MemoryFactStores) -> Bool {
        switch id.store {
        case .semantic, .diary: return stores.semantic != nil
        case .brainEdge, .brainNeed, .projectNote: return stores.brain != nil
        case .agentNote: return stores.agentDocuments != nil
        case .object: return stores.objects != nil
        case .savedPlace: return stores.savedPlaces != nil
        }
    }
}

// MARK: - Correct

/// What correcting one fact did.
struct MemoryCorrectionResult: Equatable {
    /// A re-read confirmed the wrong value is gone and the new one is there.
    let verified: Bool
    /// The corrected fact's identity, which differs from the old one when the store keys a fact
    /// by its value (a relation's destination, an object's name, a note line).
    let newID: MemoryFactID?
}

/// Replace a wrong fact with the right one, in the store that holds it (Plan GG P1). A correction
/// never leaves the wrong fact readable as history: a wrong relation is deleted, not superseded,
/// because it was never true.
@MainActor
final class MemoryFactCorrector {

    let stores: MemoryFactStores

    init(stores: MemoryFactStores) {
        self.stores = stores
    }

    func correct(_ fact: MemoryFact, to newValue: String) -> MemoryCorrectionResult {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, fact.capabilities.contains(.correct) else {
            return MemoryCorrectionResult(verified: false, newID: nil)
        }
        let id = fact.id
        switch id.store {
        case .semantic:
            guard let store = stores.semantic, store.correct(entryID: id.recordID, newValue: value),
                  store.entry(id: id.recordID)?.value == value else { return .failed }
            return MemoryCorrectionResult(verified: true, newID: id)

        case .diary:
            guard let store = stores.semantic, store.correctDiary(id: id.recordID, text: value),
                  store.diaryEntry(id: id.recordID)?.text == value else { return .failed }
            return MemoryCorrectionResult(verified: true, newID: id)

        case .brainEdge:
            guard let brain = stores.brain,
                  let newEdgeID = brain.correctEdge(id: id.recordID, newDestination: value),
                  brain.edge(id: id.recordID) == nil,
                  brain.edge(id: newEdgeID) != nil else { return .failed }
            return MemoryCorrectionResult(verified: true,
                                          newID: MemoryFactID(store: .brainEdge, recordID: newEdgeID))

        case .brainNeed:
            guard let brain = stores.brain, brain.updateNeed(id: id.recordID, text: value),
                  brain.need(id: id.recordID)?.text == value else { return .failed }
            return MemoryCorrectionResult(verified: true, newID: id)

        case .projectNote:
            guard let brain = stores.brain, brain.updateProjectMemory(id: id.recordID, text: value),
                  brain.projectMemory(id: id.recordID)?.text == value else { return .failed }
            return MemoryCorrectionResult(verified: true, newID: id)

        case .agentNote:
            guard let docs = stores.agentDocuments, let raw = stores.noteLine(id) else { return .failed }
            let rewritten = AgentNoteLine.rewrite(raw, text: value)
            guard docs.replaceMemoryLine(raw, with: rewritten), !stores.exists(id) else { return .failed }
            return MemoryCorrectionResult(verified: true, newID: MemoryFactID(
                store: .agentNote, recordID: AgentNoteLine.recordID(for: rewritten)))

        case .object:
            guard let objects = stores.objects, let entry = objects.find(id.recordID) else { return .failed }
            objects.save(ObjectMemoryEntry(id: entry.id, objectName: entry.objectName,
                                           locationDescription: value, latitude: entry.latitude,
                                           longitude: entry.longitude, savedAt: Date()))
            guard objects.find(id.recordID)?.locationDescription == value else { return .failed }
            return MemoryCorrectionResult(verified: true, newID: id)

        case .savedPlace:
            guard let places = stores.savedPlaces,
                  let newRecord = places.relabel(recordID: id.recordID, to: value),
                  places.place(recordID: newRecord)?.label == value else { return .failed }
            return MemoryCorrectionResult(verified: true,
                                          newID: MemoryFactID(store: .savedPlace, recordID: newRecord))
        }
    }
}

private extension MemoryCorrectionResult {
    static let failed = MemoryCorrectionResult(verified: false, newID: nil)
}
