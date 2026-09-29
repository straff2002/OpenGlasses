# Plan FX — Phone connection to Avenkin Office

**Status:** 🚧 Phone foundations, 2026-09-29. The public app has vendor-rooted inline office
setup, reviewed peer binding, a transport identity, and verification contracts for signed manual
assignments and managed jobs. The Go phone transport and its Syncthing source extension live in
[`Transport/`](../../Transport/); shared schemas and fictional fixtures live in
[`Contracts/`](../../Contracts/). A local managed LAN handshake has passed with zero folders.
Physical main-app pairing, durable job/manual import over that connection, exact receipts and
background/route-change behaviour still require implementation and testing. The Avenkin Office
desktop implementation and lab evidence are maintained in its private repository.

## Product boundary

The organisation runs **Avenkin Office** on a Mac or Windows computer. The phone app will be
named **Avenkin** separately; existing identifiers, URL schemes, licence fields and `.ogjob`
remain unchanged until that rename is reviewed. The office keeps organisation data locally.
No vendor-hosted application server or paid hosting account is required. Direct connections are
preferred; an encrypted relay may carry traffic when direct routing fails. A relay is not an
offline inbox: both devices need connectivity and execution time to exchange queued work.

This plan supersedes FT/FU's hosted `baseServer`, URL-bound setup and HTTP delivery assumptions
for the phone. It retains their requirements for vendor authority, organisation approval,
least-privilege jobs, manual provenance, revocation, reporting and technician consent. Plan T's
offline queue remains necessary when either endpoint is unavailable.

## Phone enrolment and pairing

1. Accept a vendor-signed organisation profile and matching vendor-signed office licence in a
   local setup package. Match stable organisation/profile IDs before the user reviews it; the
   package itself grants no trust. Existing phone entitlements remain valid.
2. Keep the phone application signing key and transport identity in device-only private storage.
   Display the actual identity during approval, rather than accepting a value supplied by the
   office or UI. Never copy transport credentials into a manual or job share.
3. Verify an administrator-signed binding to one office, one enrolment, the phone's own transport
   and application keys, office keys, a generation and validity window. Require explicit review.
   Persist the accepted generation and reject an older or conflicting replacement.
4. Recheck current profile, licence and saved binding immediately before starting a managed
   transport connection or enabling any content share. A local address is a route hint, not
   authority. Replacement and revocation need a separately reviewed flow.

The current phone UI and services implement setup, binding review and a handshake-only managed
connection. No production managed folder is enabled by that handshake. The earlier standalone
Device Lab pairing is a separate feasibility protocol, not a substitute for vendor authority.

## Messages, manuals and receipts

The [public contracts](../../Contracts/README.md) define closed, signed schemas for assignments
and jobs. Verification binds the message to the organisation, office, enrolment and exact phone
identity; rejects duplicate or unknown fields, stale times, bad signatures and conflicting
sequences; and checks declared lengths and SHA-256 digests before using bytes. Fixture keys are
fictional and have no production authority.

A manual assignment authorises a particular publisher vault archive, but does not replace its
independent publisher signature. The phone must validate archive structure, paths, byte budgets,
publisher trust and every file before installing it in private storage. The original PDF remains
available offline. Searchable text is an aid: OCR and flowchart interpretation cannot guarantee
complete or correct transcription, so the original page remains the source of truth.

A job is received only after its authenticated payload and attachments are committed durably to
the phone's private store. The phone then signs an application receipt for the exact message ID,
sequence and digest. Transport file completion alone must not mark a job accepted or completed.
Technician acknowledgement and work status are separate business events. The office must retain
pending work until it verifies the phone's exact receipt; replay of an already committed message
must remain safe.

The embedded Syncthing wrapper has a mandatory outbound request guard. Receive-only folders do
not prevent a peer from requesting local manual bytes. Until a reviewed production allowlist is
implemented, the phone may serve only the explicitly allowed synthetic receipt in the lab.
Partial staging, unknown folders and manual paths must fail closed. The modified upstream file,
MPL-2.0 notices and exact source pin are public in `Transport/`.

## Offline and connection behaviour

The phone retains queued work while Avenkin Office is off, asleep, unreachable or behind a
failed relay. Reconnect must preserve ordering and exact-once application effects across Stop,
relaunch and route changes. The UI must distinguish local draft, transfer in progress, verified
receipt, technician acknowledgement and later completion. A bounded retry policy should not
consume attempts merely because the office is unavailable. Bulk manuals must not starve small
jobs or receipts; transfer limits and network policy remain to be specified and tested.

Foreground physical Device Lab experiments demonstrated LAN, cellular direct and relay paths,
restart recovery, offline manuals and signed preview receipts. Those observations do not prove
iOS background execution, screen-lock recovery or the main app's production importer. The next
phone milestone is a physical main-app pairing followed by one signed job and one signed manual,
with an exact receipt after local byte verification and an offline reopen test.

## Public acceptance gates

- Portable Swift and Go contract tests, including malformed input, foreign binding, replay and
  publisher-vault refusal, pass against shared `Contracts/` fixtures.
- The embedded iOS transport builds from `Transport/` with the pinned source extension and the
  published MPL-2.0 notices; an unguarded engine build fails.
- A Release phone build succeeds without regenerating localization strings on throwaway builds.
- Physical-device tests prove explicit approval, direct and relay delivery, Stop/relaunch,
  screen-lock recovery, failed relay, route change, manual no-export and exact receipt handling.

The private desktop plan owns office UI, persistence, packaging, add-on licensing design and
desktop operations. This public plan owns the phone behaviour and the shared wire contract.
