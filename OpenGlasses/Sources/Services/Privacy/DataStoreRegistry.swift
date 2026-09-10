import Foundation

/// W03.1 — the sensitive-store inventory, as code rather than a document.
///
/// The roadmap asks for a data-lifecycle matrix: every store the app keeps, with its data class,
/// whose data it is, what protects it, whether it is backed up, when it expires, and what can
/// delete it. A table in a plan drifts the first time somebody adds a store; this one is checked
/// by `DataStoreRegistryTests`, which scrapes the sources for anything that opens SQLite, writes
/// into the app container, encodes structured content into preferences or adds a Keychain item,
/// and fails when it finds an owner nobody registered. The rendered Markdown in
/// `docs/plans/ET-iso27701-privacy.md` is generated from here for the same reason.
///
/// The values are *descriptive*: they record what the owner actually does today, including where
/// that is the platform default and nothing more. `DataStoreRegistryTests` reads the attributes
/// back off real stores in a temporary directory wherever that is possible, so a case claiming
/// protection its owner does not set fails rather than reassuring anybody.
///
/// ## What is excluded from backup, and what is deliberately not
///
/// The rule applied in W03.3 is **a store the subject-erasure walk can reach is excluded from
/// backup**, because a copy in a backup is a copy an erasure cannot reach, and restoring it is how
/// a forgotten person comes back. That covers the conversation history and its recall index, the
/// semantic memory, the knowledge graph, the document corpus, the face database, the evolved
/// skills and the offline queue — the queue most sharply of all, since a restored copy would
/// re-send work the wearer already watched complete. `usage.sqlite` is excluded for a different
/// and smaller reason: it is local operational accounting with nothing to restore.
///
/// The stores left backed up are left backed up on purpose, and it is a product decision rather
/// than an oversight: the wearer's own writing — notes, contextual notes, teleprompter scripts,
/// study decks, playbooks, saved places, the agent's `soul`/`skills`/`memory` documents — would
/// otherwise not survive a phone migration, and losing somebody's notebook to a privacy control
/// is a worse outcome than keeping it. What makes that safe is `ErasureLedger` replay: a completed
/// erasure is re-applied when one of those stores reappears. The limits of that mechanism are
/// stated in `docs/plans/ET-iso27701-privacy.md` rather than implied away.
enum SensitiveStore: String, CaseIterable {

    // Conversation and its derived index
    case conversationThreads
    case conversationRecallIndex

    // Memory and knowledge
    case semanticMemory
    case brainGraph
    case ragDocuments
    case agentDocuments

    // People
    case faces
    case socialContext
    case speakerNames

    // Wearer-authored notes and places
    case savedNotes
    case contextualNotes
    case objectMemory
    case savedLocations
    case geofenceReminders
    case voiceSkills
    case playbooks
    case teleprompterScripts
    case studyDecks
    case readingSessions
    case agentSchedule
    case agentNotificationQueue
    case notificationDigest

    // Media
    case recordings
    case recordedSessions
    case capturedPhotos

    // Field Assist and vaults
    case fieldSessionLogs
    case vaultDocuments
    case vaultLedger
    case fieldDeliverySettings
    case safetyAssessments

    // Clinical
    case clinicalTranscripts
    case clinicalAuditLog
    case clinicalConfiguration

    // Operational
    case offlineQueue
    case usage
    case operationJournal
    case remoteInvokeAudit
    case debugEventLog
    case spotlightIndex

    // Skills
    case evolvedSkills
    case installedSkills
    case skillPacks

    // Exports
    case medicalExports
    case stagedExports
    case diagnosticExports

    // Preferences and licence
    case preferences
    case licence

    // Keychain, by item family
    case keychainProviderKeys
    case keychainOAuthTokens
    case keychainServiceTokens
    case keychainDeviceIdentity
    case keychainConversationKey
    case keychainClinicalCredentials
    case keychainScopedDataKeys

    // Trust and consent registers (tool-definition digests, versioned consent records)
    case toolDefinitionDigests
    case consentRecords

