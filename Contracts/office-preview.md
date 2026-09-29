# Avenkin Office / Device Lab delivery preview v1

Development contract, 2026-09-27. This separate companion protocol grants no vendor,
organisation, publisher, subscription or production OpenGlasses authority. FX1 manual
assignment and the existing signed organisation profiles remain separate contracts.

## Pairing and identity

The office saves an Ed25519 application seed alongside its private transport home; the phone
saves its own application seed in its private app container. Transport certificates and API
credentials remain native. A lost seed with saved connection state refuses silent replacement.

An office invitation binds its application public key, transport fingerprint, private LAN TCP
address, device record, random 128-bit pair ID and a 15-minute validity window. The phone response
proves possession of its application key and binds its transport fingerprint to the exact
invitation digest. Compare all four groups of eight hexadecimal characters on both ends before
approval. The office consumes the invitation once and signs the exact response digest and
recipient. The phone confirms both message digests and its own identity before sharing folders.
Saved bindings are verified again before activating delivery. This ceremony is explicit local
trust; the self-signed invitation is not a vendor commissioning certificate.

No automatic trust, introductions, default folder or arbitrary peer share is enabled. Replacement,
revocation, multiple phones, QR setup and managed enrolment are not implemented. A pending phone
invitation can be cancelled explicitly. Only the paired phone is shared the pair-specific folders:

| Folder | Office | Phone | Allowed phone outbound content |
|---|---|---|---|
| `avenkin-preview-<pairID>-in` | send only | receive only | none |
| `avenkin-preview-<pairID>-manuals` | send only | receive only | none |
| `avenkin-preview-<pairID>-out` | receive only | send only | completed `receipt.json` only |

The mobile model guard refuses all other file requests, including temporary reads, before the
stock model accesses bytes. Receive-only alone is not the no-export boundary. The phone viewer
opens only a digest-verified copy of a current assigned original; screenshots and OS/device-owner
access are outside this guard's scope.

## Signed delivery and receipt

Envelopes contain base64 exact payload bytes and an Ed25519 signature with domain
`Avenkin.OfficePreview.v1\0`. Envelopes and signed flat schemas reject duplicate or unknown keys,
nested values, non-integer numeric spellings and trailing JSON. The nested manual array separately
rejects ambiguous objects and trailing data. Maximum envelope is 256 KiB.

A delivery binds pair ID, exact phone identity, random message ID, positive monotonic sequence,
issue/expiry times (at most 30 days), closed job text fields and immutable manual descriptors.
At most 16 manuals, 128 MiB total, 16 MiB per original and 2 MiB per text file are allowed. Peer
filenames never select paths; stored content paths are validated SHA-256 digests. The office
verifies source bytes before staging and saves the pending envelope before publishing it.

The phone verifies the signed delivery, recipient, time and sequence, then exact source/text
sizes and hashes. Missing, corrupt or wrong-recipient files cannot generate a receipt. It writes
private library objects, atomically commits job/manual state, and only then signs a receipt for
message ID, sequence, exact payload digest and manual count. Failed commits do not advance memory
state or acknowledge delivery. Exact replay retains the committed result; older/conflicting
revisions are refused. The office accepts only the matching phone signature and exact pending
message fields. A stale receipt cannot complete a newer delivery.

“Received in companion” records verified companion storage at receipt time. It does not mean the
technician read/accepted/completed the work, or that later local corruption/deletion is impossible.
Originals are checked again before viewing. Office status remains independently editable.

## Persistence and operating limits

Application state uses private atomic files with file sync before rename. This is tested across
ordinary Stop/Quit/relaunch and failed commits, not certified against power loss. The transport
home has an exclusive ownership lock. Its saved LAN listener and certificate survive restart;
an occupied listener fails instead of silently changing the paired endpoint. If the office's
LAN address changes, explicit reconfiguration remains a future gate.

Only one phone and one outstanding delivery are supported. The pending message and receipt survive
desktop quit; this is not yet a multi-job production outbox. Both apps must be open on the same
Wi-Fi for transfer. Explicit Stop persists; there is no tray supervisor or continuous iOS
background service. Previously saved originals remain viewable offline. No public discovery,
relay, NAT/STUN, telemetry or engine updates are enabled in this preview. The older synthetic
Internet/relay experiments do not establish this protocol's Internet operation.

No manual or job content is exported through USB status. The public developer status includes
pairing response/comparison, sequence, manual count, connection state and storage result. USB may
bootstrap public signed setup messages; job/manual delivery and receipts traverse the LAN engine.

Source: `Transport/mobile-core/officepreview`, native desktop `connection.rs`, mobile request guard and
Device Lab UI. Production OpenGlasses enrolment/import, vendor authority, rollback-resistant
recovery, entitlement enforcement, bounded multi-job queues, cancellation/revocation, platform
validation and automatic route selection remain separately reviewable work.
