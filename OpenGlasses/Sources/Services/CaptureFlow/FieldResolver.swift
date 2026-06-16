import Foundation

/// Decides whether a capture flow authored for one pack can run under another (Plan U). This is
/// qaeros's *field binding* idea reduced to "shared field names across packs": a flow runs in a
/// vault when it declares it `appliesTo` that vault (or declares nothing, i.e. universal) and the
/// fields it captures exist in the vault's known field set. Pure and deterministic.
enum FieldResolver {

    enum Resolution: Equatable {
        case runnable
        case notApplicable(vault: String)          // flow doesn't apply to this vault
        case missingFields([String])               // applies, but the vault lacks bound fields
    }

    /// `knownFields` is the set of field names a vault understands (empty ⇒ no constraint, any
    /// flow that applies can run — useful before per-vault field catalogues exist).
    static func resolve(_ flow: CaptureFlow, vaultId: String, knownFields: Set<String>) -> Resolution {
        if !flow.appliesTo.isEmpty, !flow.appliesTo.contains(vaultId) {
            return .notApplicable(vault: vaultId)
        }
        if !knownFields.isEmpty {
            let missing = flow.fieldNames.subtracting(knownFields).sorted()
            if !missing.isEmpty { return .missingFields(missing) }
        }
        return .runnable
    }

    static func canRun(_ flow: CaptureFlow, vaultId: String, knownFields: Set<String> = []) -> Bool {
        resolve(flow, vaultId: vaultId, knownFields: knownFields) == .runnable
    }
}
