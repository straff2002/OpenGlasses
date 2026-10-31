import Foundation
import CryptoKit

/// Plan CT P1 — the settings an organisation profile may touch. An explicit allow-list, never a
/// passthrough onto `UserDefaults`: a scanned code must not become a write primitive for every
/// value the app stores, and a secret must be structurally impossible to put in a photograph (the
/// disjointness with `Config`'s secret inventories is asserted by a test).
///
/// Each raw value is the `UserDefaults` key the setting already lives at. **Each case declares the
/// one way it may move** (`kind`), so a profile that tries to move a key the other way — pin the
/// privacy filter off, turn a refusal back into an allowance — is a named drop, not a write. That
/// is the pin-on-only rule this plan applies to the assistive surface, generalised.
///
/// The first cut is the seven organisation stand-ins Plans FO and FS shipped in CT's name, a few
/// capability ceilings, and the Field Assist selection. Adding a key is one case and its `kind`.
enum SettingKey: String, CaseIterable, Codable, Sendable {
    // Organisation identity — written only by a profile.
    case organizationFieldServiceRoute
    case workizEnabled
    case workizReportFieldName
    case workizClientNotes
    case organizationDisplayName
    case organizationJobSigningKey
    case organizationJobReportChannel
    case organizationReportRecipients
    /// Transcripts in reports to the office: `always` or `never` (Plan HD).
    case organizationReportTranscriptInternal
    case capturedManualsPolicy
    /// The organisation's accent, locked: every screen takes it and the picker is read-only.
    /// To offer a colour the technician may change, the profile sets `accentColorName` instead.
    case organizationAccentColor
    /// The technician's name as their team sees it (Plan FP P3), on a phone the organisation
    /// enrols per person. Set and locked by the profile; the technician sets it otherwise.
    case technicianFullName
    case technicianID
    case technicianDisplayName
    /// When tool definitions go on demand (Plan IU): `automatic`, `always` or `never`. Set and
    /// locked by the profile — the Settings row is then not the technician's to change.
    case organizationToolDefinitionsMode

    // Organisation policy — tighten only.
    case organizationAllowsUnsignedVaults
    case organizationRequiresSignedJobFiles
    case organizationRequiresCustomerSignOff
    /// Only the office addresses the organisation set up may receive a transcript (Plan HD).
    case organizationForbidsCustomerTranscript
    /// "Record this job" is not offered on this organisation's phones (Plan HE).
    case organizationForbidsJobRecording
    /// The technician's own van stock (Plan IH) is off: no `van_stock`, no Van Stock screen.
    case organizationForbidsVanStock
    /// A recorded job's faces must be blurred before it goes to the office. Until the app can
    /// blur a recording, this means no job is recorded at all — never one sent unblurred.
    case organizationRequiresBlurBeforeOfficeSync
    /// A recorded job is never sent over mobile data, whatever the technician would allow.
    case organizationForbidsRecordingSyncOnCellular
    /// A table read from a picture of a manual gives no value until it has been checked against
    /// its page (Plan JN P3). Checking is optional otherwise.
    case organizationRequiresTableChecks

    // Capability ceilings — tighten only.
    case privacyFilterEnabled
    case remoteInvokeObserveEnabled
    case remoteInvokeOutputEnabled
    case remoteInvokeCaptureEnabled
    case mcpServerEnabled
    case agentModeEnabled
    /// Face recognition (Plan HP P1 item 2): an organisation may switch it off on its phones, never
    /// on — enrolling a bystander's face is the wearer's choice, not an employer's.
    case faceRecognitionEnabled
    /// The spoken interpreter: a bystander's voice goes to the cloud. An organisation may switch it
    /// off on its phones, never on.
    case interpreterEnabled
    /// The "Connecting to Avenkin AI" line at voice startup (Plan HP P2 item 10): an organisation
    /// may make sure it is always said, never silence it — it is the disclosure that the person is
    /// talking to an AI.
    case aiConnectionCueEnabled
    /// This phone may approve team learnings (Plan FP P2). An organisation may pin it off — a field
    /// phone that never approves — and never on from here: naming the reviewer in a signed profile
    /// is an open decision (FP open question 1).
    case teamLearningReviewerDevice
    /// Dictation through a cloud recogniser the wearer chose (Plan JM P2): an organisation may pin
    /// it off, so a company that has not approved the vendor holds dictation to the phone, and
    /// never on — sending the wearer's voice to a vendor is the wearer's choice.
    case cloudDictationEnabled