    // The record of what has already been erased, so a restore cannot undo it
    case erasureLedger

    // MARK: - Facets

    /// What kind of thing the store holds. Coarser than the inventory's data categories on
    /// purpose: this is the axis retention and erasure decisions are actually made on.
    enum DataClass: String {
        case conversationContent
        case derivedIndex
        case personalMemory
        case knowledgeGraph
        case documentCorpus
        case biometric
        case socialProfile
        case media
        case clinical
        case operationalAudit
        case credential
        case preference
        case exportArtifact
        case locationData
        case skillDefinition
    }

    /// Whose data a record is about. `thirdPartySubject` is the one that matters most: those
    /// people did not install the app and cannot open its settings.
    enum SubjectLinkage: String {
        /// About the wearer, or authored by them.
        case wearer
        /// About somebody else the wearer observed, met or recorded.
        case thirdPartySubject
        /// Not about a person at all.
        case none
    }

    /// The protection the owner actually applies — not the protection it ought to have.
    enum Protection: String {
        /// `FileProtectionType.complete`, set explicitly by the owner.
        case complete
        /// `FileProtectionType.completeUntilFirstUserAuthentication`, set explicitly.
        case completeUntilFirstUserAuthentication
        /// No attribute set by the app: whatever the container's default is.
        case platformDefault
        case keychainAfterFirstUnlockThisDeviceOnly
        case keychainWhenUnlockedThisDeviceOnly
        /// Keychain, `whenUnlockedThisDeviceOnly` behind a `.userPresence` access control.
        case keychainWhenUnlockedThisDeviceOnlyWithUserPresence
        /// Held by an OS service (CoreSpotlight, Photos) under that service's own protection.
        case operatingSystemManaged
        /// Never reaches disk in production.
        case processMemoryOnly
    }

    /// When records leave, if anything makes them.
    enum Retention: Equatable {
        /// Nothing expires; records live until something deletes them.
        case none
        /// A fixed row/entry cap, oldest evicted.
        case cap(Int)
        /// Time-to-live sweep.
        case ttl
        /// A named policy that is neither a plain cap nor a plain TTL.
        case policy(String)

        var rendered: String {
            switch self {
            case .none: return "none"
            case .cap(let n): return "cap \(n)"
            case .ttl: return "TTL sweep"
            case .policy(let name): return name
            }
        }
    }

    /// Whether an erasure can reach this store, and by what.
    enum Deletion: Equatable {
        /// The API that does it.
        case api(String)
        /// Nothing does it, and why that is or is not acceptable.
        case unavailable(String)
        /// The store holds nothing about a person, so there is nothing to erase per subject.
        case notSubjectLinked

        var isAvailable: Bool { if case .api = self { return true }; return false }

        var rendered: String {
            switch self {
            case .api(let name): return "`\(name)`"
            case .unavailable(let reason): return "none — \(reason)"
            case .notSubjectLinked: return "n/a — no subject linkage"
            }
        }
    }

    /// One registered store's facts.
    struct Record {
        let store: SensitiveStore
        let dataClass: DataClass
        let subjectLinkage: SubjectLinkage
        let protection: Protection
        let backupExcluded: Bool
        let retention: Retention
        let deleteAll: Deletion
        let deleteSubject: Deletion
        /// The type that owns the bytes.
        let owner: String
        /// Repo-relative source paths the owner lives in. The exhaustiveness scrape matches on
        /// these, so a store moved to a new file fails the test until the registry follows it.
        let ownerPaths: [String]
        /// Where the bytes are, in words. Never a live path.
        let location: String
    }

    // MARK: - The inventory

