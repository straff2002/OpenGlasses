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
    case parkingSpots
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
    case vaultLinkStaging
    case fieldDeliverySettings
    case jobDeliveryQueue
    case upcomingJobs
    case orgEnrolment
    case safetyAssessments

    // The connection to the organisation's office (the opt-in office transport build)
    case officeTransportFolders
    case officeJobIntake
    case officeCheckIn
    case officeReports
    case officeReportEvidence
    case officeManuals
    case officeJobAttachments
    case officeJobUpdates
    case jobRecordingBundles
    case jobRecordingCapture

    // Clinical
    case healthSummaryCache
    case clinicalTranscripts
    case clinicalAuditLog
    case clinicalConfiguration

    // Operational
    case offlineQueue
    case usage
    case operationJournal
    case remoteInvokeAudit
    case debugEventLog
    case diagnosticBreadcrumbs
    case turnTraces
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
        /// `FileProtectionType.completeUnlessOpen` with backup exclusion, set by the owner only
        /// while Medical Compliance mode is on (`ComplianceFileProtection`), and applied to the
        /// files already there when the mode is turned on. Used for recording artefacts, which
        /// can be finished while the phone is locked. Outside the mode the app sets no attribute,
        /// and the backup-excluded column describes that state; a file created in a folder that
        /// was protected while the mode was on still inherits the folder's class.
        case completeUnlessOpenInComplianceMode
        /// `FileProtectionType.completeUnlessOpen`, set explicitly and always: a file being
        /// written or sent when the phone locks can be finished, and nothing new can be opened.
        case completeUnlessOpen
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

        case .parkingSpots:
            return Record(store: self, dataClass: .locationData, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("one active spot; the last 10 only while history is on (off by default)"),
                          deleteAll: .api("ParkingStore.clearAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "ParkingStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Parking/ParkingStore.swift"],
                          location: "Application Support/Parking/{parking.json,photos}")

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
                          protection: .completeUnlessOpenInComplianceMode, backupExcluded: false,
                          retention: .none,
                          deleteAll: .unavailable("recordings are the wearer's media, removed individually"),
                          deleteSubject: .unavailable("a recording is not indexed by who appears in it"),
                          owner: "VideoRecordingService",
                          ownerPaths: ["OpenGlasses/Sources/Services/VideoRecordingService.swift"],
                          location: "Documents/Recordings, Documents/Transcripts")

        case .recordedSessions:
            return Record(store: self, dataClass: .media, subjectLinkage: .thirdPartySubject,
                          protection: .completeUnlessOpenInComplianceMode, backupExcluded: false,
                          retention: .none,
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
                          // `photos/` is the visit's media, and since Plan FO P2c it also holds the
                          // customer's signature (`signature_*.png` and its stroke data) — a third
                          // party's handwriting, filed under the same compliance record the
                          // photographs are, and covered by the same posture and the same
                          // unavailable deletion. It is shown on the sign-off sheet, the work order
                          // and the past job's page, and is used for nothing else.
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
                          // The removal journal lives beside the ledger and is the same record in
                          // two halves: which manuals this vault has ingested, and which of them a
                          // removal has started on and not finished.
                          ownerPaths: ["OpenGlasses/Sources/Services/Vault/VaultDocumentLedger.swift",
                                       "OpenGlasses/Sources/Services/Vault/VaultManualRemoval.swift"],
                          location: "Documents/Vaults/{id}/_documents.json, and _removals.json beside "
                              + "it while a manual removal is in flight")

        case .vaultLinkStaging:
            return Record(store: self, dataClass: .documentCorpus, subjectLinkage: .none,
                          protection: .complete, backupExcluded: true,
                          retention: .policy("deleted when the install finishes, fails or is "
                                             + "dismissed; a directory found at launch belonged to "
                                             + "an approval that no longer exists and is swept"),
                          deleteAll: .api("VaultLinkStagingStore.removeAbandonedSessions()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "VaultLinkStagingStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Vault/VaultLinkStagingStore.swift"],
                          location: "Caches/VaultLinkStaging/{approval}/archive.zip")

        case .fieldDeliverySettings:
            return Record(store: self, dataClass: .preference, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("configuration, cleared by reconfiguring"),
                          deleteSubject: .notSubjectLinked,
                          owner: "DeliverySettings",
                          ownerPaths: ["OpenGlasses/Sources/Services/FieldAssist/DeliverySettings.swift"],
                          location: "preferences key `fieldAssistDeliverySettings`; its token is in the Keychain")

        case .jobDeliveryQueue:
            // Reports asked for by voice and waiting for a thumb (Plan FO P3b). It carries the
            // addresses each one would go to — which are **the same addresses
            // `fieldDeliverySettings` holds**, the organisation's own job-report destinations,
            // never a recipient taken from speech (`SpokenSendPolicy` refuses one outright). So the
            // linkage is the wearer's, as the settings' is, and there is nothing filed by person to
            // erase. It is protected and kept out of backup all the same: a queue restored onto
            // another phone would offer to send a report that already went.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true,
                          retention: .cap(DeliveryQueue.entryCap),
                          deleteAll: .api("DeliveryQueueStore.removeAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "DeliveryQueueStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/FieldAssist/Job/DeliveryQueue.swift"],
                          location: "Application Support/FieldAssist/delivery-queue.json")

        case .upcomingJobs:
            // Jobs ahead of the technician (Plan FO P3c): typed, spoken, or opened from an `.ogjob`
            // file the office sent. It carries the customer's name, the site address and a contact
            // — the same facts the visit's own record carries once the job starts, filed the same
            // way: the organisation's work order, issued to this technician. So the linkage is
            // the wearer's, as `fieldSessionLogs`' is. Unlike the session log it is not yet a
            // compliance record, so it can be cleared, and it is protected and kept out of backup
            // because a restored list would offer jobs this phone was never given.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .complete, backupExcluded: true,
                          retention: .cap(UpcomingJobStore.entryCap),
                          deleteAll: .api("UpcomingJobStore.removeAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "UpcomingJobStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/FieldAssist/Job/UpcomingJobStore.swift"],
                          location: "Application Support/FieldAssist/upcoming-jobs.json")

        case .officeTransportFolders:
            // The embedded engine's own home, in the opt-in office transport build: its
            // certificate, and the two folders it shares with the one office the binding names.
            // Jobs the office sent are committed here as the exact files it signed; the records
            // and documents on their way to the office sit here from the moment they are
            // published until the office has them and they are withdrawn. The organisation's work
            // orders, issued to and written by this technician: the wearer's, as the session log
            // is. Nothing in the app deletes it whole; a published report is withdrawn file by
            // file, and the folders stop being served when the pairing ends.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: false,
                          retention: .policy("a published report is withdrawn once the office has all of it"),
                          deleteAll: .unavailable("the engine's home has no delete; it is emptied by withdrawing what was published and removed with the app"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeTransportIdentity",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeTransportIdentity.swift"],
                          location: "Application Support/AvenkinTransport/")

        case .officeJobIntake:
            // Which jobs the office sent were offered to the technician, refused, or reviewed, and
            // the receipt signature given for each. Message identifiers, digests and a bounded
            // reason: no job content, which is in `upcomingJobs` once it is accepted.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: false,
                          retention: .cap(OfficeManagedJobIntake.maximumEntries),
                          deleteAll: .unavailable("a receipt given to the office has to be reproducible byte for byte; the record is bounded and holds no job content"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeManagedJobIntake",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeManagedJobIntake+JobFiles.swift"],
                          location: "Application Support/AvenkinOffice/managed-jobs.json")

        case .officeCheckIn:
            // The one check-in this phone is waiting on (its exact bytes, nonce and signature) and
            // whether the office has removed the phone. Identifiers, digests and dates.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: false,
                          retention: .policy("one check-in at a time; forgotten on renewal or when its challenge expires"),
                          deleteAll: .unavailable("holds no content; a check-in is forgotten when it is answered"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeCheckInService",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeCheckInService.swift"],
                          location: "Application Support/AvenkinOffice/check-in.json")

        case .officeReports:
            // Each record on its way to the office: the report's signed bytes, its manifest, which
            // documents were published and what the office has said. It names the job and the
            // documents by identifier and digest; the record and the documents themselves are in
            // the queue and in `officeReportEvidence`. The wearer's, as the queue is.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: false,
                          retention: .cap(OfficeReportService.maximumEntries),
                          deleteAll: .api("OfficeReportService.forget(recordIDs:)"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeReportService",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeReportService.swift"],
                          location: "Application Support/AvenkinOffice/reports.json")

        case .officeReportEvidence:
            // The documents that go to the office with a job's record — the work order, the audit
            // export, and the transcript when the organisation's rule lets it leave the phone —
            // kept as the exact bytes the report named until the office has them. The same content
            // a staged export holds, for longer; the organisation's record, written by this
            // technician. Excluded from backup: a restored copy would be documents the office
            // already has, or was never sent.
            return Record(store: self, dataClass: .exportArtifact, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("removed when the office has all of a report, or a later report replaces it"),
                          deleteAll: .api("OfficeReportEvidenceStore.removeAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeReportEvidenceStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeReportEvidenceStore.swift"],
                          location: "Application Support/AvenkinOffice/report-evidence/")

        case .officeManuals:
            // Which manuals the office assigned: each assignment's signed bytes, the publisher
            // grants held, the highest assignment taken for each manual set, and whether each was
            // installed. Identifiers, digests and dates; the manuals themselves are in
            // `vaultDocuments` once installed. It is kept apart from the installed vaults on
            // purpose: removing a manual must not let an old assignment bring it back.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: false,
                          retention: .cap(OfficeManualService.maximumEntries),
                          deleteAll: .unavailable("the set marks are the rollback boundary for assigned manuals; the record is bounded and holds no manual content"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeManualService",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeManualService.swift"],
                          location: "Application Support/AvenkinOffice/manuals.json")

        case .officeJobAttachments:
            // The attachments a signed job names by digest, as the office sent them: a site plan,
            // a drawing, a photograph. The organisation's documents about a job, issued to this
            // technician with the work order, so filed as `upcomingJobs` is. Each is kept only while a job that names it is ahead or open on
            // this phone, and is never sent anywhere. Excluded from backup: the office has them.
            return Record(store: self, dataClass: .documentCorpus, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("removed when the job that names it is removed or finished"),
                          deleteAll: .api("OfficeJobAttachmentStore.removeAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeJobAttachmentStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeJobAttachmentStore.swift"],
                          location: "Application Support/AvenkinOffice/job-attachments/")

        case .officeJobUpdates:
            // What the office has said about jobs this phone has: each update's signed bytes —
            // a part's state, a new time, a note in the office's words — with when it arrived,
            // when the technician first had the job open with it, and the receipt given. The
            // organisation's messages about a work order issued to this technician, so filed as
            // `upcomingJobs` is. Excluded from backup: a restored copy would show updates for
            // jobs this phone was never given.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .cap(OfficeJobUpdateService.maximumEntries),
                          deleteAll: .api("OfficeJobUpdateService.removeAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OfficeJobUpdateService",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/OfficeJobUpdateService.swift"],
                          location: "Application Support/AvenkinOffice/job-updates.json")

        case .jobRecordingBundles:
            // A recorded job sealed for the office: the video and sound of the job cut into chunks,
            // its timeline (which carries the words said) and transcript, the signed manifest, the
            // office's receipts, and this phone's record of where the bundle stands. Unblurred
            // unless the organisation requires otherwise, so the pictures are of whoever was
            // there. It lives under the job's own folder and goes when the job goes. The media is
            // removed a week after the office's verified receipt, and never before one; what is
            // left is the record that it was sent. It has no other way off the phone.
            return Record(store: self, dataClass: .media, subjectLinkage: .thirdPartySubject,
                          protection: .completeUnlessOpen, backupExcluded: true,
                          retention: .policy("media removed 7 days after the office's verified receipt; nothing unacknowledged is removed automatically"),
                          deleteAll: .api("JobRecordingSyncService.delete(bundleID:)"),
                          deleteSubject: .unavailable("a recording is not indexed by who appears in it"),
                          owner: "JobRecordingBundleStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/JobRecordingBundleStore.swift"],
                          location: "Documents/FieldSessions/{id}/recording/bundle/")

        case .jobRecordingCapture:
            // "Record this job" as it is being made, before it is sealed: each recorded part as
            // the recorder wrote it — the glasses' pictures and the microphone's sound, unblurred —
            // and a small journal of the recording so far (its clock, its parts, what was noted
            // as it happened, which carries tool names and no words). Written straight into the
            // job's own folder, never to the temporary directory, the Recordings folder or Photos.
            // It lasts as long as the recording does: stopping seals it into the bundle and the
            // parts are removed; a recording the app was closed in the middle of can be carried on
            // while its job is open, and is sealed from what it had once the job has closed. It
            // goes with its job, and has no way off the phone of its own — the bundle is the
            // only exit.
            return Record(store: self, dataClass: .media, subjectLinkage: .thirdPartySubject,
                          protection: .completeUnlessOpen, backupExcluded: true,
                          retention: .policy("removed when the recording is sealed into its bundle; one interrupted by the app closing is carried on or sealed once its job has closed"),
                          deleteAll: .api("JobRecordingCaptureStore.remove(sessionID:)"),
                          deleteSubject: .unavailable("a recording is not indexed by who appears in it"),
                          owner: "JobRecordingCaptureStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/OfficeSync/JobRecordingCaptureStore.swift"],
                          location: "Documents/FieldSessions/{id}/recording/capture/")

        case .orgEnrolment:
            // Plan CT: the organisation profile this phone is enrolled with — the signed document,
            // the lease, and what enrolment wrote and must put back — and, once the phone has left
            // the firm, what it still owes the firm (`OrgDeparture`: which session logs, and by
            // when they are erased). No content: names, ids and dates. The wearer's, as the
            // delivery settings are; removing the profile is the delete, and a departure record
            // is kept after it only until the firm's records have gone.
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .api("OrgProfileManager.remove()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "OrgProfileManager",
                          ownerPaths: ["OpenGlasses/Sources/Services/OrgProfile/OrgProfileManager.swift",
                                       "OpenGlasses/Sources/Services/OrgProfile/OrgDeparture.swift"],
                          location: "preferences keys `orgProfileEnrolment` and `orgDeparture`")

        case .safetyAssessments:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .none,
                          protection: .platformDefault, backupExcluded: false, retention: .none,
                          deleteAll: .unavailable("assessment history is the site record"),
                          deleteSubject: .notSubjectLinked,
                          owner: "SafetyAssessmentStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/SafetyAssessment/SafetyAssessmentStore.swift"],
                          location: "Application Support/SafetyAssessments/history.json")

        case .healthSummaryCache:
            // Derived numbers from Apple Health, kept so a locked phone can still answer. Readable
            // after first unlock on purpose; never backed up.
            return Record(store: self, dataClass: .clinical, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("24-hour TTL per summary, checked on every read"),
                          deleteAll: .api("HealthSummaryCache.clear()"),
                          deleteSubject: .unavailable("holds only the wearer's own numbers; cleared as a whole"),
                          owner: "HealthSummaryCache",
                          ownerPaths: ["OpenGlasses/Sources/Services/HealthSummary/HealthSummaryCache.swift"],
                          location: "Application Support/HealthSummary/summary.json")

        case .clinicalTranscripts:
            // Written at a recording's stop, which can happen while the phone is locked.
            return Record(store: self, dataClass: .clinical, subjectLinkage: .thirdPartySubject,
                          protection: .completeUnlessOpenInComplianceMode, backupExcluded: true,
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

        case .turnTraces:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("14 days, at most 2000 turns"),
                          deleteAll: .api("TurnTraceStore.shared.removeAll()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "TurnTraceStore",
                          ownerPaths: ["OpenGlasses/Sources/Services/Diagnostics/TurnTrace.swift"],
                          location: "Application Support/Diagnostics/turn-traces.json")

        case .diagnosticBreadcrumbs:
            return Record(store: self, dataClass: .operationalAudit, subjectLinkage: .wearer,
                          protection: .completeUntilFirstUserAuthentication, backupExcluded: true,
                          retention: .policy("most recent 500 events; previous run readable for 48 hours"),
                          deleteAll: .api("DiagnosticRing.shared.clear()"),
                          deleteSubject: .notSubjectLinked,
                          owner: "DiagnosticRing",
                          ownerPaths: ["OpenGlasses/Sources/Services/Diagnostics/DiagnosticRing.swift"],
                          location: "Application Support/Diagnostics/last-session.json")

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
