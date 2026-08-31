# Plan DL — Medical Secret Storage and Export Lifecycle

**Status:** 🚧 P0 ✅ · P1 ✅ · P2 ✅ · P3 remaining (drafted 2026-08-26)
**Origin:** 2026-08-26 adversarial review findings 3 (High) and 10 (Medium).
**Priority:** P0 for FHIR credentials; P1 before broader medical-export distribution.

This plan treats FHIR credentials and generated clinical files as medical security boundaries, not
ordinary preferences and generic share-sheet attachments. It covers storage, migration, creation,
sharing, cleanup, crash recovery, and tests as one lifecycle.

---

## Problem and verified path

`MedicalExportService` serializes FHIR `bearerToken` and `clientSecret` through `UserDefaults`
(`FHIRConfig` encodes the whole struct — token, secret, endpoint, `patientId`, `practitionerId` — as
one JSON blob under the `fhirConfig` key). Existing tests (`testFHIRConfigPersistence`) explicitly
assert the credential persistence behavior, locking the leak in as expected behavior. The credentials
are secrets; the identifiers are regulated medical data. Neither belongs in an unprotected
preferences blob. Notably, `Config.migrateSecretsToKeychainIfNeeded()` already migrated the
structurally identical `ModelConfig.apiKey` and `GatewayConfig.token` blobs to Keychain —
`fhirConfig` was simply never added to either migration list.
The same service writes TXT, PDF, JSON, and HL7 exports into the general temporary directory without
setting file protection, backup exclusion, a bounded lifetime, or deterministic cleanup after the
share flow — no production code ever deletes what `createExportFile` writes (only tests clean up
after themselves). Clinical data can therefore persist beyond the user's intended action.
`HIPAAComplianceService` already has unit-tested `protectFile(at:)`, `protectDirectory(at:)`, and
`secureDelete(at:)` helpers, but nothing in the export path calls them, and they are gated on the
HIPAA-mode toggle besides.

Relevant seams:

- `OpenGlasses/Sources/Services/MedicalExportService.swift`
- `OpenGlasses/Sources/Services/NativeTools/MedicalExportTool.swift`
- medical-export UI/share call sites
- `OpenGlasses/Sources/Services/HIPAAComplianceService.swift`
- `OpenGlasses/Sources/Utils/Config.swift` Keychain migration precedent
- `OpenGlassesTests/MedicalComplianceTests.swift`

## Security invariants

1. Tokens, client secrets, refresh secrets, and authorization codes never enter `UserDefaults`, logs,
   analytics, diagnostics bundles, filenames, or persisted export metadata.
2. Public connection metadata, secret credentials, and private clinical identifiers have separate
   types and stores so a future `Codable` change cannot accidentally recombine them.
3. Keychain items use a stable service/account namespace, `ThisDeviceOnly`, and an accessibility class
   no weaker than `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
4. A clinical export exists only for an explicit user action, in a dedicated protected session
   directory, until the share consumer completes or a short crash-recovery TTL expires.
5. Network FHIR submission operates on in-memory data and never creates a share file unless the user
   separately asks for one.

---

## P0 — Split configuration and migrate credentials ✅

Shipped as `FHIRServerConfiguration` (preferences), `FHIRCredential` and `FHIRPrivateContext`
(protected storage behind `FHIRCredentialStore`/`FHIRPrivateContextStore`, Keychain-backed by
`KeychainFHIRSecretStore` at `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), coordinated by
`FHIRConfigurationStore`. `baseURL` stayed a `String` rather than a `URL` because it is bound to an
editable text field where empty means "unconfigured"; validated `URL`s are produced by
`endpoint(for:)` at request time.


Create two models and an injected store:

```swift
struct FHIRServerConfiguration: Codable, Equatable {
    var baseURL: URL
    var authMode: FHIRAuthMode
    var clientID: String?
    var platformType: FHIRPlatform
}

struct FHIRCredential: Equatable {
    var bearerToken: String?
    var clientSecret: String?
}

struct FHIRPrivateContext: Equatable {
    var patientID: String?
    var practitionerID: String?
}

protocol FHIRCredentialStore {
    func load(serverID: String) throws -> FHIRCredential?
    func save(_ credential: FHIRCredential, serverID: String) throws
    func delete(serverID: String) throws
}
```

1. Persist only `FHIRServerConfiguration` in preferences. Give a server a stable opaque id so changing
   its URL does not orphan protected values. Store `FHIRCredential` in Keychain and
   `FHIRPrivateContext` in the encrypted medical vault (or a separately namespaced Keychain item until
   that vault exposes a suitable record type).
2. Implement the credential store with Keychain and dependency-inject an in-memory fake for tests.
   Do not expose a “read all secrets” API; load for a single server only at request construction time.
3. Version the migration. On first protected-data-available launch, read legacy values, write both
   protected stores, read back/compare, then remove every legacy preference key and synchronize only
   the public connection config.
4. If Keychain is locked, defer migration and block FHIR sends with an actionable message. If saving or
   verification fails, retain the legacy value only long enough to retry migration, do not use it for
   a network request, and surface a security diagnostic. Never delete the only copy before verification.
