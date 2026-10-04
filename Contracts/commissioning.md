# Office commissioning contract — v1

How a phone joins an Avenkin office by scanning one code: the invitation the office shows, the
redemption the phone answers with, the comparison code both screens show, and the office's
approval or refusal.

**Status:** contract, reference implementation, bootstrap connection and golden fixtures. The
office helper and the phone bridge expose the connection, and both apps use it: the office
desktop's commissioning screens through the helper, and the phone's scanner in its opt-in
office-transport build (`AVENKIN_OFFICE_TRANSPORT`). Adopted from
the office's proposal (`avenkin-office` `docs/proposals/commissioning-contract-v1.md`) with the
changes listed under [Changes from the proposal](#changes-from-the-proposal).

**Reference implementation:** `Transport/mobile-core/commission` (Go, messages only: it opens no
connection, stores nothing and holds no key) and `Transport/mobile-core/commission/bootstrap`
(the connection in §3). The office runs it through the helper's `commission-serve` conversation
(`cmd/office-preview`); the phone through the bridge's `Commission*` functions.
**Fixtures:** `Contracts/fixtures/commission-*`, made by `commission.Fixtures()` and kept current
by that package's tests.

**Builds on, unchanged:** the vendor-signed schema-2 profile and licence pair, the
administrator-signed peer binding (`README.md`, "Office authority and peer binding"), the
phone's application key in device-only storage and its transport identity.

## 1. What a person sees

1. At the office: **Add device**, type a name. A QR code appears.
2. The technician opens Avenkin and scans it with the in-app scanner.
3. Both screens show the same short comparison code. The office user clicks **Approve**.
4. The phone shows the organisation's review sheet (the existing one); the technician accepts,
   and the phone is enrolled and paired. Nobody types an address, copies an identity or moves a
   file.

## 2. Signed bytes

Every message is a JSON envelope of two standard-alphabet, padded base64 strings, `payload` and
`signature`. Ed25519 signs the UTF-8 bytes of the message's domain, one zero byte, then the exact
decoded payload bytes; nothing is re-encoded at verification. Envelope and payload are closed,
flat JSON objects: every listed field is present exactly once; duplicate or unknown keys, nested
values, booleans, nulls and fractional or exponent numbers are refused, as is trailing data.
Base64 must round-trip to the same text, and a signature is exactly 64 bytes.

Integers are positive and at most 2^53 − 1; times are Unix UTC seconds. Identifiers are 1–80
ASCII letters, digits, dot, underscore or hyphen, excluding `.` and `..`. Transport identities
are in the canonical device-identity form. Application keys are 32-byte Ed25519 public keys.
A field with nothing to say is the empty string, never absent.

A **message digest** is the lower-case hexadecimal SHA-256 of the exact envelope bytes as sent
(the JSON text, including the signature).

| Message | Domain | Signed by | Size cap |
|---|---|---|---|
| Invitation | `Avenkin.CommissionInvitation.v1` | Office application key | 2,048 bytes |
| Redemption | `Avenkin.CommissionRedemption.v1` | Phone application key | 4,096 bytes |
| Approval, refusal | `Avenkin.CommissionApproval.v1` | Office application key | 131,072 bytes |

**None of these signatures is authority.** The invitation's only fixes which office the next two
messages must come from. The redemption's proves the phone holds the key it presents. The
approval's says which office sent three artefacts, each of which the phone verifies with the
code it already has: the vendor-signed profile and licence pair, the owner's review, then the
administrator-signed peer binding against the administrator key in that profile.

### 2.1 Invitation (office → phone, in the QR code)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.commission-invitation` |
| `invitation` | 256 random bits as 43 characters of URL-safe base64 without padding. Single use |
| `organizationID` | Lets a phone enrolled elsewhere refuse before connecting |
| `officeID` | `office-` and the first 12 bytes of SHA-256(office application key) in hex, as in the peer binding. Refused if it is not that derivation |
| `officeApplicationKey` | The key that signed this invitation |
| `officeTransportID` | The office transport identity; the phone pins the bootstrap connection to it |
| `address` | `a.b.c.d:port` on a private IPv4 network. A route hint, never authority |
| `issuedAt`, `expiresAt` | Live while `issuedAt <= now < expiresAt`; at most 900 seconds |

**QR text:** `avenkin-commission:` followed by the URL-safe base64, without padding, of the
envelope bytes. This is text, not a URL scheme the app registers: the system camera opens
nothing, and only the in-app scanner acts on it. The fixture is 938 characters.

The invitation never carries a private key, an AI key, a relay token, the licence, the profile
or a setting. It is a bearer secret for one use and at most fifteen minutes; the office shows the
code only while it is live and keeps only a digest of the `invitation` value.

### 2.2 Redemption (phone → office)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.commission-redemption` |
| `invitationSHA256` | Digest of the invitation envelope scanned |
| `invitation` | The invitation value, so the office can redeem it |
| `enrolmentID` | The enrolment identifier the phone will use if it is approved. Chosen by the phone |
| `phoneTransportID`, `phoneApplicationKey` | The phone's own identities, from device storage |
| `appVersion`, `appBuild` | Up to 64 printable characters each, for the office's register |
| `existingEnrolment` | Empty, or the organisation the phone is already enrolled to |
| `createdAt` | Phone clock, informational only |

The office refuses a redemption that is not signed by the `phoneApplicationKey` it presents,
that names another invitation digest or value, or that presents the office's own identities.
Redemption is atomic against the office's ledger and bound to the phone's two identities: a
second redemption of the same invitation, by any device, is refused and shown as an unexpected
use.

### 2.3 Comparison code

SHA-256 of `Avenkin.CommissionComparison.v1`, one zero byte, the invitation digest and the
redemption digest (each as its 32 raw bytes). The first 60 bits are written as twelve Crockford
base32 characters (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`) in three groups of four, for example
`EGVW-EFKZ-2ZDB`. Both screens show it until a person decides.

### 2.4 Approval (office → phone)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.commission-approval` |
| `invitationSHA256`, `redemptionSHA256` | This exact exchange |
| `enrolmentID`, `phoneTransportID`, `phoneApplicationKey` | Echoed from the redemption. The phone refuses an approval for any other identity |
| `profileDocument` | The vendor-signed schema-2 profile, unchanged (at most 32,768 bytes) |
| `licenceCode` | The vendor-signed licence for the same organisation and profile, unchanged (at most 16,384 bytes) |
| `peerBinding` | The administrator-signed peer-binding envelope, unchanged, naming `enrolmentID` (at most 32,768 bytes) |
| `officeAddress` | The office sync engine's listener, `a.b.c.d:port` on a private IPv4 network, where the phone connects once enrolled (with `tcp://` in front, it is the address the phone's managed connection takes). A route hint, never authority: the engine pins the office transport identity the peer binding names. Under `automatic` the phone also finds the office through discovery; this address is the LAN shortcut |
| `issuedAt` | Office clock |

### 2.5 Refusal (office → phone)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.commission-refusal` |
| `invitationSHA256`, `redemptionSHA256` | This exact exchange |
| `reason` | One of `expired`, `already_used`, `wrong_organisation`, `refused_by_person`, `policy` |
| `issuedAt` | Office clock |

A refusal uses the approval's domain and key and carries no artefact.

## 3. The bootstrap connection

- The office listens on its private-LAN IPv4 address only while the invitation is live, and
  refuses a loopback, wildcard, link-local or public address. One listener per invitation; it
  closes when the invitation is cancelled, when it expires, or shortly after its decision has
  been delivered. It serves no job, manual, signing or administration request.
- TLS 1.3, with the office presenting its transport certificate. The phone refuses any
  certificate whose device identity is not the invitation's `officeTransportID`; there is no CA
  or host-name check. This stops someone on the same network reading an invitation off the wire
  and redeeming it first. The phone dials only the invitation's address, through no proxy, and
  follows no redirect.
- One exchange, on one path:

  | Request | Answer |
  |---|---|
  | `POST /commission/v1/redemption`, body the redemption envelope exactly as sealed | `202` and `{"status":"awaiting"}` until a person decides; then `200` and the approval or refusal envelope as the body |

  The phone repeats the identical request about every two seconds until it has a decision or
  the invitation expires, and keeps the redemption's exact bytes for that: the first valid
  redemption is the exchange, the same bytes again get the same answer, and any other valid
  redemption of the invitation gets a signed `already_used` refusal and is shown at the office
  as an unexpected use. After `expiresAt` a redemption gets a signed `expired` refusal. The
  phone opens no listener.
- Limits: the body is at most the redemption cap (4,096 bytes, else `413`); the answer at most
  the decision cap. Any other path is `404`, any other method `405`, a body that is not a
  redemption of this invitation `400`. The listener holds at most 8 connections at once and
  answers at most 1,024 requests (then `429`), with short header, read, write and idle timeouts.
- A network that blocks phone-to-computer traffic falls back to carrying the same three messages
  as files.

## 4. Rules both sides keep

- One invitation per named slot; issuing a new one or cancelling the slot kills the old one.
- A person approves every phone. Nothing approves automatically.
- The phone takes its identities and its enrolment identifier from its own storage. Nothing in
  the QR code or the approval can substitute them.
- The QR code, the address and the office identity are never authority.
- The comparison code is shown on both screens until a decision.
- A phone already enrolled to another organisation refuses before connecting.

## 5. Fixtures

`Contracts/fixtures/`, with fictional keys derived from public labels (seed = SHA-256 of the
label; see `commission-fixture-keys.json`) and the clock at 1800000000:

- `commission-invitation-v1.json` and `commission-qr-v1.txt` (the exact QR text);
- `commission-redemption-v1.json`;
- `commission-approval-v1.json` and `commission-refusal-v1.json`;
- `commission-comparison-v1.txt` (`EGVW-EFKZ-2ZDB`).

The three artefacts inside the approval fixture are fictional text. This contract carries them
without reading them; the profile and licence pair and the peer binding have their own
verifiers.

Negative cases are in `Transport/mobile-core/commission/commission_test.go`: an invitation
outside its window, with a public or named address, with another office's identifier, or signed
by a key other than the one it names; QR text that is not exact; a redemption with a wrong
digest, for another invitation, signed by another key, or presenting the office's identities; an
approval from another office, for another phone or enrolment, for another exchange, or without
an artefact; unknown refusal reasons; extra, missing, duplicate, nested and fractional fields;
and a message under another message's domain.

```
go -C Transport/mobile-core test -tags noassets ./commission/...                 # messages and connection
COMMISSION_WRITE_FIXTURES=1 go -C Transport/mobile-core test -tags noassets ./commission/   # regenerate
```

## Changes from the proposal

- **The redemption carries `enrolmentID`.** The peer binding names the phone's enrolment
  identifier, but the phone creates that identifier only when it applies a profile, and here the
  profile and the binding arrive together. The phone chooses the identifier before it answers,
  the approval echoes it, and the phone applies the profile under it.
- **Optional fields are empty strings.** The closed-object rule the other contracts use requires
  every field, so `existingEnrolment` is empty rather than absent.
- **A refusal is its own kind** (`avenkin.commission-refusal`) with its own closed field list,
  rather than an approval-shaped message with a status.
- **Digests are over the envelope bytes**, for the invitation and the redemption alike, so the
  comparison code also covers both signatures.
- **The approval carries `officeAddress`.** The invitation's address is the bootstrap listener,
  and the office's sync port is chosen when its engine starts, so without it someone would type
  the office's address into the phone.
- **Decided:** the QR is text with a prefix, not a registered URL scheme; the comparison code is
  twelve characters; the bootstrap connection is TLS pinned to the office transport identity.
- **Still open:** whether the approval later carries a first organisation overlay; lease renewal,
  revocation and removal for office-enrolled phones (now drafted separately:
  [office-check-in.md](office-check-in.md), design only); the file form of the
  three messages for networks that block the bootstrap connection.