    // Starting values the person may change.
    case fieldAssistEnabled
    case fieldAssistDefaultVaultId
    case fieldAssistDefaultMode
    /// Pilot reporting is a starting preference, never a ceiling or a locked value.
    case pilotReportsEnabled
    case pilotReportRecipients
    case supportReportEmail
    /// The accent colour the phone starts with; the technician may pick another afterwards.
    case accentColorName
    /// The units refrigeration answers start in (Plan IS P1), written `pressure,temperature,mass`
    /// (`"kPa,C,kg"`). Without one the phone follows its App Store region; the technician may
    /// change it either way.
    case refrigerationUnits
    /// The trades Field Assist starts with (`refrigeration_hvac`, `electrical`), each bringing its
    /// tiles to the grid. Its own key: the technician's choice (`fieldAssistTrades`) outranks it
    /// rather than overwriting it, and without either the default vault's manifest decides.
    case fieldAssistDefaultTrades

    enum ValueType: Equatable, Sendable {
        case bool
        case string
        case strings
    }

    enum Kind: Equatable, Sendable {
        /// Organisation identity rather than a preference: there is no user surface to override
        /// it, and removing the profile clears it. The disposition in the profile is not consulted.
        case profileOwned(ValueType)
        /// A ceiling that may only pin the flag to this value — never away from it.
        case ceiling(pinnedTo: Bool)
        case stringCeiling(pinnedTo: String)
        /// A starting value, written once, that the person may change afterwards.
        case startingValue(ValueType)
    }

    var kind: Kind {
        switch self {
        case .organizationFieldServiceRoute: return .stringCeiling(pinnedTo: "office")
        case .workizEnabled, .workizClientNotes: return .profileOwned(.bool)
        case .workizReportFieldName: return .profileOwned(.string)
        case .organizationDisplayName, .organizationJobSigningKey, .organizationJobReportChannel,
             .organizationReportTranscriptInternal, .organizationAccentColor, .technicianDisplayName, .capturedManualsPolicy,
             .organizationToolDefinitionsMode, .technicianFullName, .technicianID:
            return .profileOwned(.string)
        case .organizationReportRecipients:
            return .profileOwned(.strings)
        case .organizationAllowsUnsignedVaults:
            return .ceiling(pinnedTo: false)
        case .organizationRequiresSignedJobFiles, .organizationRequiresCustomerSignOff,
             .organizationForbidsCustomerTranscript, .organizationForbidsJobRecording,
             .organizationForbidsVanStock,
             .organizationRequiresBlurBeforeOfficeSync, .organizationForbidsRecordingSyncOnCellular,
             .organizationRequiresTableChecks,
             .privacyFilterEnabled, .aiConnectionCueEnabled:
            return .ceiling(pinnedTo: true)
        case .remoteInvokeObserveEnabled, .remoteInvokeOutputEnabled, .remoteInvokeCaptureEnabled,
             .mcpServerEnabled, .agentModeEnabled, .faceRecognitionEnabled, .teamLearningReviewerDevice,
             .cloudDictationEnabled, .interpreterEnabled:
            return .ceiling(pinnedTo: false)
        case .pilotReportRecipients:
            return .startingValue(.strings)
        case .pilotReportsEnabled, .fieldAssistEnabled:
            return .startingValue(.bool)
        case .fieldAssistDefaultVaultId, .fieldAssistDefaultMode, .supportReportEmail, .accentColorName,
             .refrigerationUnits:
            return .startingValue(.string)
        case .fieldAssistDefaultTrades:
            return .startingValue(.strings)
        }
    }

