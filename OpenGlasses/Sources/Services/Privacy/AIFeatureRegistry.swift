import Foundation

/// W08.1 / W08.5 — the AI feature inventory, as code rather than a document.
///
/// The roadmap asks for an inventory of every AI feature, screened for the sensitive categories that
/// carry legal duties, each with a way to switch it off and an honest statement of what stays on
/// disk when it is off. The same argument that made `DataStoreRegistry` code applies here: a table in
/// a plan is accurate on the day it is written and wrong the first time somebody adds a tool.
/// `AIFeatureRegistryTests` checks this one — every feature registered, every switch resolvable,
/// every tool name real, and the erase claim exercised against the actual store.
///
/// Two things this registry deliberately is *not*. It is not a classification: whether a feature is
/// high-risk under a given regulation in a given market is a legal determination with a named owner,
/// and this file records the facts that determination needs, not its outcome. And it is not an
/// authorisation policy: `ToolAuthorizationPolicy` decides whether a *call* is allowed; this decides
/// whether a *feature* exists at all.
enum AIFeature: String, CaseIterable {

    // Biometric
    case faceRecognition
    case speakerIdentification

    // Health
    case healthVault
    case medicationIdentifier
    case healthSafetyAdvisor
    case firstAidAssist
    case fitnessCoaching

    // Worker safety
    case safetyAssessment
    case fieldAssist

    // External actuation
    case smartHomeControl
    case messaging
    case remoteInvoke

    // Neither, but AI and worth inventorying
    case ambientCaptions

    // MARK: - Facets

    /// The categories that attract specific duties. A feature may sit in more than one; `none` is a
    /// positive statement that it was screened and sits in none, not that nobody looked.
    enum SensitiveCategory: String, CaseIterable {
        /// Identifies or categorises a person from a body characteristic — a face, a voice.
        case biometric
        /// Reads, infers or writes health information.
        case health
        /// Informs a decision about the safety of a worker at a workplace.
        case workerSafety
        /// Acts on the physical or social world outside the app — a lock, a light, a message sent
        /// under the wearer's name.
        case externalActuation
        case none
    }

    /// How a release disables the feature: the preferences key, and the accessor pair that reads and
    /// writes it. Named rather than closed over so a test can assert the key exists and round-trips.
    struct Switch {
        let key: String
        let isEnabled: () -> Bool
        let setEnabled: (Bool) -> Void
        /// True when the feature already had its own switch before the inventory existed. Recorded
        /// so nobody adds a second switch over the same feature.
        let preexisting: Bool
    }

    struct Record {
        let feature: AIFeature
        let title: String
        let sensitiveCategories: [SensitiveCategory]
        let disableSwitch: Switch
        /// The native tools this feature reaches the model through. Empty for a feature with no tool
        /// surface. Used by `AIFeatureGate.disabledToolNames`.
        let toolNames: [String]
        /// The stores this feature writes into, if any.
        let stores: [SensitiveStore]
        /// What is still on the device after the switch goes off — in words, honestly. "Nothing" is
        /// only written where nothing is true.
        let dataRetainedWhenDisabled: String
        /// What erases that data, or why nothing does.
        let erasure: SensitiveStore.Deletion
    }

    // MARK: - The inventory

