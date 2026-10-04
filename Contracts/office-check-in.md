# Office check-in, renewal and removal contract — draft v1 (messages, key-holder operations and fixtures; the phone's half is built in the opt-in build and not yet run against an office)

Drafted 2026-10-04 for Plan [FX](../docs/plans/FX-desktop-office-and-device-sync.md). This is the
agreement between the phone app and Avenkin Office about how a phone that joined an office by
[scanning its code](commissioning.md) stays joined, and how it stops being joined: the check-in
challenge the office sets, the check-in the phone answers with, the renewed peer binding the
office returns, and the removal an administrator signs. It is self-contained so it can be carried
into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*.

**Built so far.** `Transport/mobile-core/checkin` implements every message here — signing, the
two-step signing a phone needs, and each side's checks — and the golden fixtures in §11. The
connection helper (`cmd/office-preview`) has the three operations of the key holder in §5 and
§8: `sign-check-in-challenge` (office application key), `renew-peer-binding` and
`sign-office-removal` (administrator key), each checked before a key signs; the generation
record keeps the removed mark and the binding last issued.

**The phone's half is built, in the opt-in office transport build only** (Plan
[HO](../docs/plans/HO-office-delivery-phone-half.md) P1, 2026-10-04). The phone transport reads
`control/checkin/` and `control/removal/`, builds the check-in and the removal receipt as exact
bytes for the phone application key to sign, publishes them under `records/`, and its outbound
guard serves exactly those published files. In Swift, `OfficeCheckIn` is the phone's verifier
for every message here; `OfficeCheckInService` answers the live challenge once and keeps the
exact bytes and nonce; `OfficePairingService.renew(withResult:waiting:)` is §7 in its order, and
`remove(withRemoval:)` is §8. This is tested headless against an in-memory stand-in for the
transport and the golden fixtures. **It has not been run on a physical phone against an
office,** and the office app does not yet call the helper's operations, so no real phone has
been renewed or removed this way. The default app build links no transport and does none of
this.

