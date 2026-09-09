import Foundation

/// Who or what is being erased, in the terms the app itself models.
enum ErasureSubject: Equatable {
    /// Somebody the wearer enrolled, met or recorded, by the name the app knows them under.
    case person(String)
    /// One conversation.
    case conversationThread(id: String)
    /// One ingested document.
    case document(id: String)

    /// The text an unstructured store has to be searched for. A person is only ever findable in
    /// free prose by their name, and saying so plainly is better than a delete that looks more
    /// precise than it is.
    var searchToken: String {
        switch self {
        case .person(let name): return name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .conversationThread(let id): return id
        case .document(let id): return id
        }
    }

    var kindLabel: String {
        switch self {
        case .person: return "person"
        case .conversationThread: return "thread"
        case .document: return "document"
        }
    }
}

/// What one store did about one subject.
///
/// There is deliberately no `held` field. A legal or medical hold is a real concept in the
/// roadmap, but this app has no hold mechanism today — no store can mark a record exempt from
/// erasure and no UI can set one — so a field that was always `false` would read as a control that
/// exists. When holds land, this is where they belong.
struct ErasureReceipt: Equatable {
    let store: SensitiveStore
    /// The local copy is gone, or was never there.
    let localComplete: Bool
    /// A copy exists somewhere this device cannot reach synchronously, and a tombstone has been
    /// queued for it. Never `true` on the strength of having queued nothing.
    let remotePending: Bool
    /// How many records went. Zero with `localComplete` is the ordinary case: the subject was not
    /// in that store.
    let removed: Int
    /// Set when this store cannot be erased for this subject, saying why. `localComplete` is then
    /// false, because it is not.
    let unsupported: String?

    static func complete(_ store: SensitiveStore, removed: Int = 0,
                         remotePending: Bool = false) -> ErasureReceipt {
        ErasureReceipt(store: store, localComplete: true, remotePending: remotePending,
                       removed: removed, unsupported: nil)
    }

    static func unsupported(_ store: SensitiveStore, _ reason: String) -> ErasureReceipt {
        ErasureReceipt(store: store, localComplete: false, remotePending: false,
                       removed: 0, unsupported: reason)
    }
}

/// W03.2 — erase one subject across every store that can carry them, in dependency order.
///
/// The finding this answers is that forgetting a person removed them from the store the wearer was
/// looking at and left them in the four derived from it. So the order here is not arbitrary:
/// **derived indexes go before their sources**. A recall index rebuilt from a thread that is still
/// there is a resurrection; a thread deleted before its index rows leaves those rows orphaned and
/// still searchable. The same reasoning puts the staged exports first of all — an export is a copy
/// of several stores at once, and a share sheet still holding one would outlive the erasure.
///
/// Every store gets a receipt, including the ones that cannot be erased. The ones that cannot are
/// the point: a recording is not indexed by who is audible in it, a clinical transcript is filed by
/// session rather than by patient, and pretending otherwise would be the failure. Those receipts
/// carry the reason, and `localComplete` is false for them, so a caller summarising the outcome
/// cannot report a completed erasure it did not perform.
@MainActor
final class SubjectErasureCoordinator {

    /// The store handles an erasure needs. All optional: a caller wires what it has, and anything
    /// absent produces a receipt saying the store was not reachable rather than being skipped
    /// silently.
    struct Stores {
        var stagedExports: [StagedExportCoordinator] = []
        var spotlight: SpotlightIndexService?
        var recallIndex: ConversationIndex?
        var vaultDirectories: [URL] = []
        var documents: DocumentStore?
        var brain: BrainStore?
        var semanticMemory: SemanticMemoryStore?
        var social: SocialContextStore?
        var faces: FaceRecognitionService?
        var contextualNotes: ContextualNoteStore?
        var objectMemory: ObjectMemoryStore?
        var evolvedSkills: EvolvedSkillStore?
        var agentDocuments: AgentDocumentStore?
        var recordedSessions: RecordedSessionStore?
        var conversations: ConversationStore?
        var offlineQueue: OfflineQueue?

        init() {}
    }