5. Clear credentials when a server is deleted, auth mode changes away from secret-based auth, the user
   taps sign out, or medical data reset runs.
6. Replace the settings fields' persisted bindings with transient editor state. After save, show only
   “credential stored” and an explicit Replace/Clear action—not the decrypted token.

**Tests.** Legacy bearer/client-secret and patient/practitioner identifiers migrate then disappear
from `UserDefaults`; locked Keychain
defers and blocks send; failed migration retains recoverability without using the legacy secret;
server deletion clears both protected stores; encoding the public config cannot contain credentials
or clinical identifiers; settings never repopulate a plaintext secret field.

## P1 — Dedicated protected export sessions ✅

Shipped as `MedicalExportFileStore` returning a `MedicalExportLease`. The attribute pass sits
behind `MedicalExportProtecting` so it stays verifiable where the simulator does not report file
protection back, and a completion marker written last is what lets the scavenger tell an abandoned
session from a live one without keeping a ledger of contents.


Add a `MedicalExportFileStore` that returns an opaque `MedicalExportLease`, not a bare URL.

1. Create each action under `Library/Caches/MedicalExports/<random UUID>/`. Set the directory and file
   to `.completeFileProtection`, exclude both from backup, and use generic UUID filenames plus the
   extension. The display name can be supplied to the share UI without becoming the disk filename.
2. Write atomically. Set protection/exclusion immediately on the directory, then on the completed file;
   if any security attribute fails, delete the session directory and fail the export.
3. Restrict permissions/attributes before writing content and validate the final URL remains beneath
   the export root. No caller may provide a path component.
4. Keep FHIR network payloads in memory. For large share exports, stream directly into the protected
   file rather than building multiple plaintext copies in memory and temp storage.
5. Attach metadata in memory only: format, created time, and lease id. Do not persist patient name,
   diagnosis, or export summary in a cleanup ledger.

**Tests.** Every format is created beneath the dedicated root with generic names, complete protection,
and backup exclusion; attribute failure removes partial output; traversal-like display names cannot
escape; FHIR submit creates no file.

## P2 — Share completion, cancellation, and crash cleanup ✅

Shipped as `MedicalExportLeaseCoordinator`, with `ShareSheet` now wiring
`completionWithItemsHandler` and `MedicalExportActivityItem` giving the share UI the display name
while the file keeps its UUID name. Audit events carry an action, a format token, and a count, and
are routed into the existing compliance audit log.

Medical data reset has no control in the app yet, so `revokeAll()` is wired to compliance-mode
enable and exposed for the reset control to call when P3 adds it.


1. Route every share path through one coordinator owning the lease. Wire
   `UIActivityViewController.completionWithItemsHandler` (and SwiftUI equivalent) so success, cancel,
   and provider error all release the lease and remove its directory after the provider finishes.
2. Ensure view dismissal, scene teardown, and an abandoned async task also release. Make cleanup
   idempotent so concurrent completion paths are harmless.
3. On launch and protected-data availability, scavenge only directories under the exact export root.
   Delete incomplete sessions immediately and completed sessions older than a short documented TTL
   (recommended: one hour, solely for crash recovery).
4. On backgrounding, delete every lease not actively owned by an onscreen share controller. On explicit
   medical reset or HIPAA-mode enable, revoke all leases immediately.
5. Add a content-free audit event for created/shared/cancelled/scavenged containing format and counts,
   never file paths or clinical values.

**Tests.** Share success/cancel/error each remove; double-release succeeds; simulated crash leaves a
session scavenged after TTL; fresh active lease survives a concurrent scan; malicious sibling paths
are untouched; background cleanup follows ownership; audit events contain no patient payload.

## P3 — Failure UX and operational verification 🟡

1. Define user-facing errors for credential locked/missing, migration required, protected-file setup
   failure, share unavailable, FHIR rejection, and outcome-unknown network timeout. Do not echo server
   response bodies that may contain PHI.
2. Add a “Clear FHIR credentials and pending exports” control with biometric/device-owner
   authentication when conversation/medical lock policy requires it.
3. Exercise a real share to Files, Mail, and AirDrop on device; verify cleanup after each completion and
   after force-quit. Inspect the app container to confirm no export remains past the TTL.
4. Update privacy/security documentation and the medical settings disclosure with credential and
   export retention behavior.

---

## Rollout, rollback, and exit criteria

P0 must ship as a forward-only migration. A rollback must keep reading the Keychain-backed format and
must not restore preference persistence. P1/P2 may be guarded by a feature flag whose off behavior is
“export unavailable,” not the old general-temp implementation.

Complete when:

- repository and runtime preference scans find no FHIR secret persistence;
- migration is atomic, retryable, and tested for locked/error paths;
- all clinical export formats use protected, no-backup, dedicated session directories;
- every normal share completion deletes its files and launch scavenging covers crashes;
- FHIR network submission leaves no file artifact;
- logs and diagnostics contain neither credentials nor PHI; and
- the full unit suite, Release build, and device share matrix are green.

Use [[DM-privacy-safe-production-logging]] for medical audit/log policy and
[[DJ-composed-tool-safety-and-execution-outcomes]] for FHIR timeout outcome semantics.
