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
    case organizationDisplayName
    case organizationJobSigningKey
    case organizationJobReportChannel
    case organizationReportRecipients

    // Organisation policy — tighten only.
    case organizationAllowsUnsignedVaults
    case organizationRequiresSignedJobFiles
    case organizationRequiresCustomerSignOff

    // Capability ceilings — tighten only.
    case privacyFilterEnabled
    case remoteInvokeObserveEnabled
    case remoteInvokeOutputEnabled
    case remoteInvokeCaptureEnabled
    case mcpServerEnabled
    case agentModeEnabled

    // Starting values the person may change.
    case fieldAssistEnabled
    case fieldAssistDefaultVaultId
    case fieldAssistDefaultMode

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
        /// A starting value, written once, that the person may change afterwards.
        case startingValue(ValueType)
    }

    var kind: Kind {
        switch self {
        case .organizationDisplayName, .organizationJobSigningKey, .organizationJobReportChannel:
            return .profileOwned(.string)
        case .organizationReportRecipients:
            return .profileOwned(.strings)
        case .organizationAllowsUnsignedVaults:
            return .ceiling(pinnedTo: false)
        case .organizationRequiresSignedJobFiles, .organizationRequiresCustomerSignOff,
             .privacyFilterEnabled:
            return .ceiling(pinnedTo: true)
        case .remoteInvokeObserveEnabled, .remoteInvokeOutputEnabled, .remoteInvokeCaptureEnabled,
             .mcpServerEnabled, .agentModeEnabled:
            return .ceiling(pinnedTo: false)
        case .fieldAssistEnabled:
            return .startingValue(.bool)
        case .fieldAssistDefaultVaultId, .fieldAssistDefaultMode:
            return .startingValue(.string)
        }
    }

    /// Why a value of the right type is still refused, or nil when it is acceptable. Type and
    /// direction are checked by the applier; this is the per-key content check.
    func contentProblem(_ value: ProfileValue, resolvableVaultIds: Set<String>) -> String? {
        switch (self, value) {
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
        case (.organizationReportRecipients, .strings(let recipients)):
            if recipients.isEmpty { return "no recipients" }
            if recipients.count > 20 { return "more than 20 recipients" }
            let bad = recipients.contains { recipient in
                recipient.isEmpty || recipient.count > 254
                    || recipient.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            }
            return bad ? "a recipient is empty, too long, or contains whitespace" : nil
        case (.fieldAssistDefaultVaultId, .string(let id)):
            return resolvableVaultIds.contains(id) ? nil : "no vault with that id is installed"
        case (.fieldAssistDefaultMode, .string(let raw)):
            return FieldSession.Mode(rawValue: raw) == nil ? "not a Field Assist mode" : nil
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