    var record: Record {
        switch self {

        case .conversationThreads:
            return Record(store: self, dataClass: .conversationContent, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true,
                          retention: .policy("wearer history retention days; off by default"),
                          deleteAll: .api("ConversationStore.deleteAllThreads()"),
                          deleteSubject: .api("ConversationStore.deleteThread(_:)"),
                          owner: "ConversationStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/ConversationStore.swift"],
                          location: "Documents/conversations.json")

        case .conversationRecallIndex:
            return Record(store: self, dataClass: .derivedIndex, subjectLinkage: .wearer,
                          protection: .processMemoryOnly, backupExcluded: true, retention: .none,
                          deleteAll: .api("ConversationIndex.clear()"),
                          deleteSubject: .api("ConversationIndex.delete(threadID:)"),
                          owner: "ConversationIndex",
                          ownerPaths: ["OpenGlasses/Sources/Services/Memory/ConversationIndex.swift"],
                          location: "in-memory SQLite; the file-backed initialiser is test-only")

        case .semanticMemory:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("expires_at purge, wearer history retention days, budget eviction"),
                          deleteAll: .api("SemanticMemoryStore.clearAll()"),
                          deleteSubject: .api("SemanticMemoryStore.forget(_:)"),
                          owner: "SemanticMemoryStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/SemanticMemoryStore.swift"],
                          location: "Documents/semantic_memory.sqlite")

        case .brainGraph:
            return Record(store: self, dataClass: .knowledgeGraph, subjectLinkage: .thirdPartySubject,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("no whole-graph clear; erasure is per entity"),
                          deleteSubject: .api("BrainStore.forget(entityName:)"),
                          owner: "BrainStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Brain/BrainStore.swift"],
                          location: "Documents/brain.sqlite")

        case .ragDocuments:
            return Record(store: self, dataClass: .documentCorpus, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .none,
                          deleteAll: .api("DocumentStore.clearAll()"),
                          deleteSubject: .api("DocumentStore.forget(documentId:)"),
                          owner: "DocumentStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/RAG/DocumentStore.swift"],
                          location: "Documents/documents.sqlite")

        case .agentDocuments:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .api("AgentDocumentStore.save(_:content:) to default content"),
                          deleteSubject: .api("AgentDocumentStore.removeLines(containing:)"),
                          owner: "AgentDocumentStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/AgentDocumentStore.swift"],
                          location: "Documents/{soul,skills,memory}.md")

        case .faces:
            return Record(store: self, dataClass: .biometric, subjectLinkage: .thirdPartySubject,
                          protection: .complete, backupExcluded: true, retention: .none,
                          deleteAll: .api("FaceRecognitionService.forgetAllFaces()"),
                          deleteSubject: .api("FaceRecognitionService.forgetFace(name:)"),
                          owner: "FaceRecognitionService",
                          ownerPaths: ["OpenGlasses/Sources/Services/FaceRecognitionService.swift"],
                          location: "Documents/known_faces.json")

        case .socialContext:
            return Record(store: self, dataClass: .socialProfile, subjectLinkage: .thirdPartySubject,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("people are forgotten one at a time"),
                          deleteSubject: .api("SocialContextStore.clearFacts(for:)"),
                          owner: "SocialContextStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/SocialContextTool.swift"],
                          location: "preferences key `socialContext`")

        case .speakerNames:
            return Record(store: self, dataClass: .biometric, subjectLinkage: .thirdPartySubject,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("names are cleared per speaker"),
                          deleteSubject: .api("SpeakerRegistry.setName(nil, for:)"),
                          owner: "SpeakerRegistry",
                          ownerPaths: ["OpenGlasses/Sources/Services/Diarization/SpeakerRegistry.swift"],
                          location: "preferences key `diarizationSpeakerNames`")

        case .savedNotes:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .cap(50),
                          deleteAll: .unavailable("the wearer's own notes; the cap is what expires them"),
                          deleteSubject: .unavailable("free-text notes are not indexed by person"),
                          owner: "NotesStorage",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/NotesTool.swift"],
                          location: "preferences key `nativeTool_savedNotes`")

        case .contextualNotes:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("the wearer's own notes, removed by query"),
                          deleteSubject: .api("ContextualNoteStore.deleteMatching(_:)"),
                          owner: "ContextualNoteStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/ContextualNoteTool.swift"],
                          location: "preferences key `contextualNotes`")

        case .objectMemory:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("entries are removed one object at a time"),
                          deleteSubject: .api("ObjectMemoryStore.delete(_:)"),
                          owner: "ObjectMemoryStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/ObjectMemoryTool.swift"],
                          location: "preferences key `objectMemory`")

        case .savedLocations:
            return Record(store: self, dataClass: .locationData, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("the wearer's own places, removed individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "SaveLocationTool",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/SaveLocationTool.swift"],
                          location: "preferences key `saved_locations`")

        case .geofenceReminders:
            return Record(store: self, dataClass: .locationData, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("reminders are removed individually as they fire"),
                          deleteSubject: .notSubjectLinked,
                          owner: "GeofenceTool",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/GeofenceTool.swift"],
                          location: "preferences key `geofence_reminders`")

        case .voiceSkills:
            return Record(store: self, dataClass: .skillDefinition, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("skills are removed individually by name"),
                          deleteSubject: .notSubjectLinked,
                          owner: "VoiceSkillStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/VoiceSkillsTool.swift"],
                          location: "preferences key `voiceSkills`")

        case .playbooks:
            return Record(store: self, dataClass: .skillDefinition, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("playbooks are the wearer's authored content, removed individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "PlaybookStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/PlaybookStore.swift"],
                          location: "preferences keys `playbooks`, playbook session state")

        case .teleprompterScripts:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("scripts are the wearer's authored content, removed individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "TeleprompterScriptStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Teleprompter/TeleprompterScriptStore.swift"],
                          location: "Documents/teleprompter_scripts.json")

        case .studyDecks:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("decks are the wearer's authored content, removed individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "StudyStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Study/StudyStore.swift"],
                          location: "Application Support/StudyDecks/{decks,reviews}.json")

        case .readingSessions:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true, retention: .none,
                          deleteAll: .unavailable("sessions are removed individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "ReadingSessionStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Reading/ReadingSessionStore.swift"],
                          location: "Application Support/ReadingSessions/{sessions,references}.json")

        case .agentSchedule:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("tasks are cancelled individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "AgentScheduler",
                          ownerPaths: ["OpenGlasses/Sources/Services/AgentScheduler.swift"],
                          location: "preferences key `agentScheduledTasks`")

        case .agentNotificationQueue:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("entries are consumed as the agent triages them"),
                          deleteSubject: .notSubjectLinked,
                          owner: "AgentNotificationQueue",
                          ownerPaths: ["OpenGlasses/Sources/Services/AgentNotificationQueue.swift"],
                          location: "Documents/agent_notification_queue.json")

        case .notificationDigest:
            return Record(store: self, dataClass: .personalMemory, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("the digest is rebuilt from the current window"),
                          deleteSubject: .notSubjectLinked,
                          owner: "NotificationDigestService",
                          ownerPaths: ["OpenGlasses/Sources/Services/Digest/NotificationDigestService.swift"],
                          location: "Documents/notification_digest.json")

        case .recordings:
            return Record(store: self, dataClass: .media, subjectLinkage: .thirdPartySubject,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("recordings are the wearer's media, removed individually"),
                          deleteSubject: .unavailable("a recording is not indexed by who appears in it"),
                          owner: "VideoRecordingService",
                          ownerPaths: ["OpenGlasses/Sources/Services/VideoRecordingService.swift"],
                          location: "Documents/Recordings, Documents/Transcripts")

        case .recordedSessions:
            return Record(store: self, dataClass: .media, subjectLinkage: .thirdPartySubject,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .api("RecordedSessionStore.deleteAll()"),
                          deleteSubject: .api("RecordedSessionStore.delete(_:)"),
                          owner: "RecordedSessionStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/RecordedSessionStore.swift"],
                          location: "Documents/recorded_sessions.json plus the audio it names")

        case .capturedPhotos:
            return Record(store: self, dataClass: .media, subjectLinkage: .thirdPartySubject,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("photos are the wearer's media, managed in Photos"),
                          deleteSubject: .unavailable("a photo is not indexed by who appears in it"),
                          owner: "AppState",
                          ownerPaths: ["OpenGlasses/Sources/App/OpenGlassesApp.swift"],
                          location: "Documents/Photos")

        case .fieldSessionLogs:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("a session log is the engineer's compliance record"),
                          deleteSubject: .notSubjectLinked,
                          owner: "SessionLogger",
                          ownerPaths: ["OpenGlasses/Sources/Services/FieldAssist/SessionLogger.swift"],
                          location: "Documents/FieldSessions/{id}/{session.json,log.jsonl,photos}")

        case .vaultDocuments:
            return Record(store: self, dataClass: .documentCorpus, subjectLinkage: .none,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("vaults are removed individually by identity"),
                          deleteSubject: .notSubjectLinked,
                          owner: "VaultStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Vault/VaultStore.swift",
                                       "OpenGlasses/Sources/Services/Vault/VaultImporter.swift"],
                          location: "Documents/Vaults/{id}")

        case .vaultLedger:
            return Record(store: self, dataClass: .derivedIndex, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .api("VaultDocumentLedger.clear(in:)"),
                          deleteSubject: .api("VaultDocumentLedger.forget(documentId:in:)"),
                          owner: "VaultDocumentLedger",
                          ownerPaths: ["OpenGlasses/Sources/Services/Vault/VaultDocumentLedger.swift"],
                          location: "Documents/Vaults/{id}/_documents.json")

        case .fieldDeliverySettings:
            return Record(store: self, dataClass: .preference, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("configuration, cleared by reconfiguring"),
                          deleteSubject: .notSubjectLinked,
                          owner: "DeliverySettings",
                          ownerPaths: ["OpenGlasses/Sources/Services/FieldAssist/DeliverySettings.swift"],
                          location: "preferences key `fieldAssistDeliverySettings`; its token is in the Keychain")

        case .safetyAssessments:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("assessment history is the site record"),
                          deleteSubject: .notSubjectLinked,
                          owner: "SafetyAssessmentStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/SafetyAssessment/SafetyAssessmentStore.swift"],
                          location: "Application Support/SafetyAssessments/history.json")

        case .clinicalTranscripts:
            return Record(store: self, dataClass: .clinical, subjectLinkage: .thirdPartySubject,
                          protection: .complete, backupExcluded: true,
                          retention: .policy("clinical retention days, whatever the mode; disabled at zero"),
                          deleteAll: .api("HIPAAComplianceService.deleteFile(at:)"),
                          deleteSubject: .unavailable("transcripts are filed by session, not by patient"),
                          owner: "HIPAAComplianceService",
                          ownerPaths: ["OpenGlasses/Sources/Services/HIPAAComplianceService.swift"],
                          location: "Documents/Transcripts")

        case .clinicalAuditLog:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true, retention: .cap(1000),
                          deleteAll: .api("HIPAAComplianceService.clearAuditLog"),
                          deleteSubject: .unavailable("an audit entry is evidence; it is content-free by design"),
                          owner: "HIPAAComplianceService",
                          // The service owns the log; FileAuditLogStore is the file it writes through.
                          ownerPaths: ["OpenGlasses/Sources/Services/HIPAAComplianceService.swift",
                                       "OpenGlasses/Sources/Services/AuditLogStore.swift"],
                          location: "Documents/hipaa_audit_log.json")

        case .clinicalConfiguration:
            return Record(store: self, dataClass: .preference, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("configuration, cleared by reconfiguring"),
                          deleteSubject: .notSubjectLinked,
                          owner: "FHIRConfigurationStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Medical/FHIRConfigurationStore.swift"],
                          location: "preferences key `fhirServerConfiguration`; secrets live in the Keychain")

        case .offlineQueue:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("purgeDone plus a photo-evidence byte budget"),
                          deleteAll: .api("OfflineQueue.deleteAll()"),
                          deleteSubject: .api("OfflineQueue.delete(id:)"),
                          owner: "OfflineQueue",
                          ownerPaths: ["OpenGlasses/Sources/Services/Offline/OfflineQueue.swift"],
                          location: "Documents/offline_queue.sqlite")

        case .usage:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .none,
                          deleteAll: .api("UsageStore.deleteAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "UsageStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Usage/UsageStore.swift"],
                          location: "Documents/usage.sqlite")

        case .toolDefinitionDigests:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .none,
                          deleteAll: .api("ToolDefinitionDigestStore.forget(serverID:) per server"),
                          deleteSubject: .notSubjectLinked,
                          owner: "ToolDefinitionDigestStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Security/ToolDefinitionDigestStore.swift"],
                          location: "Application Support/ToolTrust/tool-definition-digests.json")
        case .consentRecords:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("a consent record is evidence of what was agreed; withdrawal is recorded, not erased"),
                          deleteSubject: .unavailable("closed-vocabulary purpose/recipient/actor fields only; no subject identity is stored"),
                          owner: "ConsentStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Security/ConsentRecord.swift"],
                          location: "Application Support/Consent/consent-records.json")
        case .erasureLedger:
            return Record(store: self, dataClass: .operationalAudit,
                          subjectLinkage: .thirdPartySubject,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .cap(200),
                          deleteAll: .api("ErasureLedger.clear()"),
                          deleteSubject: .unavailable("the entry is what makes the erasure survive; "
                              + "removing it would let a restore bring the subject back"),
                          owner: "ErasureLedger",
                          ownerPaths: ["OpenGlasses/Sources/Services/Privacy/ErasureLedger.swift"],
                          location: "Application Support/Erasure/erasure-ledger.json")

        case .operationJournal:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("OperationJournalRetention (age and count)"),
                          deleteAll: .unavailable("the journal is the at-most-once evidence; retention prunes it"),
                          deleteSubject: .notSubjectLinked,
                          owner: "ProtectedOperationJournal",
                          // OperationJournalStorage is the file seam the journal writes through.
                          ownerPaths: ["OpenGlasses/Sources/Services/NativeTools/OperationJournal.swift",
                                       "OpenGlasses/Sources/Services/NativeTools/OperationJournalStorage.swift"],
                          location: "Application Support/OperationJournal/operations.json")

        case .remoteInvokeAudit:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .cap(50),
                          deleteAll: .unavailable("the trail is what makes remote invocation reviewable"),
                          deleteSubject: .notSubjectLinked,
                          owner: "RemoteInvokeService",
                          ownerPaths: ["OpenGlasses/Sources/Services/OpenClaw/RemoteInvoke/RemoteInvokeService.swift"],
                          location: "preferences key `remoteInvokeAuditLog`")

        case .debugEventLog:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false,
                          retention: .policy("ring-capped on write"),
                          deleteAll: .unavailable("the ring overwrites itself"),
                          deleteSubject: .notSubjectLinked,
                          owner: "AppState",
                          ownerPaths: ["OpenGlasses/Sources/App/OpenGlassesApp.swift"],
                          location: "Documents/debug-events.log")

        case .spotlightIndex:
            return Record(store: self, dataClass: .derivedIndex, subjectLinkage: .wearer,
                          protection: .operatingSystemManaged, backupExcluded: false, retention: .none,
                          deleteAll: .api("SpotlightIndexService.purgeAll()"),
                          deleteSubject: .api("SpotlightIndexing.delete(ids:)"),
                          owner: "SpotlightIndexService",
                          ownerPaths: ["OpenGlasses/Sources/Services/Siri/SpotlightIndexService.swift"],
                          location: "CoreSpotlight, plus a snapshot in preferences")

        case .evolvedSkills:
            return Record(store: self, dataClass: .skillDefinition, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .none,
                          deleteAll: .api("EvolvedSkillStore.deleteAll()"),
                          deleteSubject: .api("EvolvedSkillStore.deleteMatching(_:)"),
                          owner: "EvolvedSkillStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Skills/EvolvedSkillStore.swift"],
                          location: "Documents/evolved_skills.sqlite")

        case .installedSkills:
            return Record(store: self, dataClass: .skillDefinition, subjectLinkage: .none,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("skills are uninstalled individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "InstalledSkillStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/ClawHubService.swift"],
                          location: "Documents/clawhub_skills.json")

        case .skillPacks:
            return Record(store: self, dataClass: .skillDefinition, subjectLinkage: .none,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("packs are uninstalled individually"),
                          deleteSubject: .notSubjectLinked,
                          owner: "SkillPackStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/SkillPacks/SkillPackStore.swift"],
                          location: "Documents/skillpacks")

        case .medicalExports:
            return Record(store: self, dataClass: .exportArtifact, subjectLinkage: .thirdPartySubject,
                          protection: .complete, backupExcluded: true, retention: .ttl,
                          deleteAll: .api("MedicalExportFileStore.revokeAll()"),
                          deleteSubject: .unavailable("an export is a lease, released rather than searched"),
                          owner: "MedicalExportFileStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Medical/MedicalExportFileStore.swift"],
                          location: "Caches/MedicalExports/{session}")

        case .stagedExports:
            return Record(store: self, dataClass: .exportArtifact, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true, retention: .ttl,
                          deleteAll: .api("StagedExportCoordinator.revokeAll()"),
                          deleteSubject: .unavailable("an export is a lease, released rather than searched"),
                          owner: "StagedExportCoordinator",
                          ownerPaths: ["OpenGlasses/Sources/Services/Export/StagedExportCoordinator.swift"],
                          location: "Caches/{Agent,Safety,FieldSession}Exports/{session}")

        case .diagnosticExports:
            return Record(store: self, dataClass: .exportArtifact, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true, retention: .ttl,
                          deleteAll: .unavailable("released on share, background and launch scavenge"),
                          deleteSubject: .notSubjectLinked,
                          owner: "DiagnosticExportCoordinator",
                          ownerPaths: ["OpenGlasses/Sources/Services/Diagnostics/DiagnosticExportCoordinator.swift"],
                          location: "Caches/DiagnosticExports/{session}")

        case .preferences:
            return Record(store: self, dataClass: .preference, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("settings are the wearer's configuration, changed not erased"),
                          deleteSubject: .notSubjectLinked,
                          owner: "Config",
                          ownerPaths: ["OpenGlasses/Sources/Utils/Config.swift"],
                          location: "UserDefaults; the content-bearing keys are registered separately above")

        case .licence:
            return Record(store: self, dataClass: .credential, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("the licence is the wearer's entitlement, cleared by unlicensing"),
                          deleteSubject: .notSubjectLinked,
                          owner: "LicenseService",
                          ownerPaths: ["OpenGlasses/Sources/Services/LicenseService.swift"],
                          location: "preferences key `fieldAssistLicenseCode`")

        case .keychainProviderKeys:
            return Record(store: self, dataClass: .credential, subjectLinkage: .wearer,
                          protection: .keychainAfterFirstUnlockThisDeviceOnly, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("keys are removed per provider"),
                          deleteSubject: .notSubjectLinked,
                          owner: "KeychainService",
                          ownerPaths: ["OpenGlasses/Sources/Services/KeychainService.swift"],
                          location: "Keychain: LLM, TTS and search provider API keys")

        case .keychainOAuthTokens:
            return Record(store: self, dataClass: .credential, subjectLinkage: .wearer,
                          protection: .keychainAfterFirstUnlockThisDeviceOnly, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("tokens are removed per provider on sign-out"),
                          deleteSubject: .notSubjectLinked,
                          owner: "KeychainService",
                          ownerPaths: ["OpenGlasses/Sources/Services/KeychainService.swift"],
                          location: "Keychain: Google, Claude and ChatGPT OAuth credentials")

        case .keychainServiceTokens:
            return Record(store: self, dataClass: .credential, subjectLinkage: .wearer,
                          protection: .keychainAfterFirstUnlockThisDeviceOnly, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("tokens are removed per service"),
                          deleteSubject: .notSubjectLinked,
                          owner: "KeychainService",
                          ownerPaths: ["OpenGlasses/Sources/Services/KeychainService.swift"],
                          location: "Keychain: gateway, bridge, broadcast, MCP, HUD and delivery tokens")

        case .keychainDeviceIdentity:
            return Record(store: self, dataClass: .credential, subjectLinkage: .none,
                          protection: .keychainAfterFirstUnlockThisDeviceOnly, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("the identity is the device's, not a subject's"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OpenClawDeviceIdentity",
                          ownerPaths: ["OpenGlasses/Sources/Services/OpenClaw/OpenClawDeviceIdentity.swift"],
                          location: "Keychain: the device's Ed25519 private key")

        case .keychainConversationKey:
            return Record(store: self, dataClass: .credential, subjectLinkage: .wearer,
                          protection: .keychainWhenUnlockedThisDeviceOnlyWithUserPresence,
                          backupExcluded: true, retention: .none,
                          deleteAll: .api("ConversationEncryptionService.deleteKey()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "ConversationEncryptionService",
                          ownerPaths: ["OpenGlasses/Sources/Services/ConversationEncryptionService.swift"],
                          location: "Keychain: the conversation encryption key, behind user presence")

        case .keychainScopedDataKeys:
            return Record(store: self, dataClass: .credential, subjectLinkage: .thirdPartySubject,
                          protection: .keychainAfterFirstUnlockThisDeviceOnly, backupExcluded: true,
                          retention: .none,
                          deleteAll: .api("ScopedKeyring.eraseClass(_:files:)"),
                          deleteSubject: .unavailable("a scoped key covers a class, not a person; "
                              + "forgetting one person cannot destroy the key everyone else is sealed under"),
                          owner: "ScopedKeyring",
                          ownerPaths: ["OpenGlasses/Sources/Services/Privacy/ScopedKeyring.swift"],
                          location: "Keychain: one data key per erasable class")

        case .keychainClinicalCredentials:
            return Record(store: self, dataClass: .credential, subjectLinkage: .thirdPartySubject,
                          protection: .keychainWhenUnlockedThisDeviceOnly, backupExcluded: true,
                          retention: .none,
                          deleteAll: .unavailable("credentials are removed per FHIR server"),
                          deleteSubject: .api("FHIRCredentialStore.deleteContext(serverID:)"),
                          owner: "KeychainFHIRSecretStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Medical/FHIRCredentialStore.swift"],
                          location: "Keychain: FHIR bearer token, client secret, patient and practitioner ids")
        }
    }

    // MARK: - Views over the inventory

    static var all: [Record] { allCases.map(\.record) }

    /// Stores that can hold something about a named person — the set a subject erasure has to
    /// reach, whether or not it currently can.
    static var subjectLinked: [Record] {
        all.filter { $0.subjectLinkage != .none }
    }

    /// The paths the exhaustiveness scrape resolves against.
    static var registeredPaths: Set<String> {
        Set(all.flatMap(\.ownerPaths))
    }

    // MARK: - Rendering

    /// The data-lifecycle matrix, as the Markdown that lives in the ISO 27701 plan. Generated so
    /// the document cannot disagree with the code.
    static func markdownTable() -> String {
        var lines = [
            "| Store | Owner | Data class | Subject | Protection | Backup excluded | Retention | Delete all | Delete subject |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for record in all.sorted(by: { $0.store.rawValue < $1.store.rawValue }) {
            lines.append([
                record.store.rawValue,
                "`\(record.owner)`",
                record.dataClass.rawValue,
                record.subjectLinkage.rawValue,
                record.protection.rawValue,
                record.backupExcluded ? "yes" : "no",
                record.retention.rendered,
                record.deleteAll.rendered,
                record.deleteSubject.rendered,
            ].joined(separator: " | ").withPipes)
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var withPipes: String { "| \(self) |" }
}