    /// The stores an erasure walks, in the order it walks them. Derived before source.
    ///
    /// `SubjectErasureTests` checks this against the registry, so a new store that gains a subject
    /// delete — or a new store holding third-party data — fails until it is wired in here.
    static let order: [SensitiveStore] = [
        // Copies of several stores at once.
        .stagedExports,
        .medicalExports,
        // Derived indexes and projections.
        .spotlightIndex,
        .conversationRecallIndex,
        .vaultLedger,
        // Sources.
        .ragDocuments,
        .brainGraph,
        .semanticMemory,
        .socialContext,
        .faces,
        .speakerNames,
        .contextualNotes,
        .objectMemory,
        .evolvedSkills,
        .agentDocuments,
        .recordedSessions,
        .recordings,
        .capturedPhotos,
        .clinicalTranscripts,
        .keychainClinicalCredentials,
        .conversationThreads,
        // Last: the queue that tells a peer to do the same.
        .offlineQueue,
    ]

    private let stores: Stores

    init(stores: Stores) {
        self.stores = stores
    }

    // MARK: - Erasure

    /// Erase `subject` everywhere this device can reach, and queue a tombstone for everywhere it
    /// cannot. Returns one receipt per store in `order`.
    @discardableResult
    func erase(_ subject: ErasureSubject, now: Date = Date()) async -> [ErasureReceipt] {
        var receipts: [ErasureReceipt] = []
        var remotePending = false

        for store in Self.order {
            let receipt: ErasureReceipt
            switch store {
            case .stagedExports:
                receipt = eraseStagedExports()
            case .medicalExports:
                receipt = .unsupported(store, "a clinical export is a lease, released on share or TTL, "
                                       + "not searchable by subject")
            case .spotlightIndex:
                receipt = await eraseSpotlight()
            case .conversationRecallIndex:
                receipt = eraseRecallIndex(subject)
            case .vaultLedger:
                receipt = eraseVaultLedger(subject)
            case .ragDocuments:
                receipt = eraseDocuments(subject)
            case .brainGraph:
                receipt = eraseBrain(subject)
            case .semanticMemory:
                let made = eraseSemanticMemory(subject)
                if made.localComplete { remotePending = true }
                receipt = made
            case .socialContext:
                receipt = eraseSocial(subject)
            case .faces:
                receipt = eraseFaces(subject)
            case .speakerNames:
                receipt = .unsupported(store, "a diarization label is keyed by voice cluster id; "
                                       + "the wearer renames or clears it from the captions screen")
            case .contextualNotes:
                receipt = eraseContextualNotes(subject)
            case .objectMemory:
                receipt = eraseObjectMemory(subject)
            case .evolvedSkills:
                receipt = eraseEvolvedSkills(subject)
            case .agentDocuments:
                receipt = eraseAgentDocuments(subject)
            case .recordedSessions:
                receipt = eraseRecordedSessions(subject)
            case .recordings:
                receipt = .unsupported(store, "a recording is not indexed by who is audible in it; "
                                       + "erasure is per file from the recordings screen")
            case .capturedPhotos:
                receipt = .unsupported(store, "a photo is not indexed by who appears in it; "
                                       + "erasure is per file, in Photos")
            case .clinicalTranscripts:
                receipt = .unsupported(store, "transcripts are filed by session, not by patient; "
                                       + "clinical retention is what removes them")
            case .keychainClinicalCredentials:
                receipt = .unsupported(store, "clinical context is keyed by FHIR server, not by person")
            case .conversationThreads:
                receipt = eraseConversations(subject)
            case .offlineQueue:
                receipt = eraseQueue(subject, remotePending: remotePending, now: now)
            default:
                receipt = .unsupported(store, "not wired into the erasure walk")
            }
            receipts.append(receipt)
        }

        PrivacyLog.store(.subjectErasure, .cleared,
                         count: receipts.filter(\.localComplete).count,
                         total: receipts.count)
        return receipts
    }

    /// A one-line, content-free summary a caller can put in front of the wearer.
    static func summary(_ receipts: [ErasureReceipt]) -> String {
        let done = receipts.filter { $0.localComplete }.count
        let removed = receipts.reduce(0) { $0 + $1.removed }
        let pending = receipts.contains { $0.remotePending }
        let blocked = receipts.filter { $0.unsupported != nil }.count
        var text = "Erased \(removed) record(s) across \(done) store(s)."
        if pending { text += " A copy on a connected peer is queued for deletion and not confirmed yet." }
        if blocked > 0 { text += " \(blocked) store(s) cannot be erased by subject; see the receipt." }
        return text
    }