    /// Why a value of the right type is still refused, or nil when it is acceptable. Type and
    /// direction are checked by the applier; this is the per-key content check.
    func contentProblem(_ value: ProfileValue, resolvableVaultIds: Set<String>) -> String? {
        switch (self, value) {
        case (.workizReportFieldName, .string(let name)):
            return name.isEmpty || name.count > 120 || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "provide a report field name of at most 120 printable characters" : nil
        case (.organizationDisplayName, .string(let name)):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "the organisation name is empty" }
            if trimmed.count > 120 { return "the organisation name is longer than 120 characters" }
            return nil
        case (.organizationJobSigningKey, .string(let key)):
            guard let data = Data(base64Encoded: key), data.count == 32,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil else {
                return "not a Curve25519 public key"
            }
            return nil
        case (.organizationJobReportChannel, .string(let raw)):
            return DeliveryChannel(rawValue: raw) == nil ? "not a delivery channel this build knows" : nil
        case (.organizationToolDefinitionsMode, .string(let raw)):
            // Deny by default: a mode this build does not know is a named drop, never a guess.
            return ToolDefinitionsMode(rawValue: raw) == nil ? "not one of automatic, always or never" : nil
        case (.capturedManualsPolicy, .string(let raw)):
            return ["off", "jobOnly", "reviewToPool"].contains(raw) ? nil : "not a photographed-manual policy"
        case (.organizationReportTranscriptInternal, .string(let raw)):
            // Deny by default: a value this build does not know is a named drop, never a guess.
            return ReportTranscriptPolicy.InternalRule(rawValue: raw) == nil
                ? "not one of always or never" : nil
        case (.organizationReportRecipients, .strings(let recipients)):
            if recipients.isEmpty { return "no recipients" }
            if recipients.count > 20 { return "more than 20 recipients" }
            let bad = recipients.contains { recipient in
                recipient.isEmpty || recipient.count > 254
                    || recipient.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            }
            return bad ? "a recipient is empty, too long, or contains whitespace" : nil
        case (.pilotReportRecipients, .strings(let addresses)):
            return PilotReportRecipients.validated(addresses) == nil ? "provide one to three email addresses" : nil
        case (.technicianID, .string(let value)):
            return value == TechnicianID.clean(value) && !value.isEmpty ? nil : "provide a printable technician ID of at most 40 characters"
        case (.technicianDisplayName, .string(let name)), (.technicianFullName, .string(let name)):
            // The contract's author rule: plain text, 1–120 characters once trimmed.
            if name.unicodeScalars.contains(where: LearningCandidateText.isRefused) {
                return "the name contains a control character"
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "the name is empty" }
            if LearningCandidateText.length(trimmed) > TechnicianName.limit {
                return "the name is longer than \(TechnicianName.limit) characters"
            }
            return nil
        case (.fieldAssistDefaultVaultId, .string(let id)):
            return resolvableVaultIds.contains(id) ? nil : "no vault with that id is installed"
        case (.fieldAssistDefaultMode, .string(let raw)):
            return FieldSession.Mode(rawValue: raw) == nil ? "not a Field Assist mode" : nil
        case (.supportReportEmail, .string(let address)):
            return SupportReportRecipient.isPlausible(address.trimmingCharacters(in: .whitespacesAndNewlines))
                ? nil : "not an email address"
        case (.organizationAccentColor, .string(let colour)), (.accentColorName, .string(let colour)):
            // A profile names a colour, never one of this build's presets: preset ids are an
            // app detail that may change, and a hex code means the same thing on every build.
            return AppAccent.hexValue(colour) == nil ? "not a colour written as #RRGGBB" : nil
        case (.refrigerationUnits, .string(let raw)):
            // Deny by default: units this build cannot read are a named drop, never a guess.
            return RefrigerationUnits(encoded: raw) == nil
                ? "not units written as pressure,temperature,mass (for example kPa,C,kg)" : nil
        case (.fieldAssistDefaultTrades, .strings(let trades)):
            // An empty list is a choice: no trade tiles. A list this build reads none of is a
            // named drop; a list naming some trades it knows keeps them and ignores the rest, so a
            // profile written for a newer build still gives this one what it understands.
            if trades.count > 20 { return "more than 20 trades" }
            if !trades.isEmpty && FieldTrade.known(trades).isEmpty {
                return "names no trade this version knows ("
                    + FieldTrade.allCases.map(\.rawValue).joined(separator: ", ") + ")"
            }
            return nil
        default:
            return nil
        }
    }
}

extension ProfileValue {
    var valueType: SettingKey.ValueType {
        switch self {
        case .bool: return .bool
        case .string: return .string
        case .strings: return .strings
        }
    }
}
