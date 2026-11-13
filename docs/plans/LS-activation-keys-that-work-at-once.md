# Plan LS — Activation Keys That Work at Once (sign up, hand over the key, start the pilot in the same visit)

**Status:** 📝 Drafted 2026-11-14. Nothing built. Six [decisions](#decisions-for-greig) open.
**Track:** Field Assist — fleet. Activation, the licence host, the public site.
**Builds on:** Plan [CT](CT-org-configuration-profiles.md) 3a (the activation key and its sealed file), Plan
[JS](JS-licence-sales-and-device-seats.md) (the vendor-run service, one key per customer for life, the licence
host and its public paths), Plan [FY](FY-rename-to-avenkin.md) P0 item 7 (`PublicSite`, one base
for every public address, and `PublicSiteGuardTests`).
**Sits beside:** Plan [LR](LR-company-vaults-from-the-portal.md) (company vaults, served from the same licence
host).
**Service side:** planned in the private service repository; this plan carries only the contract the phone reads
and a one-line outline of each service step.

---

## Trigger

A partner cannot install the app, activate it and start a pilot in one visit. They sign the company up in the
portal, read the key to the technician, the technician types it, and the app says the key isn't recognised.

The key is right. Its sealed file is not on the public site yet. Today the service sets the file aside at
sign-up; a scheduled job on the service host, signed in to GitHub as the owner, commits it to `activation/` in this
repository every ten minutes; GitHub Pages deploys it a minute later. So a new key works somewhere between one and
twelve minutes after sign-up. Worse, the public site's CDN caches the *miss*: a key tried before its file is
published keeps failing after the file is there. On 2026-11-14 a lookup of a missing activation file came back
from the CDN with `age: 273`, a cached 404 nearly five minutes old. The partner tries the key once, too early,
and then it fails again on every retry for several more minutes.

## Outcome

- The partner signs the company up. By the time the portal shows the key, its file is already served. The
  technician types it seconds later and the phone activates.
- A key tried too early is never remembered as missing: every answer on the lookup path, the miss included, is
  `no-store`, so the next try asks again.
- Keys issued before the change keep working, on new builds and old ones.
- Nothing about issuing a key touches GitHub. The service host holds no GitHub credential, and this repository's
  history stops recording each customer sign-up as a commit.
- A rotated key stops opening on new builds at once, not when the next scheduled job runs.

## What exists, and what doesn't

**Exists (verified against `main` at 57a37d0d2):**
- `ActivationKey` (`Services/OrgProfile/ActivationKey.swift`): the file name is
  hex(SHA-256(`"openglasses.activation-id.v1\n"` + key)); the file is base64 AES-GCM under
  HKDF-SHA256(key, `"openglasses.activation-key.v1"`); version 2 carries the licence code and the company secret.
  Both signing domains are pinned by `StorageIdentifierGuardTests` and never change.
- `ActivationKeyResolver` reads **one** directory, `ActivationKey.defaultDirectory` =
  `PublicSite.activationDirectory` = `https://avenkin.com/activation/`. 2xx opens the file; 404/410, an HTML
  reply or one over size mean "no file for this key" (`.unknownKey`); anything else is `.unreachable`.
  `OrgEnrolmentService` uses it; tests inject `directory` and `fetch`.
- The fetch goes through `BoundedHTTPClient` with the `.activationKey` profile: 8 KiB, `text/plain` or
  `application/octet-stream`, at most 3 redirects, 20 s total, 8 s to first byte. The client opens its own
  sockets, so there is no `URLCache` on the phone; the only cache in the way is the CDN's.
- `PublicSiteGuardTests` pins every `PublicSite` address under `https://avenkin.com` at the path the old Pages
  addresses redirect to (`activationDirectory` → `/activation/`), checks the resolver's default reads it
  (`https://avenkin.com/activation/abc`), and scrapes the sources for old Pages or repository addresses.
- The licence host is not written anywhere in the app. Every signed licence code names its profile address
  (`https://licence.avenkin.com/p/<profileId>`), and `DeviceSeatLease.seatOrigin(profileAddress:)` derives the
  seat service from it. The phone cannot use that to find the activation file: the address is *inside* the
  sealed file.
- `Scripts/stage-pages-site.sh` copies `activation/` into the site and refuses any path there that is not a
  64-character hex name. `Scripts/generate-field-license.swift --activation-key` mints a key by hand and tells
  the operator to commit its file under `activation/`.
- Egress: the activation lookup, like the profile fetch and LR's company catalog, has no `NetworkRoute` case.
  It sends nothing of the phone's: the only thing in the request is the file name, which only someone holding
  the key can compute. `BoundedHTTPClient` is on the registry's justified exemption list as shared transport.
  Medical Local Only does not refuse it, for the same reason it does not refuse the profile fetch: enrolment is
  a deliberate act and carries no user content.

**Doesn't exist:**
1. Any activation file on the licence host. It serves signed profiles at `/p/` and company vaults at `/c/`, both
   at once and both `no-store` where they change; activation files are only set aside for the repository job.
2. A second place for the phone to look.
3. A way to issue a key without a GitHub write.

## Design

### The contract the phone reads

One new public path on the licence host, beside `/p/` and `/c/`:

```
GET https://licence.avenkin.com/a/<file name>
```

`<file name>` is the same 64-character lowercase hex digest the public site uses. The bytes are the same sealed
file, unchanged. Nothing else answers under `/a/`: no listing, no other name shape, `GET` and `HEAD` only.

| Answer | Means | Headers |
|---|---|---|
| `200`, the sealed file | Issued and current | `Content-Type: text/plain; charset=utf-8`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` |
| `404`, empty body | The host looked, and no key has this name | `Cache-Control: no-store` |
| `410`, empty body | The host looked, and this key was withdrawn (rotated) | `Cache-Control: no-store` |
| `5xx` | The host could not look | `Cache-Control: no-store` |

Three rules matter to the phone:
- **The file is served before the key is shown.** The service writes it in the same step that publishes the
  customer's profile, before the portal's sign-up page returns. "Works at once" is an ordering guarantee, not a
  fast poll.
- **A miss is never cached**, at the host or at the edge in front of it. The edge's off-host copy (the one LR's
  vault files and the profiles already use when the host is down) answers `/a/` like a profile: the host first,
  the copy only when the host cannot answer, and a `5xx`, never a `404`, when neither can say.
- **The path is permanent.** Once a build reads `/a/`, the path must answer for as long as that build is in use,
  the same rule as the profile addresses inside every code. Decision [5](#decisions-for-greig) names it.

The contract goes into `Contracts/activation-lookup.md`, written for the service the way LR's
`Contracts/company-vaults.md` is.

### On the phone

**`LicenceHost`** (new, `Utils/`): the one place the licence host is written.
`baseURL = https://licence.avenkin.com`, `activationDirectory = /a/`. It is not under `PublicSite.baseURL`, so it
gets its own enum rather than an exception in `PublicSite`.

**`ActivationKeyResolver`** reads an ordered list of sources, `[LicenceHost.activationDirectory,
PublicSite.activationDirectory]`, one after the other. The public site is asked only when the licence host has no
file or cannot answer, so a key issued after the change never sends its digest to GitHub at all.

| Licence host | Public site | Result |
|---|---|---|
| `200`, opens | not asked | the contents |
| `200`, does not open | not asked | `.unreadable` |
| `410` | not asked | `.unknownKey`. Withdrawn is final: the public site may still have a copy until its job runs |
| `404`, HTML, or over size | `200`, opens | the contents (a key issued before the change, until it is copied over) |
| `404`, HTML, or over size | `404`, HTML, or over size | `.unknownKey` |
| `5xx`, timeout, or no network | `200`, opens | the contents |
| `5xx`, timeout, or no network | `404`, HTML, or over size | `.unreachable`. The authority couldn't be asked, so "not recognised" would be a guess |
| any | `5xx`, timeout, or no network | `.unreachable`, unless the licence host said `404` (then `.unknownKey`) |

The worst case is two sequential lookups, 40 s under today's profile. The first byte comes within 8 s, or the
next source is asked. That only happens when the licence host is down and its copy is too.

The failure wording stays as it is. One case changes: `.unknownKey` on a build with this plan now means the key
really is unknown, so the message can say so plainly.

**Nothing else moves.** The file format, both signing domains, `ActivationKeyMint` in `Tools/LicenceIssuance`,
`OrgEnrolmentService`, the company secret's handling and `BoundedHTTPClient`'s `.activationKey` profile are
unchanged. `text/plain; charset=utf-8` already passes the profile's MIME check; P0 pins that with a test.

### Privacy and egress

- **Who sees the lookup changes; what it carries does not.** Today GitHub and its CDN see the phone's address and
  the file name. After this plan the vendor's host and its edge see them instead, and GitHub only sees lookups for
  keys issued before the change. The vendor can map a file name to a customer, but learns nothing new: the same
  phone fetches that customer's profile from the same host a second later. `/a/` is held to the same rule as
  the host's other public paths: no access log of request paths.
- **No `NetworkRoute` case, no Medical Local Only exception.** The lookup stays where the profile fetch is: no
  user content, no device identifier, and a deliberate act. `NetworkRouteRegistryTests` is untouched, because the
  resolver still owns no transport.
- **No privacy manifest or in-app copy change.** No new data type, and no shipped copy says where a key is looked
  up (checked: `privacy.html` and the sources name no lookup host). P0 searches again before it lands.
- **`PublicSiteGuardTests`** changes in three places. `activationDirectory` stays pinned at `/activation/` until
  the public copy is retired. `testTheConsumersReadTheBase` asserts the resolver's order instead of its one
  directory. A new section pins `LicenceHost`: the base is `https://licence.avenkin.com`; `/a/` is under it; it
  is the origin `DeviceSeatLease.seatOrigin` derives from a profile address on that host, so the codes and the
  lookup can never name different hosts. The section also scrapes `OpenGlasses/Sources` so the host is written
  nowhere but `LicenceHost`, with comments excepted as the existing scrape excepts them.

### The GitHub write credential

Today the service host keeps the owner's own GitHub sign-in so the scheduled job can commit activation files.
That sign-in is not scoped to one directory, or even to one repository. It can push to this repository's `main`,
which Xcode Cloud builds the app from and which has no branch protection. So a machine whose only job is issuing
licences, reachable from the internet through its tunnel, is one compromise away from changing the app's
source. Even a fine-grained token limited to this repository's contents could still push to `main`.

It has other costs:
- The job runs only while that sign-in is valid and the owner's user session on the host is up. When the login
  expires, keys silently stop publishing.
- Every customer sign-up and every key rotation is a public commit ("Publish an activation key file", "Retire an
  activation key file"). The file names reveal nothing, but the history shows how many customers sign up, and
  when.
- Retiring a key removes its file from the site, not from the repository's history. Anyone holding a rotated key
  can still fetch its old file from history. On the licence host a withdrawn file is gone (`410`).

Once new keys stop going to the repository ([decision 1](#decisions-for-greig)), the host needs no GitHub
credential at all. The job is removed, the owner signs the host out of GitHub, and that token is revoked. It sat
on an internet-facing machine, so it is not reused. Nothing else on the host uses GitHub. Keys that are already
on the public site stay there without any credential: serving them is static. Withdrawing one of those during
the window becomes a rare hand commit by the owner, not a job.

### What happens to the public-site copy

Two separate events, so the credential can go long before the copy does:
1. **New keys stop going to the repository** (decision 1). From then on, a key issued after that date resolves
   only on builds with this plan.
2. **The copy is retired** (decision 3). That is one later PR: remove the fallback from the resolver,
   `PublicSite.activationDirectory`, its guard row, the `activation/` directory, its gate in
   `stage-pages-site.sh`, and the hand-mint instruction in `generate-field-license.swift`, which then points at
   the service. It waits until no build in use reads only the public site.

Before event 1, the service copies every file it ever issued, plus the hand-minted ones in `activation/`, onto the
licence host (decision 2). That makes the licence host the single source for every key, and leaves the public site
as a fallback only for builds that predate the change.

## Phases

One PR each. The app's P0 and the service's P1 do not depend on each other: a build with P0 and no P1 falls
back to the public site; P1 with no P0 build changes nothing for the phone until one ships. The outcome needs
both.

- **P0 — the resolver and its guards (headless).** `LicenceHost`; `ActivationKeyResolver` with ordered sources
  and the table above; `Contracts/activation-lookup.md`; `PublicSiteGuardTests` as described.
  `ActivationKeyTests` covers every row of the table with an in-memory fetch that records what it was asked. It
  asserts that the public site is never asked after a licence-host `200`, `410` or unreadable file, and that a
  `text/plain; charset=utf-8` reply is accepted. `LicenceIssuanceIntegrationTests` resolves a minted key from
  each source in turn. **Exit:** the tests; no change to a key's file name or bytes, shown by the existing
  `StorageIdentifierGuardTests` and fixture tests passing untouched.
- **P1 — the service (private repository).** In outline: the service writes each sealed file into the host's
  public tree at `a/<name>` in the step that publishes the profile; the host serves `/a/` to the contract above;
  the off-host copy and its edge routes cover `/a/` as they cover profiles; withdrawing a key answers `410`;
  every file already issued is copied over; the repository job keeps running until decision 1's date, then the
  job and the host's GitHub sign-in are removed. **Exit:** the service's smoke test signs up a fixture company
  and fetches its `/a/` file, which opens with the key, before the sign-up reply is read; a withdrawn key answers
  `410`; a miss carries `no-store`.
- **P2 — device pass.** A fresh install of the P0 build. A test company is signed up in the portal and the key
  typed within 30 seconds: it activates, the profile applies and a pilot starts, all in one visit. A key typed
  once before sign-up and again right after sign-up works on the second try. A key issued before the change
  works on the P0 build and on the previous App Store build. A withdrawn key is refused at once on the P0 build.
- **P3 — retire the public-site copy (later, on decision 3).** The single PR described above.

## Decisions for Greig

1. **When new keys stop going to the public repository, and the host signs out of GitHub.** *Recommended:* the day
   the P0 build is live on the App Store and on TestFlight. Before that day, keep both, so a key works on any build
   (instantly on the new one, within minutes on the old). After it, a technician on an older build is told to
   update first. The portal's sign-up page states the minimum build next to the key. A new technician installs
   the current build anyway, so only an existing install that hasn't updated meets this. *Alternative:* stop at P1
   deploy, which removes the credential sooner, but a new key fails on every build without P0 until it ships.
2. **Copy every existing key onto the licence host.** *Recommended:* yes, in P1, including the hand-minted ones
   already public in `activation/`. They are sealed and already public, so copying them exposes nothing. The
   licence host then answers for every key, and the public site matters only to old builds.
3. **When to retire the public-site copy (P3).** *Recommended:* when seat renewals show no enrolled phone on a
   build older than P0's, and at least 90 days after P0 reaches TestFlight, by which time every older TestFlight
   build has expired. Licences without seat checks don't report a build, so the 90 days is the floor. The files
   stay in the repository's history either way; they are sealed.
4. **A withdrawn key on the licence host is final.** *Recommended:* yes. `410` stops the lookup without asking the
   public site, so a rotation takes effect at once on new builds instead of waiting for the repository job or
   the CDN.
5. **The path, `/a/<name>`.** *Recommended:* `/a/`, matching `/p/` and `/c/` on the same host. It is permanent
   once a build reads it, so it is chosen now and pinned by the guard.
6. **Make old builds instant too, by putting the public site behind the same edge.** That would mean a route on
   `avenkin.com/activation/*` that asks the licence host first. *Recommended:* no. The public site is served
   straight from GitHub today, not through Cloudflare. Moving its hosting to fix a window that ends when a build
   updates costs more than it saves, and it would keep a GitHub-hosted path in the activation flow.