    // MARK: - Per-store

    private func eraseStagedExports() -> ErasureReceipt {
        guard !stores.stagedExports.isEmpty else {
            return .unsupported(.stagedExports, "no export coordinator was supplied")
        }
        // An export is a copy of several stores at once and carries no index of its own, so the
        // only correct answer is to revoke every staged archive rather than search inside them.
        let removed = stores.stagedExports.reduce(0) { $0 + $1.revokeAll() }
        return .complete(.stagedExports, removed: removed)
    }

    private func eraseSpotlight() async -> ErasureReceipt {
        guard let spotlight = stores.spotlight else {
            return .unsupported(.spotlightIndex, "no Spotlight service was supplied")
        }
        // The donation is a projection of the stores below; purging and letting the next refresh
        // rebuild from what survives is what keeps the index from outliving its sources.
        await spotlight.purgeAll()
        return .complete(.spotlightIndex)
    }

    private func eraseRecallIndex(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let index = stores.recallIndex else {
            return .unsupported(.conversationRecallIndex, "no recall index was supplied")
        }
        switch subject {
        case .conversationThread(let id):
            index.delete(threadID: id)
            return .complete(.conversationRecallIndex)
        case .person, .document:
            // The index is full-text, so the honest reach is the same one recall itself uses:
            // find the turns that mention the subject, then delete exactly those rows.
            let hits = index.search(phrase: subject.searchToken, limit: 500)
            guard !hits.isEmpty else { return .complete(.conversationRecallIndex) }
            index.delete(messageIDs: hits.map(\.id))
            return .complete(.conversationRecallIndex, removed: hits.count)
        }
    }

    private func eraseVaultLedger(_ subject: ErasureSubject) -> ErasureReceipt {
        guard case .document(let id) = subject else {
            return .complete(.vaultLedger)   // nothing in the ledger is keyed by anything else
        }
        guard !stores.vaultDirectories.isEmpty else {
            return .unsupported(.vaultLedger, "no vault directory was supplied")
        }
        var removed = 0
        for directory in stores.vaultDirectories {
            if (try? VaultDocumentLedger.forget(documentId: id, in: directory)) ?? nil != nil {
                removed += 1
            }
        }
        return .complete(.vaultLedger, removed: removed)
    }

    private func eraseDocuments(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let documents = stores.documents else {
            return .unsupported(.ragDocuments, "no document store was supplied")
        }
        switch subject {
        case .document(let id):
            documents.forget(documentId: id)
            return .complete(.ragDocuments, removed: 1)
        case .person:
            let ids = Set(documents.passages(containingToken: subject.searchToken, limit: 500)
                .map(\.documentId))
            ids.forEach { documents.forget(documentId: $0) }
            return .complete(.ragDocuments, removed: ids.count)
        case .conversationThread:
            return .complete(.ragDocuments)
        }
    }

    private func eraseBrain(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let brain = stores.brain else {
            return .unsupported(.brainGraph, "no brain store was supplied")
        }
        guard case .person(let name) = subject else { return .complete(.brainGraph) }
        brain.forget(entityName: name)
        return .complete(.brainGraph, removed: 1)
    }

    private func eraseSemanticMemory(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let memory = stores.semanticMemory else {
            return .unsupported(.semanticMemory, "no memory store was supplied")
        }
        // Memories are key/value and the value is free prose, so both halves have to be searched.
        let token = subject.searchToken.lowercased()
        let doomed = memory.memories.filter {
            $0.key.lowercased().contains(token) || $0.value.lowercased().contains(token)
        }
        doomed.keys.forEach { _ = memory.forget($0) }
        // The remember path copies to a connected gateway; this device cannot confirm that copy is
        // gone, so the receipt says pending and the queue below carries the request.
        return ErasureReceipt(store: .semanticMemory, localComplete: true, remotePending: true,
                              removed: doomed.count, unsupported: nil)
    }

    private func eraseSocial(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let social = stores.social else {
            return .unsupported(.socialContext, "no social store was supplied")
        }
        guard case .person(let name) = subject else { return .complete(.socialContext) }
        let before = social.facts(for: name).count
        social.clearFacts(for: name)
        return .complete(.socialContext, removed: before)
    }