**Builds on, unchanged:** the vendor-signed schema-2 profile and licence pair, the
administrator-signed peer binding and its generation rule ([README](README.md), "Office authority
and peer binding"), the phone's application key in device-only storage, and the
[managed office folders](office-folders.md) that carry every file here.

## 1. The problem this closes

A phone that joined an office by its code holds two things that run out, and nothing renews
either without a person:

| What | How long | What happens when it runs out |
|---|---|---|
| The peer binding | At most 30 days from issue, and never past the profile's `policyExpiry` | Neither side opens the managed connection or its folders; the office delivers no job |
| The management lease | The profile's `leaseDays` from the last renewal, and never past `policyExpiry` | The phone locks the organisation's content (after any job already open) and opens no managed connection |

A phone enrolled from a hosted profile renews its lease by fetching that profile again, and hears
a revocation the same way. A phone enrolled by an office has no profile address, so that fetch
never runs: its lease ends `leaseDays` after it joined, its binding 30 days after it joined, and
it cannot be told it has been removed.

The licence's own expiry and the profile's `policyExpiry` are the vendor's and are **not**
extended by anything here (§10).

## 2. What a person sees

- **Normally, nothing.** When the app is running and can reach the office, it checks in and the
  office renews. Nobody approves, scans or types anything.
- **After time away.** A phone that was out of reach — a holiday, a long site visit — checks in
  the next time the app runs in reach of the office, provided its binding and lease have not
  both been allowed to run out. *Requirement on the office:* it sets a new challenge whenever
  none is live and the phone's binding was issued more than 24 hours ago, so a phone in regular
  contact always holds a binding with at least 29 days left, and a lease renewed within the
  last day.
- **After too long away.** Once the binding or the lease has run out, the phone cannot check in
  (§9, "Renewal is before the end"). It joins again by scanning a code at the office; its
  enrolment identifier is kept, so this is a renewal by hand, not a new phone.
- **Removed.** The phone says the organisation has removed it, and the existing leaving rules
  apply: its rules lift, its content locks, and records still owed are handled as for any
  revoked phone.

## 3. Signed bytes

Every message is the JSON envelope the other contracts use: two standard-alphabet, padded base64
strings, `payload` and `signature`. Ed25519 signs the UTF-8 bytes of the message's domain, one
zero byte, then the exact decoded payload bytes; nothing is re-encoded at verification. Envelope
and payload are closed, flat JSON objects: every listed field is present exactly once; duplicate
or unknown keys, nested values, booleans, nulls and fractional or exponent numbers are refused,
as is trailing data. A field with nothing to say is the empty string, never absent.

Integers are positive and at most 2^53 − 1; times are Unix UTC seconds. Identifiers are 1–80
ASCII letters, digits, dot, underscore or hyphen, excluding `.` and `..`. A **nonce** is 256
random bits as 43 characters of URL-safe base64 without padding. A **message digest** is the
lower-case hexadecimal SHA-256 of the exact envelope bytes as published. A **binding digest** is
the lower-case hexadecimal SHA-256 of a peer binding's decoded payload bytes — the value the
phone already keeps with its generation high-water mark.

| Message | Domain | Signed by | Size cap |
|---|---|---|---|
| Challenge | `Avenkin.OfficeCheckInChallenge.v1` | Office application key | 4,096 bytes |
| Check-in | `Avenkin.OfficeCheckIn.v1` | Phone application key | 4,096 bytes |
| Result | `Avenkin.OfficeCheckInResult.v1` | **Administrator key** | 65,536 bytes |
| Removal | `Avenkin.OfficeRemoval.v1` | **Administrator key** | 4,096 bytes |
| Removal receipt | `Avenkin.OfficeRemovalReceipt.v1` | Phone application key | 4,096 bytes |

**Which key, and why.** The office application key and the phone application key are the ones
the current binding names; each is taken from the binding, never from the message. They prove
who is speaking and nothing more. Renewing a lease and removing a phone are the organisation's
decisions, so the result and the removal are signed by the administrator key the vendor-signed
profile names — the same key, verified the same way, as the binding itself. A message carries no
key of its own, and no domain here is accepted for another message.

## 4. The exchange

Three files, in the phone's own managed folders:

| Step | Path | Direction |
|---|---|---|
| Challenge | `control/checkin/<challengeID>.challenge.envelope.json` | office → phone |
| Check-in | `records/checkin/<challengeID>.envelope.json` | phone → office |
| Result | `control/checkin/<challengeID>.result.envelope.json` | office → phone |

`challengeID` is 32 lowercase hexadecimal characters chosen by the office. Every name, once
published, always holds the same bytes.

### 4.1 Challenge (office → phone)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-check-in-challenge` |
| `challengeID` | As in the file's name |
| `nonce` | The office's nonce. Single use |
| `organizationID`, `enrolmentID`, `officeID` | The binding this is set under |
| `phoneTransportID` | The phone's transport identity under that binding |
| `generation`, `bindingSHA256` | The binding the office holds as current for this phone |
| `issuedAt`, `expiresAt` | Live while `issuedAt <= now < expiresAt`; at most 7 days, and not past the binding's `expiresAt` |

At most one challenge is live per enrolment. Setting a new one withdraws the old: the office
removes the old file, and a check-in for it no longer renews.

### 4.2 Check-in (phone → office)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-check-in` |
| `challengeID`, `challengeSHA256` | The challenge answered, and its message digest |
| `nonce` | The phone's own nonce, new for this check-in |
| `organizationID`, `enrolmentID`, `officeID`, `phoneTransportID` | From the phone's own storage and its verified binding |
| `generation`, `bindingSHA256` | The binding the phone holds as current |
| `leaseRenewBy` | When the phone's lease ends as it stands, phone clock. Informational: it lets the office list each phone's date |
| `appVersion`, `appBuild` | Up to 64 printable characters each, for the office's register |
| `createdAt` | Phone clock, informational only |

The phone answers a challenge only when all of these hold, checked at that moment:

- its gate for the managed connection passes — vendor-signed profile and licence, lease in
  force, the saved binding verifying against its own keys and its generation high-water mark;
- the challenge is signed by the office application key that binding names, names this phone's
  organisation, enrolment, office and transport identity, and names exactly the generation and
  binding digest the phone holds;
- the challenge is live on the phone's clock.

It answers the live challenge with the latest `issuedAt`, once: it keeps the exact bytes of its
check-in and its nonce until a result arrives or the challenge expires, and publishes the same
bytes again rather than a second check-in for the same challenge. A challenge that fails a check
is left where it is and not answered.

### 4.3 Result (office → phone)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-check-in-result` |
| `challengeID`, `checkInSHA256` | This exact exchange: the message digest of the check-in answered |
| `organizationID`, `enrolmentID`, `officeID`, `phoneTransportID` | Echoed. The phone refuses a result for any other identity |
| `outcome` | `renewed` — the only outcome in v1 |
| `peerBinding` | The renewed administrator-signed peer-binding envelope, unchanged (at most 32,768 bytes) |
| `issuedAt` | Office clock |

A check-in the office does not renew gets no result in v1. The phone sees a challenge that was
never answered; the office says why on its own screen.

## 5. When the office renews

The office renews only when every one of these holds, on its own clock and its own records:

1. the check-in is signed by the phone application key **in the binding the office holds** for
   that enrolment, and names that organisation, enrolment, office and transport identity;
2. it names a challenge the office set for that enrolment, by identifier and message digest,
   that is live and has not been used or withdrawn;
3. it names the generation and binding digest of the binding the office holds as current;
4. that binding is still inside its validity window;
5. the enrolment has not been removed (§8).

Using the challenge and recording the renewed binding are one durable step: after a crash there
is either no renewal and an unused challenge, or exactly one renewed binding at the new
generation. A second check-in for a used challenge — the same bytes or others — never produces a
second renewal; the same bytes get the same result file again.

**Nothing else renews.** A live connection, a file's timestamp, an index exchange, a job receipt,
a replayed check-in or a check-in for an expired or withdrawn challenge does not renew a binding
or a lease.

**Where the administrator key is.** *Assumption:* the administrator key is held by one process
on the office computer on behalf of the office app. That holder must not sign a renewed binding
on request alone: it is given the exact challenge, check-in and current binding envelopes,
verifies the challenge and the check-in as this contract says, checks that the binding's
generation is the latest it has issued for that enrolment and that the enrolment is not marked
removed, and only then signs. The rule in the previous paragraph is therefore enforced where the
key is, not only by its caller.

## 6. The renewed binding

It is an ordinary peer binding under `Avenkin.OfficePeerBinding.v1`, and the phone verifies it
with the verifier it already has. Compared with the binding the check-in named:

- **the same** organisation, profile, enrolment, office identifier, office transport identity,
  office application key, phone transport identity and phone application key;
- a **higher** generation;
- a new `issuedAt` and an `expiresAt` at most 30 days later and not past `policyExpiry`.

A binding that differs in any identity is not a renewal and is refused here. A different office
computer or office key is a replacement, which a person approves by scanning a code (§10).

**Why a higher generation.** The phone keeps one binding digest per generation and refuses a
second binding at the same generation as a conflict. That rule stays. Renewal therefore moves
the generation on, with the consequences the existing contracts already give a new generation:

- the managed folders are **the same folders** — their identifiers do not include the
  generation;
- a managed job names one generation exactly, so a job signed under the old generation that the
  phone has not committed is refused once the phone holds the new one. *Requirement on the
  office:* it issues such jobs again under the new generation. A job the phone already committed
  keeps its receipt, which names the generation it was received under;
- sequences in each contract restart under the new generation, as their own rules say.

## 7. What the phone does with a result

In this order, stopping at the first failure and changing nothing:

1. The result is signed by the administrator key from the vendor-verified profile, and names
   this phone's organisation, enrolment, office and transport identity.
2. `challengeID` and `checkInSHA256` are those of the one check-in the phone is waiting on. A
   result for any other check-in — an earlier one, or one this phone never made — is ignored.
3. `peerBinding` passes the existing binding verifier against the phone's own keys and the
   office identities it saved when a person approved the pairing, with a generation higher than
   the retained one, and meets §6.
4. The profile, licence and lease are checked again, as before any managed connection.
5. Commit, in this order: the generation high-water mark; the saved binding; then the lease —
   `lastRenewedAt` becomes **the phone's own clock now**, exactly as a re-fetched hosted profile
   renews it. Then the phone forgets the check-in's nonce.

The lease still ends at the earliest of `leaseDays` from that moment and `policyExpiry`, and the
licence's expiry is checked independently, as today. The office cannot grant a longer lease than
the vendor-signed profile allows, and the result carries no lease length.

A crash between the steps of 5 is repaired by taking the same result in again: the same
generation with the same digest is an exact repeat, not a conflict. Taking a result in a second
time after the nonce is forgotten changes nothing, so a stored or replayed result cannot renew a
lease later.

## 8. Removal

One administrator-signed message ends an enrolment, whether the technician has left, the phone
is being handed on, or it has been lost.

**Path:** `control/removal/<removalID>.envelope.json`, `removalID` 32 lowercase hexadecimal
characters.

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-removal` |
| `removalID` | As in the file's name |
| `organizationID`, `profileID`, `enrolmentID` | The enrolment that ends |
| `officeID`, `phoneTransportID` | The pairing it was sent through |
| `reason` | `removed` (an orderly leaving) or `revoked` (lost, stolen or no longer trusted) |
| `issuedAt` | Office clock |

A removal has no expiry and no generation: it is final for that enrolment identifier, and an
exact repeat changes nothing.

**The phone,** on a removal signed by the administrator key from its vendor-verified profile and
naming its own organisation, profile, enrolment and transport identity, treats it exactly as a
signed revocation heard from a hosted profile: the enrolment is revoked, the organisation's
rules lift, its content stays locked, and the existing leaving rules decide what happens to
records still owed. It then publishes a receipt and opens no further managed connection for that
enrolment. `reason` changes the sentence the person reads and nothing else. A phone that later
joins the same office again does so under a new enrolment identifier, which the old removal does
not name.

**Removal receipt:** `records/removal/<removalID>.envelope.json`.

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-removal-receipt` |
| `removalID`, `removalSHA256` | The removal acted on, and its message digest |
| `organizationID`, `enrolmentID`, `phoneTransportID` | This phone |
| `actedAt` | Phone clock when the enrolment was marked revoked |

**The office,** from the moment an administrator removes a phone:

- treats the pairing as not current: no job, assignment or bulk content is published for it, no
  challenge is set and no check-in is renewed, and **no binding is ever issued for that
  enrolment identifier again** — the key holder in §5 keeps that mark with its generation
  record;
- for `removed`: keeps `control` — holding only the removal — and `records` shared so the
  removal can be delivered and the receipt and any owed records collected, until the receipt
  arrives or the last binding's `expiresAt`, whichever is first; then removes the peer and its
  folders;
- for `revoked`: removes the peer and every folder at once. The removal is recorded but may
  never be delivered; the phone's lease running out is the backstop, and until it does the
  phone keeps what it already downloaded. Information already on an unreachable phone cannot
  be erased from the office.

This is the one exception to "gone when the binding is" in the
[folders contract](office-folders.md) §1, which is amended to say so.

## 9. Replay, order and clocks

- **Renewal is before the end.** A phone checks in, and an office renews, only while the
  current binding is inside its validity window and the phone's lease is in force. Nothing in v1
  reopens a connection for a binding or a lease that has run out; that phone joins again by
  scanning (§2). An unreachable office therefore cannot be made up for afterwards — which is
  why the office renews early (§2) rather than near the end.
- **One challenge, one check-in, one result.** A challenge is used once. The phone waits on at
  most one check-in. A result is bound to that check-in's digest, which covers the phone's
  nonce and the challenge's digest, which covers the office's nonce: a result made for another
  exchange, phone or day fits nothing.
- **Generations only rise.** The office never issues a generation it has issued before, also
  after it has been restored from a backup: *Requirement on the office:* the generation record
  is restored with the administrator key or reconciled upward before anything is signed. A
  phone refuses a binding at or below its retained generation unless it is the exact one it
  holds.
- **File arrival order means nothing.** A result may arrive before the phone has noticed its
  check-in was taken; a new challenge may arrive while an old result is still in the folder.
  Each file is judged by the fields above, not by when it appeared.
- **Each side uses its own clock.** The office's clock decides whether a challenge is live when
  it renews, and stamps the binding. The phone's clock decides whether a challenge and a
  binding are valid when it takes them in, with the rule it already has for a clock wound back
  behind a time it has seen. `createdAt`, `leaseRenewBy` and `actedAt` are information for a
  screen and decide nothing. A challenge or binding not yet valid on the phone's clock waits; it
  is not remembered as refused.
- **Malformed or refused input** is left where it is and recorded once with a bounded reason,
  as the folders contract says.

## 10. Deliberately left out

1. **Replacing the office** — a new office computer, application key or transport identity. It
   changes `officeID`, so the folders are different folders, and the phone requires a person to
   compare the new identities. It is done by scanning a code under the same enrolment and a
   higher generation. A signed hand-over from the old office to the new is not designed.
2. **A newer profile or licence.** The result carries only a binding. A phone whose profile
   term or licence is ending still needs the vendor-signed pair delivered as a setup package,
   until the administrator overlay and profile distribution have their own contract.
3. **Coming back after the end** without a scan — a check-in-only connection for a binding or
   lease that has run out. It would need the phone's gate and the office's folder rule to admit
   an expired binding for this one purpose.
4. **A refusal outcome.** A check-in that is not renewed gets no file.
5. **A vendor-signed revocation** for a phone that never reconnects and whose organisation's
   office is gone.
6. **A file form** of these messages for a phone that cannot reach the office's folders.
7. **Background delivery.** Nothing here makes iOS run the engine in the background: a phone
   checks in when the app is allowed to run.

## 11. Fixtures

In `Contracts/fixtures/`, made by `checkin.Fixtures()` and kept current by that package's tests,
with fictional keys derived from public labels (the office and phone keys are the commissioning
fixtures' own) and the clock at 1800000000: `office-check-in-binding-v1.json` (generation 1),
`office-check-in-challenge-v1.json`, `office-check-in-v1.json`, `office-check-in-result-v1.json`
(carrying the same binding at generation 2), `office-removal-v1.json`,
`office-removal-receipt-v1.json` and `office-check-in-fixture-keys.json`.

```
go -C Transport/mobile-core test -tags noassets ./checkin/ ./officepreview/ ./cmd/office-preview/
CHECKIN_WRITE_FIXTURES=1 go -C Transport/mobile-core test -tags noassets ./checkin/   # regenerate
```

Negative cases, covered in the Go tests and, for the phone's side, in the portable Swift checks
(`Contracts/tests/test_manual_contracts.py` for the messages, `test_inline_entitlement.py` for
the pairing gate) against these fixtures: a check-in for an expired, withdrawn, used or
foreign challenge; a check-in signed by a key other than the binding's; a check-in naming an
older generation or another binding digest; a second check-in for one challenge; a result signed
by the office application key instead of the administrator key; a result for another check-in,
phone or enrolment; a result whose binding changes an identity, repeats or lowers the
generation, or outlives `policyExpiry`; a result taken in twice; a removal for another enrolment
or profile, or signed by the office application key; a binding requested for a removed
enrolment; each message under another message's domain; and extra, missing, duplicate, nested
and fractional fields.

## 12. Open points

1. **Coming back after the end** (§10.3) is the gap a long absence falls into. Whether a
   bounded grace is worth the weaker rule is undecided.
2. **How early the office renews** is a requirement here (24 hours), not a wire rule. Each
   renewal re-issues undelivered jobs under a new generation; whether that cost wants a longer
   interval is unmeasured.
3. **Records still owed at removal** travel by whatever path reports use. Reports over the
   folders now have a contract ([office-reports.md](office-reports.md)), which leaves this point
   open: a removed phone opens no further connection, so a report not receipted by then does
   not travel that way.
4. **The lease shorter than the binding.** A profile with `leaseDays` under 30 makes the lease
   the limit. Nothing here forbids it; an office that authors policy should say so.