    var record: Record {
        switch self {

        case .faceRecognition:
            return Record(feature: self, title: "Face recognition",
                          sensitiveCategories: [.biometric],
                          disableSwitch: Switch(key: "faceRecognitionEnabled",
                                                isEnabled: { Config.faceRecognitionEnabled },
                                                setEnabled: { Config.faceRecognitionEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["face_recognition"],
                          stores: [.faces],
                          dataRetainedWhenDisabled: "Face embeddings and the names attached to them stay in the known-faces file until they are erased; turning the feature off stops new matching and new enrolment, it does not delete what was already learned.",
                          erasure: .api("FaceRecognitionService.forgetAllFaces()"))

        case .speakerIdentification:
            return Record(feature: self, title: "Speaker identification",
                          sensitiveCategories: [.biometric],
                          disableSwitch: Switch(key: "diarizationEnabled",
                                                isEnabled: { Config.diarizationEnabled },
                                                setEnabled: { Config.diarizationEnabled = $0 },
                                                preexisting: true),
                          toolNames: [],
                          stores: [.speakerNames],
                          dataRetainedWhenDisabled: "Names the wearer attached to voice clusters stay in preferences; they are cleared one speaker at a time.",
                          erasure: .api("SpeakerRegistry.setName(nil, for:)"))

        case .healthVault:
            return Record(feature: self, title: "Health vault access",
                          sensitiveCategories: [.health],
                          disableSwitch: Switch(key: "healthVaultAIEnabled",
                                                isEnabled: { Config.healthVaultAIEnabled },
                                                setEnabled: { Config.healthVaultAIEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["health_vault"],
                          stores: [.vaultDocuments],
                          dataRetainedWhenDisabled: "The vault's own contents — the wearer authored them and they are not a by-product of the AI feature. Disabling stops the model reading them.",
                          erasure: .unavailable("vaults are removed individually by identity"))

        case .medicationIdentifier:
            return Record(feature: self, title: "Medication identifier",
                          sensitiveCategories: [.health],
                          disableSwitch: Switch(key: "medicationIdentifierEnabled",
                                                isEnabled: { Config.medicationIdentifierEnabled },
                                                setEnabled: { Config.medicationIdentifierEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["identify_medication"],
                          stores: [],
                          dataRetainedWhenDisabled: "Nothing. The identification is answered and not stored; the frame is not retained.",
                          erasure: .notSubjectLinked)

        case .healthSafetyAdvisor:
            return Record(feature: self, title: "Health safety advisor",
                          sensitiveCategories: [.health],
                          disableSwitch: Switch(key: "healthSafetyAdvisorEnabled",
                                                isEnabled: { Config.healthSafetyAdvisorEnabled },
                                                setEnabled: { Config.healthSafetyAdvisorEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["health_check"],
                          stores: [],
                          dataRetainedWhenDisabled: "Nothing of its own. It reads the health vault, which has its own switch and its own erasure.",
                          erasure: .notSubjectLinked)

        case .firstAidAssist:
            return Record(feature: self, title: "First-aid coaching and triage",
                          sensitiveCategories: [.health],
                          disableSwitch: Switch(key: "firstAidAssistEnabled",
                                                isEnabled: { Config.firstAidAssistEnabled },
                                                setEnabled: { Config.firstAidAssistEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["first_aid"],
                          stores: [],
                          dataRetainedWhenDisabled: "Nothing. Triage cards are in memory for the session and are not written to disk.",
                          erasure: .notSubjectLinked)

        case .fitnessCoaching:
            return Record(feature: self, title: "Fitness coaching",
                          sensitiveCategories: [.health],
                          disableSwitch: Switch(key: "fitnessCoachingEnabled",
                                                isEnabled: { Config.fitnessCoachingEnabled },
                                                setEnabled: { Config.fitnessCoachingEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["fitness_coach"],
                          stores: [],
                          dataRetainedWhenDisabled: "Workouts already written to Apple Health stay there — they are the wearer's health record, held by the operating system, and this app cannot and should not silently remove them.",
                          erasure: .unavailable("workouts belong to Apple Health; the wearer deletes them there"))

        case .safetyAssessment:
            return Record(feature: self, title: "Safety assessment",
                          sensitiveCategories: [.workerSafety],
                          disableSwitch: Switch(key: "safetyAssessmentEnabled",
                                                isEnabled: { Config.safetyAssessmentEnabled },
                                                setEnabled: { Config.safetyAssessmentEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["safety_assessment"],
                          stores: [.safetyAssessments],
                          dataRetainedWhenDisabled: "Assessment history stays: it is the site record, and a worksite assessment is kept deliberately rather than swept.",
                          erasure: .unavailable("assessment history is the site record"))

        case .fieldAssist:
            return Record(feature: self, title: "Field Assist sessions",
                          sensitiveCategories: [.workerSafety],
                          disableSwitch: Switch(key: "fieldAssistToolsEnabled",
                                                isEnabled: { Config.fieldAssistToolsEnabled },
                                                setEnabled: { Config.fieldAssistToolsEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["field_session"],
                          stores: [.fieldSessionLogs],
                          dataRetainedWhenDisabled: "Session logs stay: they are the engineer's own compliance record, and a warranty or refrigerant log that vanished with a settings toggle would be worse than one that stayed.",
                          erasure: .unavailable("a session log is the engineer's compliance record"))

        case .smartHomeControl:
            return Record(feature: self, title: "Smart home control",
                          sensitiveCategories: [.externalActuation],
                          disableSwitch: Switch(key: "smartHomeControlEnabled",
                                                isEnabled: { Config.smartHomeControlEnabled },
                                                setEnabled: { Config.smartHomeControlEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["smart_home", "home_assistant"],
                          stores: [],
                          dataRetainedWhenDisabled: "Nothing. Home state belongs to HomeKit or the Home Assistant instance, not to this app.",
                          erasure: .notSubjectLinked)

        case .messaging:
            return Record(feature: self, title: "Messaging and email",
                          sensitiveCategories: [.externalActuation],
                          disableSwitch: Switch(key: "aiMessagingEnabled",
                                                isEnabled: { Config.aiMessagingEnabled },
                                                setEnabled: { Config.aiMessagingEnabled = $0 },
                                                preexisting: false),
                          toolNames: ["send_message", "send_via", "asian_messaging"],
                          stores: [],
                          dataRetainedWhenDisabled: "Nothing here. A message already sent lives in the messaging app it was sent from.",
                          erasure: .notSubjectLinked)

        case .remoteInvoke:
            return Record(feature: self, title: "Remote invocation",
                          sensitiveCategories: [.externalActuation],
                          disableSwitch: Switch(key: "agentModeEnabled",
                                                isEnabled: { Config.agentModeEnabled },
                                                setEnabled: { Config.setAgentModeEnabled($0) },
                                                preexisting: true),
                          toolNames: [],
                          stores: [.remoteInvokeAudit],
                          dataRetainedWhenDisabled: "The remote-invoke audit log stays, deliberately: the record of what was invoked outlives permission to invoke.",
                          erasure: .unavailable("the trail is what makes remote invocation reviewable"))

        case .ambientCaptions:
            return Record(feature: self, title: "Ambient captions",
                          sensitiveCategories: [.none],
                          disableSwitch: Switch(key: "ambientCaptionsEnabled",
                                                isEnabled: { Config.ambientCaptionsEnabled },
                                                setEnabled: { Config.ambientCaptionsEnabled = $0 },
                                                preexisting: false),
                          toolNames: [],
                          stores: [],
                          dataRetainedWhenDisabled: "Nothing. Captions are held for the session and are not written to disk.",
                          erasure: .notSubjectLinked)
        }
    }
}

/// Reads the inventory's switches at each feature's entry point (W08.5).
///
/// Deliberately trivial. The value is not in the logic, it is in there being one place every entry
/// point asks, so "can this release turn that off?" has an answer that is checked rather than
/// remembered.
enum AIFeatureGate {

    static func isEnabled(_ feature: AIFeature) -> Bool {
        feature.record.disableSwitch.isEnabled()
    }

    /// The refusal a disabled feature's tool returns. Says which switch, so the wearer can find it.
    static func disabledMessage(_ feature: AIFeature) -> String {
        String(localized: "\(feature.record.title) is turned off in Settings. Turn it back on to use this.")
    }

    /// Every tool name belonging to a currently disabled feature.
    ///
    /// The tools of features owned by other in-flight work — the router itself among them — cannot
    /// take an inline gate without colliding, so the router will consult this set by name once those
    /// land. Until then this is the inventory's answer to "which tools should not be callable", and
    /// the features whose tools this branch does own gate themselves inline as well.
    static var disabledToolNames: Set<String> {
        Set(AIFeature.allCases
            .filter { !isEnabled($0) }
            .flatMap { $0.record.toolNames })
    }

    /// Whether a tool call should be refused because its feature is off. What the router will call.
    static func isToolDisabled(_ name: String) -> Bool {
        disabledToolNames.contains(name)
    }
}