    private func eraseFaces(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let faces = stores.faces else {
            return .unsupported(.faces, "no face service was supplied")
        }
        guard case .person(let name) = subject else { return .complete(.faces) }
        let before = faces.knownFaces.count
        _ = faces.forgetFace(name: name)
        return .complete(.faces, removed: before - faces.knownFaces.count)
    }

    private func eraseContextualNotes(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let notes = stores.contextualNotes else {
            return .unsupported(.contextualNotes, "no note store was supplied")
        }
        return .complete(.contextualNotes, removed: notes.deleteMatching(subject.searchToken))
    }

    private func eraseObjectMemory(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let objects = stores.objectMemory else {
            return .unsupported(.objectMemory, "no object memory was supplied")
        }
        let token = subject.searchToken.lowercased()
        let doomed = objects.all().filter {
            $0.objectName.lowercased().contains(token)
                || $0.locationDescription.lowercased().contains(token)
        }
        doomed.forEach { _ = objects.delete($0.objectName) }
        return .complete(.objectMemory, removed: doomed.count)
    }

    private func eraseEvolvedSkills(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let skills = stores.evolvedSkills else {
            return .unsupported(.evolvedSkills, "no skill store was supplied")
        }
        return .complete(.evolvedSkills, removed: skills.deleteMatching(subject.searchToken))
    }

    private func eraseAgentDocuments(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let documents = stores.agentDocuments else {
            return .unsupported(.agentDocuments, "no agent document store was supplied")
        }
        return .complete(.agentDocuments, removed: documents.removeLines(containing: subject.searchToken))
    }

    private func eraseRecordedSessions(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let sessions = stores.recordedSessions else {
            return .unsupported(.recordedSessions, "no recorded session store was supplied")
        }
        let token = subject.searchToken.lowercased()
        let doomed = sessions.sessions.filter {
            $0.title.lowercased().contains(token) || $0.transcript.lowercased().contains(token)
        }
        doomed.forEach { sessions.delete($0) }
        return .complete(.recordedSessions, removed: doomed.count)
    }

    private func eraseConversations(_ subject: ErasureSubject) -> ErasureReceipt {
        guard let conversations = stores.conversations else {
            return .unsupported(.conversationThreads, "no conversation store was supplied")
        }
        switch subject {
        case .conversationThread(let id):
            conversations.deleteThread(id)
            return .complete(.conversationThreads, removed: 1)
        case .person, .document:
            // A thread is not about one person, so deleting whole threads because a name appears
            // in them would erase the wearer's own record of unrelated conversations. The turns
            // that mention the subject are already gone from the recall index above; the thread
            // text itself is left, and the receipt says so.
            return .unsupported(.conversationThreads,
                                "a thread is not about one subject; its matching turns are removed "
                                    + "from the recall index instead")
        }
    }

    private func eraseQueue(_ subject: ErasureSubject, remotePending: Bool,
                            now: Date) -> ErasureReceipt {
        guard let queue = stores.offlineQueue else {
            return .unsupported(.offlineQueue, "no offline queue was supplied")
        }
        // Two jobs. First, anything already queued that carries the subject must not go out after
        // the wearer asked for it to be forgotten — a pending op is a copy waiting to be sent.
        let token = subject.searchToken.lowercased()
        let carriers = queue.all(limit: 5000).filter {
            String(data: $0.payload, encoding: .utf8)?.lowercased().contains(token) == true
        }
        carriers.forEach { queue.delete(id: $0.id) }

        // Second, the tombstone. It carries the subject's identity because that is what a peer
        // needs to delete, and nothing else about them. It stays pending until a sink acknowledges
        // it, which is what makes `remotePending` an honest answer rather than a hope.
        guard remotePending else {
            return .complete(.offlineQueue, removed: carriers.count)
        }
        queue.enqueue(QueuedOp.make(
            kind: .subjectErasure,
            sessionId: "erasure",
            json: ["subjectKind": subject.kindLabel,
                   "subject": subject.searchToken,
                   "requestedAt": now.timeIntervalSince1970]))
        return ErasureReceipt(store: .offlineQueue, localComplete: true, remotePending: true,
                              removed: carriers.count, unsupported: nil)
    }
}
