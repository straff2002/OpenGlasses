# FX1 manual assignment contract — draft v1

Other contracts in this folder: [job file](job-file.md) (format 2: an office-assigned identifier
and revision, signed over exact bytes; reference implementation, fixture and the phone's import), [office commissioning](commissioning.md) (scan to join an office),
[office preview](office-preview.md), [recorded session](recorded-session.md),
[team learning](team-learning.md), [managed office folders](office-folders.md),
[office reports](office-reports.md) (messages, reference implementation and fixtures; no app
caller) and [office check-in, renewal and removal](office-check-in.md) (team learning is design only; the
folders carry managed jobs and check-in in the opt-in phone build; check-in has its messages,
key-holder operations and fixtures, the phone's half in that build, and no office app caller).

This is a tested draft and import preflight, not production commissioning or delivery. The
Swift phone verifier and Go implementation agree on the same public, fictional signed vault
fixture. No production trust key, entitlement, manual or queue is present in these fixtures.

An assignment grants a previously commissioned phone permission to receive one immutable vault
archive. It does not make the office a publisher, create a licence, accept a work report or mean
that a vault is installed/indexed. The transport certificate alone does not authorize it.

## Signed bytes

The JSON envelope has two base64 strings, `payload` and `signature`. Ed25519 signs the UTF-8
bytes `Avenkin.ManualAssignment.v1`, one zero byte, then the exact decoded payload bytes. There
is no JSON re-encoding at verification time. Both envelope and payload are closed, flat JSON
objects: duplicate/unknown keys, nested values and fractional/exponent integer spellings are
refused so platform decoders cannot interpret ambiguous input differently. This domain is separate from profiles, jobs,
publisher archives and receipts. Envelopes are capped at 32 KiB before parsing.

| Payload field | Meaning |
| --- | --- |
| `version`, `kind` | Exactly `1`, `avenkin.manual-assignment` |
| `assignmentID` | 32 lowercase hexadecimal characters |
| `organizationID`, `enrolmentID` | Exact intended managed phone |
| `officeID`, `generation` | Exact application authority from verified commissioning |
| `setID`, `sequence` | Stable assigned set and increasing release sequence |
| `issuedAt`, `expiresAt` | Unix UTC seconds; valid at `issuedAt <= now < expiresAt` |
| `vaultID`, `vaultVersion`, `publisherID` | Exact archive and vault identity/version/publisher |
| `archiveSHA256`, `archiveBytes` | Exact immutable ZIP digest and compressed byte length |

Integers are positive and no greater than 2^53 − 1. Identifiers use 1–80 ASCII letters, digits,
dot, underscore or hyphen, excluding `.` and `..`; archive digests are 64 lowercase hexadecimal
characters. The vault version is 1–80 printable ASCII bytes without spaces. A caller's content
byte ceiling is mandatory and cannot be raised by a signed assignment.

Trust is supplied by the caller **after** vendor/administrator-bound commissioning. The assignment
cannot carry its own trusted key. The current app has no production caller for this contract.
Fixtures intentionally inject test trust and do not stand in for that chain.

## Office authority and peer binding in the phone app

The main app now understands an optional schema-2 `officeAuthority` in a vendor-signed organisation
profile: `organizationID`, an Ed25519 `administratorPublicKey`, and `transportPolicy` (`privateLan`
or `automatic`). Legacy schema-1 profiles remain valid for their existing features but cannot
authorize an Avenkin office. A malformed schema-2 authority is refused even with a valid vendor
signature. The profile issuer script emits schema 2 only when this field is present; it never holds
an organisation administrator private key.

An administrator-signed peer-binding envelope uses the same closed, flat JSON and exact-byte
signature rules as the assignment, with domain `Avenkin.OfficePeerBinding.v1` followed by a zero
byte. It names the organisation/profile/enrolment, exact office and phone transport identities,
exact office and phone application public keys, an office generation and a validity interval no
longer than 30 days. The phone derives the administrator verification key only from the
vendor-verified profile and compares peer fields against independently established local and
reviewed identities. A QR code, transport ID or network response cannot substitute its own root.

This remains a **verification contract**, not a functioning delivery flow. The phone now keeps an
Ed25519 application key in device-only Keychain storage, signs fresh possession challenges and
retains the accepted binding generation there with an atomic update. The default main-app build
does not embed the mobile transport. In the opt-in build the binding is rechecked before the
managed folders open (below); successful binding verification alone still does not grant an
entitlement, open a Syncthing share, install a manual or accept a job. The main-app path must also
check the current enrolment, lease, entitlement and administrator approval before sharing data.

An opt-in OpenGlasses build can now link the same pinned mobile engine as Device Lab and obtain
its actual, stable phone transport identity from an app-private certificate. The
`OfficePairingService` composes that identity with the phone's application key, current reviewed
desktop identity, live desktop-managed enrolment, vendor-signed licence/profile pair and
administrator-signed binding. It persists the accepted generation only after all those checks.
The opt-in phone build can display/copy its public pairing details and import the signed binding
for explicit owner approval. The desktop displays its actual public transport and app identities.
It can create a separate, local administrator key and display only its public half for inclusion in
the vendor-signed schema-2 profile. Given that profile and independently copied phone details,
the native helper verifies the vendor signature and the named administrator key before issuing
the exact-byte signed peer binding to a local JSON file. The issuer records increasing generations
per organisation/enrolment. Its office ID is derived from the desktop application public key,
so the binding and displayed office ID cannot diverge through manual entry. Both people must
compare the public identities before approval; the
desktop issuer does not prove phone-key possession by itself. The desktop never receives a vendor
private key and cannot create a qualifying profile or licence. A production transport-share caller
and administrator revocation flow remain; neither a production connection nor main-app job/manual
delivery is claimed.

The phone now retains the exact approved envelope and independently reviewed office IDs in
device-only Keychain storage. Before a LAN connection it re-verifies the vendor profile/licence,
management lease, administrator signature, actual local keys and separate generation high-water.
The first managed connection mode pins the office transport certificate and dials a private LAN
address with **no listener and no shared folders**. The desktop accepts the bound phone identity
after issuing its binding, also without creating a managed folder. This tests a direct handshake;
it cannot transfer a managed job/manual or establish background delivery. Actual phone-to-desktop
connectivity remains to be verified with a signed organisation setup on the physical device.

**Managed office connection.** The phone bridge's `Client.StartManagedOfficeRoute(officeTransportID,
policy, lanHint)` takes its policy only from the vendor-signed profile's
`officeAuthority.transportPolicy`, read again on every connect; the peer binding carries none, and
a QR code, an approval or a typed address cannot widen it. `lanHint` is empty or
`tcp://a.b.c.d:port` on a private IPv4 network (an approval's `officeAddress` with `tcp://` in
front); anything else is refused. Under either policy the phone only dials: no listener, no shared
folder, no introducer or auto-accepted folder, and the engine pins the office transport identity
the binding names. Under `privateLan` the hint is required and is the only address dialled; no
public service is contacted. Under `automatic` the hint is optional and listed first, then the
phone looks the office up in Syncthing's global discovery and dials what it returns, directly or,
as a relay client, through the office's community relay. The phone announces nothing (it has no
listener) and uses no local discovery, NAT mapping or STUN. A lookup shows the discovery server
the phone's IP address and the office ID it asked for; a relay sees both devices' IP addresses and
IDs, timing and byte counts, while the content stays TLS end to end between the pinned identities.
`StartManagedOffice(officeTransportID, address)` is the `privateLan` form. That connection
carries no job or manual.

**Managed folders in the phone app.** In the opt-in build,
`OfficePairingService.openFoldersWithApprovedOffice` calls `StartManagedOfficeFolders` under the
same policy and hint rules. It is the only caller. The binding object it hands over is built from
the approval verified at that moment — vendor profile and licence, live lease, administrator
signature, this phone's actual transport and application keys, and the generation high-water —
and from nothing else. The approval is verified again once the engine has started; if it fails,
or is no longer the same binding under the same policy, the folders are closed. While the app is
open the connection is kept by `OfficeFieldConnection`, which repeats the check every 30 seconds.

**Check-in, renewal and removal in the phone app.** Over those folders, in the same opt-in
build, the phone answers the office's live challenge once, takes the administrator-signed result
through the pairing gate (`OfficePairingService.renew(withResult:waiting:)`: the generation
high-water mark, the saved binding, then the lease from the phone's own clock), and starts the
folders again under the new generation. An administrator-signed removal revokes the enrolment as
a signed revocation does, its receipt is signed and published, and the gate then opens no
further connection ([check-in contract](office-check-in.md)). Tested headless against the golden
fixtures; not yet run on a physical phone against an office.

## Managed job transport reference — draft v1

`manageddelivery.Job` in Go and `OfficeManagedJob` in Swift now verify the same fictional fixture
under the separate `Avenkin.ManagedJob.v1` signature domain. The flat signed payload binds a
message ID, organisation, enrolment, office, binding generation, both transport identities,
sequence, validity window, and exact `.ogjob` SHA-256 and byte count. The verifier's key must come
from the freshly rechecked vendor-rooted administrator binding; the message supplies no trust
key. Both sides reject duplicate/unknown fields, another recipient, expiry, rollback, same-sequence
conflict, or altered job bytes. The phone's existing `JobFileService` must still validate the
`.ogjob` document and show the technician its review. Transport verification is neither job
acceptance nor a delivery receipt.

`manageddelivery.SignPayload` signs exact payload bytes a caller built, for the case where the
office application key is held by one process (the connection helper) on behalf of another (the
desktop). The key holder checks the payload as a verifier would — closed flat object, the field
rules, issued no more than five minutes ahead and not expired — and that it names the office the
key belongs to, then returns the same envelope `Sign` produces for those bytes. Nothing is
re-encoded, so the office's record of a message and what a phone verifies are the same bytes. The
helper exposes it as the one-shot operation `sign-managed-job`; its reply carries the envelope and
no key.

The Go transport takes managed jobs out of the `control` folder, keeps the high-water mark and
commits them. In the opt-in phone build `OfficeManagedJobIntake` then hands each committed job's
exact bytes to `JobFileService` — the same validation, signature rule and review as a file opened
from Mail — and only a job that import would offer is receipted. The default build has none of
this, and no physical-phone run is claimed. The fixture contains public test
keys and a synthetic unsigned `.ogjob`; it cannot satisfy an organisation policy requiring a
separately signed job file. The Device Lab preview signature must not be treated as this contract.

## Managed job receipt — draft v1

A receipt is the phone's signed statement that it **verified one managed job and committed its
exact bytes durably to its own private store**, ready for the technician's review. It is what
lets the office stop holding the job as pending. It is not the technician accepting or starting
the job, and a file finishing its transfer never produces one.

`manageddelivery.Receipt` is a closed, flat payload under its own signature domain,
`Avenkin.ManagedJobReceipt.v1` followed by a zero byte, signed with the **phone application
key** the binding names. The envelope is the same two base64 strings as every other contract
here, capped at 8 KiB.

| Payload field | Meaning |
| --- | --- |
| `version`, `kind` | Exactly `1`, `avenkin.managed-job-receipt` |
| `messageID`, `sequence` | The managed job this answers |
| `organizationID`, `enrolmentID`, `officeID`, `generation` | The binding the job was sent under |
| `phoneTransportID` | The phone's transport identity under that binding |
| `payloadSHA256` | SHA-256 of the signed managed-job payload bytes the phone verified |
| `jobSHA256` | SHA-256 of the job-file bytes it committed |
| `outcome` | `received` — the only outcome in v1 |
| `receivedAt` | Unix UTC seconds on the phone's clock when it committed |

The phone gives a receipt only after `Verify` and `VerifyBytes` pass against the freshly
rechecked binding and the bytes are committed. An exact replay of a committed message gives the
same receipt again. A job the phone refuses gets no receipt in v1; the office sees it as not
received and re-issues.

`VerifyReceipt` is the office's check: closed envelope and payload, the signature over the exact
payload bytes under the phone application key **from the binding, never from the receipt**, the
binding fields, the field rules, and that message id, sequence, payload digest and job digest
are exactly those of the message the office sent — so a receipt for one message cannot complete
another. The office's own clock, not `receivedAt`, records when it accepted the receipt.

The phone application key lives in device-only storage outside the transport, so signing is in
two steps: `ReceiptPayload` gives the exact bytes to sign, and `SealReceipt` wraps them with the
signature. `SignReceipt` does both for a key held in process, which only fixtures, tests and
stand-in phones have.

In the [managed office folders](office-folders.md) the receipt is
`records/receipts/<messageID>.envelope.json`. The golden fixture `managed-job-receipt-v1.json` is
the receipt for `managed-job-v1.json`, signed by a fictional phone key whose public half is in
`managed-job-fixture-keys.json`. The Go transport offers a receipt for each job it commits
(`ManagedJobsPending`, `PublishManagedJobReceipt`). In the opt-in phone build
`OfficeManagedJobIntake` signs it with the phone application key
(`OfficePhoneIdentity.signManagedJobReceipt`, which refuses anything that is not a closed receipt
payload) once the job-file import would offer the job and the offer is recorded; a job file the
import refuses is recorded with a bounded reason and gets none. The phone keeps the signature, so
a job listed again gets the same receipt byte for byte. `OfficeManagedJobReceipt` is the Swift
form of `VerifyReceipt`, checked against the golden fixture in the portable checks. The default
build gives no receipt, and none has been given by a physical phone yet.

## Inline desktop licence and profile

New desktop licence codes retain the existing vendor Ed25519 signature and add two signed,
optional claims: `organizationID` and `profileID`. The issuer takes both through
`--organization-id` and `--profile-id`, refuses partial/unsafe IDs, and refuses combining them with
a hosted `--profile` URL or static activation key. Legacy licences remain readable on their
existing paths; they do not qualify for desktop-managed enrolment.

For an inline Avenkin package, the phone verifies both independent vendor signatures and requires
the licence IDs to match the schema-2 profile's `officeAuthority.organizationID` and `profileId`.
It checks both issue/expiry clocks, rejects a licence with a hosted profile URL, and rejects a
profile embedding a different licence. A display name is never used for this match. The
`OrgEnrolmentService` can stage the verified pair in the existing human profile review without a
network fetch; `OrgProfileManager` repeats the association check at review and apply. The package
alone does **not** complete peer pairing or authorize a transport share. No production transport
caller invokes this ingress yet.

The local hand-off file is a bounded, flat JSON object with exactly `version: 1`,
`profileDocument` and `licenceCode` string fields. The wrapper is unsigned and conveys no trust;
the phone verifies both vendor signatures and their exact ID association after import. Avenkin's
Devices page can package vendor-issued documents in a private local file for transfer through
Files or AirDrop. OpenGlasses Field Assist settings imports the JSON file and opens the existing
owner review sheet. It does not contact a setup site, connect to the desktop or authorize a share.

## Replay and installation boundary

High-water state belongs to the organization/enrolment/set, hashed with zero-delimited fields.
It remains scoped across an authorized office replacement. Within a generation, lower sequences
are refused; the same sequence with different payload bytes is a conflict. An exact replay is
classified separately. An older generation than the retained state is refused, even if the caller
supplies its older trust. A separately authorized newer generation may restart its sequence.

The vault preflight refuses replays until a durable commit lookup exists. This prevents treating
repeat delivery as permission to re-import a manual the technician deliberately removed. The
state value is currently an explicit verifier input, **not yet a durable production store**.

Fresh delivery passes these independent checks:

1. Office signature, recipient, authority, revision, time and content policy.
2. Assignment time checked again after download, then exact ZIP digest and size before extraction.
3. Complete ZIP inflation budget, including header/signature/ignored entries, plus existing
   ZIP entry/CRC checks and vault archive limits.
4. Matching header and vault manifest identity/version, exact declared file bytes, and a valid
   signature from an active publisher supplied by the existing trusted publisher directory.
5. Safe manifest paths and all required configuration, manual text and original files present.

Only then can `OfficeManualImport.Prepared.vaultImportRequest` hand the immutable files and
publisher provenance to the existing `VaultLinkInstaller`. There is no unsigned fallback. The
office assignment does not replace publisher verification or the phone's entitlement/validation
checks. The preflight performs no network calls and writes no files. Run it off the UI thread.

## Checks and fixtures

From the repository root:

```sh
GOMODCACHE="$PWD/Transport/.tools/gomod" GOCACHE="$PWD/Transport/.tools/gocache" \
  go -C Transport/mobile-core test -race -tags noassets ./...
python3 Contracts/tests/test_manual_contracts.py
python3 Contracts/tests/test_inline_entitlement.py
```

The Swift script copies the actual production verification/ZIP/manifest sources unchanged into
an isolated temporary package, and runs the same XCTest cases registered in the app's test
target. It substitutes no signature, archive or ZIP implementation. It tests the portable
boundary on Mac; it does not run the app installer, entitlement gate or document index.
The inline-entitlement runner likewise copies the production licence, profile and office verifier
sources and runs their negative tests. Its only test-only seams replace unrelated app settings and
tier types; signatures and association checks are the production implementations. It does not
exercise the iOS enrolment UI or a Syncthing connection.

`generate-fixture.go` derives fictional test keys from public labels, without production authority.
It deterministically generates the assignment, tiny publisher-signed archive and public-key
metadata. To reproduce those exact public fixtures:

```sh
GOMODCACHE="$PWD/Transport/.tools/gomod" GOCACHE="$PWD/Transport/.tools/gocache" \
  go -C Transport/mobile-core run ../../Contracts/generate-fixture.go
```

Earlier local checks covered the portable Swift tests, Go contract tests, race checks and vet.
The public fixture reproduces byte-for-byte. A signed iPhone 17 Pro simulator run also passed all
19 app test cases, including the `vaultImportRequest` publisher-provenance handoff. The app and
test target compiled. Use normal simulator signing for XCTest; an unsigned attempt launched the
app without loading its test bundle and was cancelled before the successful signed retry.
The CI workflow also runs the portable Swift check on Mac; no remote run is asserted.
The separate portable runner passed nine tests locally on 2026-09-28, including local package
parsing, a foreign pair and a pairing gate that refuses a signed binding for another phone or a
lapsed lease. The pairing test uses the production verification code with in-memory substitutes
for the app manager, transport identity and high-water storage; it does not exercise Keychain or
the engine. The updated iOS app
and test target compiled, but the simulator test host exited without a completed XCTest result on
two attempted destinations; that run is not counted as a pass.

## Next integration gates

- Recheck the vendor-rooted binding, reviewed inline enrolment, actual transport keys and stored
  generation immediately before any production share; add administrator revocation handling.
- Authorize bulk shares only after the assignment and network/content policy pass. Keep the
  mandatory no-export guard active for partial and complete transport staging.
- Add durable high-water/installation state outside removable vault content, per-set serialization,
  crash recovery and exact-replay receipt lookup. Commit it with a verified installation result.
- Preserve the previous usable vault until a replacement is committed; exercise install failures
  and restart recovery. The existing importer needs a stronger update transaction before this
  path is enabled, including receipt/registry failure handling.
- Enforce entitlement at the new installation boundary and index required reference documents;
  report Ready offline only after successful import/index and an independent signed receipt.
- Prove selective downloads, cellular policy, quotas, controls taking priority and physical-device
  installation through the guarded adapter. No new physical-device pass is claimed by these tests.
