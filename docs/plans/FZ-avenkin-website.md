# Plan FZ — The Avenkin Website (avenkin.com)

**Status:** 🚧 P2 shipped 2026-10-03 ([#626](https://github.com/straff2002/OpenGlasses/pull/626), live on avenkin.com); P5's vault guide page shipped with it; P3, P4 and the rest of P5 not started. Drafted 2026-09-29. avenkin.com
already serves the Pages site and new builds read one base URL (`PublicSite`, Plan FY).
**P2 as built:** the homepage at `/` with the sign-in hand-off kept inline and byte-for-byte as it
was; `/auth/meta/` with the fixed-path hand-off; `/app/`, `/field-assist/`, `/office/`, `/pricing/`
(structure, no prices or buy links), `/source/`, `/terms/`, `/security.html`,
`/.well-known/security.txt`, `/404.html`; one shared stylesheet; a `<meta>` Content-Security-Policy
on every new page; the association file narrowed to `/auth/meta`; `Scripts/site-legacy-paths.txt`,
`Scripts/check-pages-site.py` and `Scripts/tests/site-auth-forward.test.js`, run by `pages.yml` on
deploy and on pull requests that touch the site. **Differences from the text below:** (1) new pages
live in `site/`, but the four legacy pages stay at the repository root, because
`BrandNameGuardTests`, `WeatherKitEntitlementGuardTests` and the rename script read them there;
(2) `/` forwards on any query or fragment, as it always has, rather than on named auth keys, because
P0 recorded no key names — so nothing may link to a fragment of the homepage, and the site check
enforces that; (3) the role addresses (`support@`, `security@`, …) are **not** used: avenkin.com has
no mail records yet, so every page keeps the existing contact address; (4) the privacy policy gains
a section on the website only — Avenkin Office is not covered yet; (5) the activation-gate fixture
is not written. **Also shipped:** the homepage and product pages redesigned; a TestFlight beta
link; three app screenshots on `/field-assist/`; the vault guide as `/field-assist/vault-guide/`,
converted with its PDF by `Scripts/build-vault-guide-page.py` and checked against the Markdown on
every deploy; `.well-known/` published for the first time
([#627](https://github.com/straff2002/OpenGlasses/pull/627)). **Owed by the owner:** a Meta registration from a clean install via `/` and via
`/auth/meta/`, then the portal switch; legal review of `/terms/` (R10); mail for the domain.
**Origin:** The owner bought **avenkin.com** on 2026-09-29, the day after the product was renamed
(Plan FY: the phone app becomes **Avenkin**, the desktop app **Avenkin Office**). Decided the same
day: the existing GitHub Pages site, built by this repository's `pages.yml`, takes avenkin.com as
its custom domain now; new builds read every site address from one base-URL setting; the site stays
static, and anything dynamic lives on a subdomain.
**Depends on:** nothing for P0 and P1. P2's copy follows FY's naming decision (open question 5). P3
needs the desktop release pipeline in the private desktop repository. P4's automated half builds on
Plan [EI](EI-licence-issuance-portal.md)'s pure issuance core.
**Related:** Plan [CT](CT-org-configuration-profiles.md) (activation keys and the `activation/`
directory; org profiles), Plan [EE](EE-field-assist-commercial-licensing.md) (tiers; what the app may
and may not say about buying), Plan [EI](EI-licence-issuance-portal.md) (hosted issuance, ledger,
signing-key isolation), Plan [EG](EG-vault-packs.md) (signed vault-pack catalog), Plan
[FV](FV-support-reports.md) (support-report address), Plan FX (phone connection to Avenkin Office),
Plan FY (the rename).
**Surfaces:** the published site (`Scripts/stage-pages-site.sh`, `.github/workflows/pages.yml`, the
pages themselves), a small app change (P1), owner work at the registrar, GitHub, App Store Connect,
the Meta developer portal and a mail host, and later a small serverless service on a subdomain.

---

## What this plan decides

1. **One site, one domain, no broken builds.** avenkin.com is the GitHub Pages site that already
   serves privacy, support, the signed catalogs and the activation files. Every path a shipped build
   reads keeps existing at the same path. Old builds reach it through GitHub's redirect from
   `straff2002.github.io/OpenGlasses/…`, and that redirect is verified per address before anything
   else moves.
2. **A real homepage at `/`,** which means the Meta auth redirect page moves to its own path. `/`
   keeps forwarding an in-flight Meta auth bounce until the portal change is confirmed, and after
   that as a cheap safety net.
3. **Avenkin Office ships as a direct download** (a notarised Mac disk image and a signed Windows
   installer) with an in-app updater reading a manifest on avenkin.com. The Mac App Store is
   reconsidered later, for discoverability only.
4. **Licences are sold on the web** through a merchant-of-record payment provider or by invoice. At
   first they are issued by hand with the existing generator, then by a small serverless signer that
   reuses the existing licence format byte for byte.
5. **The website makes the same privacy promise as the app.** No third-party analytics, trackers,
   fonts or embeds. If anything is measured, it is first-party, cookieless and disclosed.

---

## Verified starting point (main, 2026-09-29)

**The site is an allowlist, not the checkout.** `pages.yml` runs `Scripts/stage-pages-site.sh`, which
copies an explicit list into `_site/` and then refuses to publish if the staged tree contains any
denied path (source, plans, secrets, build products). `activation/` is copied whole, but the gate only
accepts `activation/<64 hex characters>`. The deploy uses the Actions Pages artifact, so a custom
domain is set in the repository's Pages settings and a `CNAME` file is not needed.

**`/` is not a homepage.** `index.html` is the Meta auth redirect page. It builds
`mwdat-<app id>://` + `location.pathname` + query + hash, and after two seconds shows an "Open the
app" button. On github.io the pathname is `/OpenGlasses/`. **On avenkin.com it will be `/`, so the
scheme URL the page produces changes the moment the domain is switched on.** Whether the SDK's
`handleUrl` cares about the path is unknown. P0 tests this with a real registration.

**What shipped builds read, and how:**

| Address (under `straff2002.github.io/OpenGlasses/`) | Read by | Fetched with |
|---|---|---|
| `privacy.html` | `SettingsView.swift:146` (opens in the browser); App Store Connect privacy URL | Safari |
| `support.html`, `about.html` | App Store Connect support and marketing URLs | Safari |
| `index.html` (`/`) | The Meta developer portal registration (exact URL to confirm in P0) | Safari, then the `mwdat-…://` scheme |
| `skillpacks/catalog.json`, `vaultpacks/catalog.json` | `Config.skillPackCatalogURL` / `vaultPackCatalogURL` defaults (`Config.swift:2176`, `:2186`); a user override wins | `BoundedHTTPClient` `.signedCatalog` |
| `skillpacks/packs/com.openglasses.barista-1.0.0.zip`, `…focus-1.0.0.zip` | The `downloadURL` **inside the signed catalog payload**: the github.io address is covered by the catalog signature | `BoundedHTTPClient` `.skillPack` |
| `activation/<hex>` | `ActivationKey.defaultDirectory` (`ActivationKey.swift:29`) | `BoundedHTTPClient` `.activationKey` |
| `.well-known/apple-app-site-association` | Nothing today. The app has no associated-domains entitlement, and iOS does not fetch the file from a project path | — |

Not on Pages, but also read by shipped builds:

- `raw.githubusercontent.com/straff2002/OpenGlasses/main/OpenGlasses/Sources/Resources/Translations`
  (`LocalizationManager.swift:45`): downloadable languages. There is no redirect for this host. The
  files stay at that path on the public `main` for as long as a supported build reads them.
- `github.com/straff2002/OpenGlasses/issues/new` (`DiagnosticsReportBuilder.swift:86`) and the
  OpenRouter `HTTP-Referer` (`LLMService.swift:2056`).
- The developer support address (`DiagnosticsReportBuilder.supportEmail`), a personal mailbox, is the
  Plan FV fallback for personal phones and is also on `support.html`, `privacy.html` and
  `SECURITY.md`.

**How the app follows a redirect** (`Services/Security/BoundedHTTPClient.swift`): the client handles
redirects itself, **at most 3 hops**, and refuses a redirect that weakens transport
(`insecureRedirect`), so any `https → http` hop fails the fetch. Each profile accepts a fixed set of
MIME types: catalogs `application/json`, packs zip or octet-stream, activation files `octet-stream`
or `text/plain` (HTML is read as "no such key"). So the redirect has to be HTTPS all the way, take at
most three hops, and leave the final `Content-Type` unchanged. **A missing activation file must
still come back as an HTML 404,** not as a redirect to the homepage.

**Licensing today.** A licence code is `base64(payload JSON).base64(Ed25519 signature)`. The app
checks the signature over the **raw payload bytes** against one embedded public key
(`LicenseService.productionPublicKeyBase64`), then decodes with ISO-8601 dates. The private key is
kept off the repository and read from a 0600 file by `Scripts/generate-field-license.swift`, which
also mints CT 3a activation keys and their sealed files. A code carries an expiry and nothing can
revoke it. Organisations enrolled through a profile can be revoked at the profile's address (CT PR
2b/PR 4). The pack catalogs are signed with a **different** key. The desktop licence and FY's add-on
list are being added in the desktop thread, not here.

---

## Invariants

- **I1 — Legacy paths are permanent.** Every path in *Legacy paths* below answers at the same path
  on avenkin.com, with the same bytes (or a re-signed successor for catalogs) and the same
  `Content-Type`, for as long as any supported build can read it. A redesign may add paths. It never
  moves one of these.
- **I2 — The domain is load-bearing.** Once the redirect is on, every shipped build depends on
  avenkin.com resolving. The registration stays on auto-renew with registrar lock and two-factor
  sign-in on the registrar account.
- **I3 — The apex stays on GitHub Pages.** Moving the apex to another host would probably end the
  github.io redirect that old builds depend on. Dynamic things go on subdomains (`api.`,
  `downloads.`), never on the apex.
- **I4 — No third-party requests from any page.** No analytics, tag managers, hosted fonts, embedded
  video, social widgets or remotely loaded scripts. Payment happens on the provider's hosted checkout
  page, reached by a link, not embedded.
- **I5 — The app never steers a consumer to buy outside the App Store.** Pages the app links to
  (privacy, support, docs) carry no purchase links. Selling to organisations stays enterprise
  activation (EE; App Review Guideline 3.1.3(c)).
- **I6 — Signing keys never touch the site repository or the site build.** Four keys, each with one
  job: the licence key, the pack-catalog key, the org-profile key (CT) and the new desktop
  update key (P3). None of them is ever reachable from the Pages workflow.

---

## Legacy paths (must be preserved)

| Path on avenkin.com | Why it must stay |
|---|---|
| `/` and `/index.html` | The Meta registration's current target; must keep completing an auth bounce (see *The Meta auth redirect*) |
| `/privacy.html` (and its fragment ids: `#retention`, `#contact`, `#medical`, …) | Shipped builds' Settings link; App Store Connect; `support.html` links fragments |
| `/support.html` | App Store Connect support URL |
| `/about.html` | App Store Connect marketing URL |
| `/skillpacks/catalog.json` | Default catalog URL in every shipped build |
| `/skillpacks/packs/com.openglasses.barista-1.0.0.zip`, `/skillpacks/packs/com.openglasses.focus-1.0.0.zip` | Named inside the signed catalog payload. Any pack zip ever listed in a published catalog stays too |
| `/vaultpacks/catalog.json` | Default vault-catalog URL in every shipped build |
| `/activation/<64-hex>` and the HTML 404 for unknown names | Every activation key ever issued; shipped builds look nowhere else |
| `/.well-known/apple-app-site-association` | Keeps the path; its contents narrow in P2 (see *Universal links*) |
| `/LICENSE`, `/README.md`, `/README.zh-CN.md`, `/docs/BUILDING.md`, `/docs/CAPABILITIES.md`, `/docs/field-assist-vault-guide.md`, `/docs/field-assist-vault-guide.pdf`, `/docs/skillpack-authoring.md`, `/docs/webrtc/expert-client.html`, and the other `docs/` files on today's allowlist | Linked from the READMEs and from outside; cheap to keep |
| Outside Pages: the `Translations` files on the public repository's `main` | Read over `raw.githubusercontent.com` by shipped builds, with no redirect |

These paths live in a checked list, `Scripts/site-legacy-paths.txt`, from P2 on. The staging script
fails if any of them is missing from the staged site (see *Tests*).

---

## Site map

Structure first; copy and design are P2/P5 work. New pages use directory-style paths (`/office/`);
legacy pages keep their `.html` names, and a directory alias may point at them.

| Path | Page | Phase | Notes |
|---|---|---|---|
| `/` | **Home** — what Avenkin is: a private AI assistant that goes where you are (phone, watch, glasses; glasses are one device among several); Field Assist for trades; Avenkin Office for the organisation; the privacy stance in one paragraph | P2 | Keeps the Meta auth forwarding (below) |
| `/app/` | **The phone app** — features, supported devices, App Store link (badge as a local image), requirements | P2 | `about.html` stays and links here (or becomes this page's content at its old path) |
| `/field-assist/` | Field Assist — solo in the app; teams and enterprise by licence | P2 | |
| `/office/` | **Avenkin Office** — what it does for an organisation, how phones connect, what stays on the office's own computer | P2 | Copy follows FX: no vendor-hosted server |
| `/office/download/` | **Download** — macOS and Windows builds, version, release date, system requirements, SHA-256 checksums, signature and notarisation details, how to verify, release notes link, previous versions | P3 | Links to binaries on `downloads.` or the release repository |
| `/office/releases/` | Release notes, newest first, one anchor per version | P3 | The updater's "what's new" links here |
| `/office/updates/<channel>.json` | Update manifest (machine-readable) | P3 | See *Release hosting and updates* |
| `/pricing/` | **Plans** — structure only in this plan: the phone app (App Store); Field Assist solo (App Store) and team/enterprise (licence); Medical Compliance (App Store); Avenkin Office (per organisation, licence); add-ons (per office); accessibility is free and never a purchase | P2 (structure), P4 (buy links) | Never linked from inside the iOS app (I5) |
| `/licensing/` | **Licensing** — buy, manage, activate. What a licence code and an activation key are; that codes work offline; renewal is a new code; how organisation enrolment works; lost-code re-issue; who to contact | P4 | |
| `/licensing/activate/` | How to activate on the phone (typed key, scanned code) and in Office (setup file) | P4 | Instructions only, no form. Activation happens in the apps |
| `/privacy.html` | **Privacy policy** covering the phone app, Avenkin Office and the website itself (and the payment provider as processor once P4 lands) | P2 | Legacy path. Moves in the same PR as the in-app privacy copy (FY D8, Plan DQ) |
| `/terms/` | Website terms of use | P2 | |
| `/terms/office/` | **Avenkin Office licence agreement (EULA)** | P3 (before the first download) | Needs legal review |
| `/terms/licences/` | Terms for organisation licences: seats as recorded, term, renewal, re-issue, refunds (with the payment provider's terms of sale) | P4 | Needs legal review |
| `/source/` | **Licence terms for the source-available phone app**: plain summary of BSL 1.1 as it stands (non-commercial use permitted; commercial use needs a licence; change date 2030-03-24 to Apache 2.0), a link to `/LICENSE` and the repository | P2 | Never says "open source" |
| `/security.html` | **Security and responsible disclosure**, from `SECURITY.md` | P2 | |
| `/.well-known/security.txt` | RFC 9116: `Contact: mailto:security@avenkin.com`, the repository's private-advisory link, `Policy:`, `Expires:`, `Preferred-Languages: en`, `Canonical:` | P2 | Added to the stage allowlist deliberately |
| `/support.html` | **Support and contact** — support@, licensing@, security@; how to send a support report from the app (FV); who to ask on an organisation phone (your office, not the developer) | P2 | Legacy path |
| `/docs/…` | **Guides**: Field Assist vault guide (HTML from the existing markdown/PDF), organisation setup, Office administrator guide, activation, troubleshooting, supported devices | P5 | Existing `docs/` paths stay |
| `/auth/meta/` | Meta auth redirect page (moved) | P2 | See next section |
| `/translations/…` | Downloadable language files for new builds | P1 | Copied from the repository's `Translations` folder by the stage script |
| `/add-ons/` | Add-ons catalogue: each add-on, what it does, the Office version it needs | Later | Per-office entitlements (FY) |
| `/account/` | Account portal (see *Later*) | Later | Would be on `api.`/`account.`, not Pages |
| `/404.html` | Not-found page — **must return HTTP 404 with `text/html`** | P2 | The activation resolver relies on it |

---

## The Meta auth redirect

**Move it to `/auth/meta/`, and let `/` keep forwarding until the portal is confirmed.**

1. **P0 records** exactly which URL the Meta developer portal registration names, and what a real
   bounce looks like: which query and fragment keys arrive (names only; token values are never
   logged or written down), and whether the flow still completes once the page is served from
   avenkin.com with pathname `/`.
2. **P2 adds `/auth/meta/index.html`.** Same script, with one change: it builds the scheme URL from
   a **fixed** path (whatever P0 showed works: the historical `/OpenGlasses/`, or none) plus the
   query and fragment. It no longer derives the path from wherever the page happens to be served.
   No text or button on it names the product until FY's P1 ships. After that it says Avenkin.
3. **`/` becomes the homepage with a small inline forwarding check at the top.** If the query or
   fragment carries the auth keys P0 recorded, it forwards to the same scheme URL `/auth/meta/` would
   build, before any content renders. Otherwise it renders the homepage. The check sends nothing
   anywhere and stores nothing. It stays after the portal change: it costs nothing, and it covers a
   registration that was never updated or a bookmarked link.
4. **The owner updates the portal** to `https://avenkin.com/auth/meta/`, then runs a full
   registration from a clean install. The check passes when the app registers, and when the same
   happens with the old URL (via `/`).
5. **Universal links, later.** With avenkin.com at the domain root, `/.well-known/apple-app-site-association`
   is fetchable by iOS for the first time. A later build could add `applinks:avenkin.com` and receive
   `/auth/meta/…` directly: the app delegate already passes `webpageURL` to `handleUrl`. **Before
   any build carries that entitlement,** P2 narrows the file's `paths: ["*"]` to the auth path (and
   any deliberate deep-link paths). Otherwise every link on the marketing site would open the app.
   This is open question 6.

---

## Mac App Store or direct download?

**Recommendation: direct download for v1** — a Developer ID-signed, notarised and stapled disk image
for macOS and a code-signed installer for Windows, both from `/office/download/`, both updated by the
app's own signed updater. Reconsider the Mac App Store after v1 for discoverability, as a second
channel, only if the constraints below have become cheap.

The reasons, weighed:

| Consideration | Mac App Store | Direct download |
|---|---|---|
| **Windows** | Not applicable; Windows needs a direct download and an update channel anyway | One pipeline, one updater, one release page for both platforms |
| **Sandbox** (Guideline 2.4.5(i): "must be appropriately sandboxed") | The Office bundles sidecar helper binaries and runs LAN sync and discovery services. Every helper must be signed into the bundle and sandboxed with inherited entitlements; incoming LAN connections, local network discovery and the content store all need entitlements and testing. Some of that may not fit at all | Hardened runtime plus notarisation; helpers signed with the same Developer ID |
| **Background work** (2.4.5(iii): no processes that keep running after quit without consent) | A sync service that should keep phones' work flowing needs explicit consent UI and a design review against this rule | Same consent is good practice, but no review gate |
| **Licence keys** (2.4.5(vi): may not "require license keys, or implement their own copy protection") | The Office is unlocked by a vendor-signed organisation licence and setup file. On the Mac App Store that conflicts directly. The in-app purchase rules (3.1.1) would have to be reconciled with the enterprise exception (3.1.3(c)) | Licence files sold directly to organisations are the whole model |
| **Updates** (2.4.5(vii): "must use the Mac App Store to distribute updates") | Store-managed only. Every fix waits for review | The in-app updater, a signed manifest on avenkin.com, releases on the owner's schedule, and rollback in minutes |
| **Review latency** | Every v1 fix waits for review, for a fast-moving product | None. Notarisation is automated and usually takes minutes |
| **Signing identity** | App Store distribution under the individual developer account | Developer ID under the same **individual** account: allowed, but Gatekeeper and the certificate show the owner's personal name, not the company (open question 3) |
| **Discoverability and trust** | Store listing, store search, familiar install | Must be earned: the download page, checksums, a clear publisher name, and notarisation so Gatekeeper opens it without warnings |
| **Payment** | Apple's in-app purchase for anything unlocked in the app | Merchant-of-record checkout or invoice (P4) |

Guideline numbers and quotes were checked against Apple's published App Review Guidelines on
2026-09-29. Re-check them before the decision is reopened.

**Windows signing.** An unsigned or newly signed installer triggers SmartScreen warnings until the
signature builds reputation. Code-signing certificates now require the private key in a hardware
token or a cloud signing service, and an organisation-validated certificate is issued to the company
(Skunkworks NZ Ltd), which needs company validation. The options are open question 4. The v1
decision can be made without resolving them, because unsigned preview builds are never published.

---

## Release hosting and updates (Avenkin Office)

**Where things live:**

- **The manifest lives on avenkin.com** (`/office/updates/stable.json`, later `preview.json`). The
  app bakes in this address, and it is under the owner's domain for good.
- **The binaries live elsewhere.** They are too large for Pages, and Pages is not meant as a download
  host. Two options, both cheap: (a) the releases of a **public, release-only repository** that
  holds binaries, notes and checksums and no source (the private desktop repository's releases
  cannot be downloaded publicly); or (b) **object storage with free egress** behind
  `downloads.avenkin.com`. The manifest names full artefact URLs, so moving from (a) to (b) later
  is a manifest change, not an app change. **Lean: (a) for v1**: no new account, stable URLs, and
  download counts for free.

**Manifest and signatures.** The desktop framework's updater expects a small JSON manifest (version,
publication date, notes, and per platform: URL and signature). Each artefact is signed with an
**update key** (Ed25519, its own key, kept off every repository like the licence key), and the app
refuses an artefact whose signature does not verify against the public key built into it. The
manifest itself is trusted over HTTPS. The app refuses to "update" to a version equal to or lower
than the one installed. The contract is a schema plus fixtures (a valid manifest, a bad signature, a
downgrade, an unknown platform), tested in the desktop repository.

**Checksums and verification.** Each release publishes `SHA256SUMS` beside the artefacts, and the
download page repeats the sums and explains how to check them (`shasum -a 256`,
`Get-FileHash`), how to check notarisation (`spctl -a -vv`, `stapler validate`), and whose name
the Windows signature should show.

**Pipeline (local; desktop CI is Linux-only and cannot sign or notarise):**

1. Tag in the private repository. Build on the owner's Mac (and on a Windows machine or VM for the
   installer).
2. macOS: sign every sidecar binary and the app with hardened runtime and the Developer ID
   certificate, build the disk image, submit to notarisation, staple, verify with `spctl` and
   `stapler`.
3. Windows: sign the executable, helpers and installer with the chosen signing method. Verify the
   signature and the publisher name.
4. Sign each artefact with the update key, write `SHA256SUMS`, draft the release notes.
5. Upload the artefacts. Then, in a separate step, publish the manifest and the download page (a
   site-only change to this repository). **The manifest goes last.** An app never sees a version
   whose files are not yet downloadable.
6. A release script does steps 4–5's bookkeeping and refuses to publish a manifest that names an
   artefact whose sum or signature does not verify.

**Rollback.** Never down-version. To pull a bad release, point the manifest back at the previous
good version (apps already on the bad version stay there, because downgrades are refused), then ship
a fix as a new, higher version. The same script does the pull, so rollback is one command plus a
Pages deploy of a few minutes. Previous versions stay listed on the download page for manual
reinstall.

---

## Licensing on the web

**Who buys what, where:**

| Product | Where it is bought | What the buyer gets |
|---|---|---|
| Avenkin (phone app), Field Assist solo, Medical Compliance | App Store only (in-app purchase) | Nothing from the website; the site links to the App Store |
| Field Assist team / enterprise | Website checkout (merchant of record) or invoice | A licence code and a short activation key (CT 3a), by email |
| Avenkin Office | Website checkout or invoice | An organisation licence and setup package (FX: vendor-signed profile plus office licence) |
| Office add-ons (later) | Website, against an existing office licence | A re-issued office licence whose add-on list includes it (FY) |

**Payment provider.** Use a **merchant-of-record** provider, which sells as the seller of record and
handles GST/VAT and sales tax for a New Zealand company selling worldwide, plus receipts, refunds and
a customer billing portal. Buyers pay on the provider's hosted checkout page, linked from
`/pricing/`, so no card data ever touches our pages (I4). Enterprise stays on invoice. Which provider
is open question 2.

**Phase A: manual issuance (P4a, no service).**

1. The buyer pays by checkout link or invoice. The provider notifies licensing@.
2. The owner mints with `Scripts/generate-field-license.swift` (with `--activation-key` where a key
   is wanted), exactly as today, and records the issuance in the ledger format EI defines (a
   spreadsheet is acceptable at first; never the code itself, only its digest and `licenseIDHash`).
3. The sealed activation file is published by a site-only commit to `activation/`. The stage gate
   already refuses anything else there.
4. The owner emails the code and key from licensing@, with a link to `/licensing/activate/`.

This is enough for the first customers, and it stays the fallback whenever the service is down.

**Phase B: automated issuance (P4c).**

```
checkout (provider, hosted) ──webhook──▶ api.avenkin.com (serverless function)
      verify webhook signature → idempotency on the provider's order id
      → build payload (the shared pure core) → sign (licence key, isolated)
      → mint activation key + sealed file → append ledger row (hash-chained, no code)
      → email code + key from licensing@ → publish sealed file to activation/
```

- **Payload building reuses EI's pure core.** `(order, product, now) → LicensePayload`: tier,
  plan, seats, term, packs, add-ons and profile. Signing is a separate step, so the policy is testable
  without a key. A web order is a partner grant whose partner is the vendor.
- **Format compatibility is a contract, not a hope.** The app verifies the signature over the raw
  payload bytes, so a signer in another language can produce valid codes. But its JSON must decode
  in the app. **Traps:** Swift's `.iso8601` strategy rejects fractional seconds (a JavaScript
  `toISOString()` date is `.malformed`), and unknown keys are ignored silently (a misspelt claim
  grants nothing, without an error). The activation key must mirror `ActivationKey`: Crockford
  alphabet, check character, `openglasses.activation-id.v1` file naming, and HKDF info
  `openglasses.activation-key.v1`. These domain strings are frozen by FY D2 and never renamed.
- **Publishing the sealed file.** The function commits `activation/<hex>` to the public repository
  with a token scoped to that one repository's contents, and the Pages deploy publishes it. The email
  says a new key can take a few minutes to start working. The stage gate rejects anything but a
  64-hex name. A later build could also try `api.avenkin.com/activation/` first. That is not needed
  for v1.
- **Lookup and resend.** A form on `api.` takes an order email and sends a message to **that
  address** only; the page never shows a licence. Because the ledger never holds a code (EI),
  "resend" is a **re-issue**: a new code and a new activation key, a ledger row with `replaces`, and
  the old key's sealed file deleted. That stops new activations with the old key. Phones already
  activated keep working until the old code's expiry.
- **Refunds and chargebacks.** The provider's webhook marks the ledger row and deletes the
  activation file. The code itself cannot be recalled offline. That is why organisation terms are
  annual and renewal is a new code (EE). An enrolled organisation can also be revoked at its profile
  address (CT).
- **Revocation and expiry, honestly.** A bare licence code is a bearer credential with an expiry. There is no
  revocation list, and this plan does not add one. Real revocation exists only for organisations
  enrolled through a profile (CT PR 2b / PR 4) and for Office bindings (FX). The licensing page says
  so in plain words.
- **Add-ons.** An add-on is a named entry in the office licence's add-on list (FY *Add-on
  entitlements*). Buying one re-issues the office licence with the longer list. The office pushes it
  to its phones through the profile. The website never grants anything the licence does not carry.

**The signing key.**

- **Never in any repository, CI log, environment dump or chat.** The service holds it in a managed
  key service that signs Ed25519 without exporting the key, if the chosen host offers one. If not, it
  is an encrypted secret bound to one isolated signing function that nothing else can call. The web
  tier never reads it.
- **Least privilege.** The signing function signs payloads the policy produced, and nothing else. The
  webhook secret, the repository token and the email credential are separate secrets, each scoped to
  one job.
- **Audit.** The EI ledger is append-only and hash-chained, with one row per signature, so a
  compromise is enumerable: which codes, when, for whom.
- **Rotation.** Today the app embeds **one** public key. Rotating it (as on 2026-09-03) makes every
  code minted with the old key fail on new builds. Before the key moves to a host, decide whether the
  app should also accept a pre-published *next* key, so a rotation does not strand paying customers.
  EI lists a second embedded key as a non-goal, so this is open question 7.
- **Blast radius.** A compromised service can mint codes, but it cannot change how any phone or
  office verifies them. Terms bound the exposure, and the manual generator keeps sales going while
  the service is offline.

---

## Email and the domain

- **Addresses:** `support@` (FV support reports, general help), `licensing@` (orders, licence
  delivery, renewals), `security@` (disclosure; in `security.txt` and `SECURITY.md`), `privacy@` (the
  privacy policy's contact, for requests under the Privacy Act 2020). Aliases can land in one mailbox
  at first. Nothing is sent from a `no-reply` address.
- **Mail authentication:** MX at the chosen mail host; **SPF** listing only the mail host and the
  transactional sender (and the payment provider only if it sends as avenkin.com); **DKIM** for each
  sender; **DMARC** starting at `p=none` with aggregate reports, moving to `quarantine` and then
  `reject` once the reports are clean. Subdomains that never send get a null SPF record.
- **Certificates:** a **CAA** record, if one is added, must allow the issuer GitHub Pages uses
  (Let's Encrypt), or Pages HTTPS stops renewing, plus whatever the `api.`/`downloads.` hosts use.
- **Plan FV:** the developer fallback address becomes `support@avenkin.com` in P1, **after** P0 has
  shown the mailbox receives mail with an attachment of a realistic size. The rule that an
  organisation phone never falls back to the developer does not change.
- **Existing copy** that names the personal address (`support.html`, `privacy.html`, `SECURITY.md`)
  moves to the role addresses in P2.

---

## Website privacy and hardening

- **No third-party requests (I4).** Fonts and images are self-hosted. The App Store badge is a local
  file with a plain link. No video embeds (host a file or link out). A site check enforces this
  (see *Tests*).
- **Measurement: none at launch.** App Store Connect and release download counts answer the
  questions that matter. If page counts are wanted later, the options are a first-party, cookieless
  counter on `api.` (no IP retention, no identifiers, aggregate only), disclosed on the privacy page
  in the same PR.
- **Headers.** Pages does not let a site set response headers. A Content-Security-Policy goes in a
  `<meta>` tag (`default-src 'self'`, with the inline redirect scripts allowed by hash). HSTS and other
  header-only controls wait for a host that allows them. That is not a reason to move the apex (I3).
- **Pages terms.** GitHub's Pages terms rule out using Pages mainly for commercial transactions or as
  a download host. So the site describes the product and links out: checkout is on the provider,
  binaries on the release repository or `downloads.`. Re-read the terms before P3 and P4 (risk R6).

---

## Phases

### P0 — Owner steps: DNS, domain, HTTPS, redirect verification (no code)

1. **Baseline first.** Before any change, record for every legacy path its status, `Content-Type`
   and SHA-256 from `straff2002.github.io/OpenGlasses/…`, and record a Meta registration end to end
   (key names only, never token values). Keep the baseline with the P0 record; P2's checks reuse it.
2. **Verify the domain** for the account's Pages (TXT record), which guards against takeover.
3. **DNS:** apex `A`/`AAAA` to GitHub Pages' published addresses; `www` `CNAME` to
   `straff2002.github.io`; short TTLs during the cutover. Registrar lock and auto-renew on.
4. **Set the custom domain** to the apex `avenkin.com` (not `www`: one fewer hop for old builds).
   Wait for the certificate, then turn on **Enforce HTTPS**. The redirect must never offer an
   `http://` hop.
5. **Verify every legacy path through the redirect** (script, kept for P2 regression):
   - `curl -sS -o /dev/null -w '%{http_code} %{redirect_url}'` on each github.io address shows `301`
     to `https://avenkin.com/<same path>`, with the query string kept.
   - `curl -sSL --max-redirs 3 -w '%{num_redirects} %{content_type}'` shows at most 2 redirects,
     the same content type as the baseline, and a byte-identical body (SHA-256).
   - An unknown `activation/<64 hex>` gives `404` with `text/html`, before and after.
   - `http://avenkin.com/…` and `https://www.avenkin.com/…` redirect to `https://avenkin.com/…`.
   - Both signed catalogs verify with their public key after being fetched through the redirect, and
     both pack zips match the `sha256` in the catalog payload.
6. **Verify with a shipped build** (the current App Store or TestFlight build, on a clean phone, no
   GitHub login): Settings → privacy opens; the skill-pack catalog lists and one pack installs; the
   vault catalog loads; a test activation key minted for the owner's own short-expiry test licence
   resolves; a Meta registration completes (records the pathname behaviour for P2); a downloaded
   language installs.
7. **Mail:** MX, SPF, DKIM and DMARC in place; each role address receives mail, including one with
   an attachment the size of a support report.
8. **App Store Connect:** the privacy, support and marketing URLs point at `https://avenkin.com/…`
   (same paths). Fields that can only change with a version submission move with the next one.
9. **Meta portal:** record the registered URL(s). Do **not** change them in P0.

**Rollback:** removing the custom domain restores github.io serving. Check this once, early, while
TTLs are short.
**Exit:** every check in 5–7 passes and the results are recorded. Any failure in 5 or 6 means
rollback, not a patch.

### P1 — One base URL in the app (one PR, small; may land before FY's rename)

- A single `SiteAddress` (or `Config.siteBaseURL`) constant, `https://avenkin.com/`. It derives
  privacy, support, the skill and vault catalog defaults, the activation directory, translations
  (`/translations/`) and the support page that replaces the GitHub issues link. User overrides of the
  catalog URLs still win.
- The stage script publishes `OpenGlasses/Sources/Resources/Translations` at `/translations/`
  (allowlisted explicitly) in the same PR, so the path exists before a build reads it.
- OpenRouter `HTTP-Referer` → `https://avenkin.com`. `DiagnosticsReportBuilder.issueBaseURL` → the
  support page, and `supportEmail` → `support@avenkin.com` (after P0 step 7), with
  `DiagnosticsReportBuilderTests` updated.
- **Guard test:** no `github.io`, `githubusercontent.com` or `github.com/straff2002` string in
  `OpenGlasses/Sources` (and the extension and watch targets) outside a short, commented allowlist.
  **Pin test:** each derived address equals base + the legacy relative path (`privacy.html`,
  `skillpacks/catalog.json`, `vaultpacks/catalog.json`, `activation/`), so a base-URL change can
  never move a path.
- **Acceptance:** tests green; a Release build; on a device, the P0 step 6 checks pass again with
  the new build reading avenkin.com directly (no redirect).

### P2 — Site restructure (one PR)

- Site sources move to a `site/` folder staged to the root; legacy files keep their published paths.
  Hand-written HTML with one shared stylesheet, or a very small generator run in `pages.yml`; no
  framework, no client-side rendering.
- The homepage at `/` with the auth forwarding check; `/auth/meta/` with the fixed-path scheme URL;
  `/404.html` (HTML, status 404); `/app/`, `/field-assist/`, `/office/`, `/pricing/` (structure, no
  buy links yet), `/source/`, `/terms/`, `/security.html`, `/.well-known/security.txt`; the privacy
  policy extended to Office and the website (same PR as any in-app privacy copy change); role email
  addresses everywhere.
- `apple-app-site-association` narrowed to explicit paths.
- **Acceptance:** the site checks pass (see *Tests*); the P0 step 5 script passes unchanged; a Meta
  registration completes via the old URL (`/`) and via `/auth/meta/`; **then** the owner switches the
  portal and repeats the registration from a clean install.

### P3 — Avenkin Office download page and update hosting (one PR here; pipeline in the desktop repository)

- `/office/download/`, `/office/releases/`, `/office/updates/stable.json` (empty until the first
  release), `/terms/office/` (after legal review), and the release-only repository or `downloads.`
  host.
- **Acceptance:** on a clean Mac, the disk image downloads, opens with no Gatekeeper warning, and
  `spctl`/`stapler` confirm notarisation. On a clean Windows machine, the installer shows the
  expected publisher, and SmartScreen's behaviour is recorded. Checksums on the page match the files.
  Version N−1 updates to N through the manifest. A tampered artefact and a lower-version manifest are
  both refused. A rollback rehearsal restores the previous manifest within one deploy.

### P4 — Licensing on the web

- **P4a (docs and pages, one PR):** `/licensing/`, `/licensing/activate/`, `/terms/licences/`,
  checkout or invoice links on `/pricing/`, and the manual runbook (mint, ledger row, publish the
  activation file, email). **Acceptance:** a real order from payment to an activated phone (and,
  once FX allows it, an activated office) run end to end by the owner.
- **P4b (headless core, one PR):** the shared issuance core and the contract fixtures below; the
  generator becomes a caller of it (as EI P1 intends). **Acceptance:** fixture tests green in the
  app suite and the core's own tests.
- **P4c (service, mostly outside this repository):** the webhook function on `api.avenkin.com`,
  isolated signing, the ledger, the resend/re-issue form, refund handling. In this repository:
  `docs/licensing/web-issuance.md` (operational contract, key handling, recovery when the service
  is down). **Acceptance:** a test-mode checkout issues a code signed by a test key, which the app
  fixture verifies; replaying the webhook issues nothing twice; a refund deletes the activation file;
  switching the service off leaves the manual path working.

### P5 — Documentation and support content (one or more doc PRs)

- The Field Assist vault guide as a page, organisation setup, the Office administrator guide,
  activation, troubleshooting, supported devices, and an FAQ. The manual-text extractor gets a
  public download location on the site, allowlisted deliberately. Today the guide points at a raw
  GitHub URL under `Scripts/`, which the stage denylist rightly keeps off the site.
- **Acceptance:** the link check passes; every guide the app or Office links to exists; the support
  page answers "who do I ask" differently for personal and organisation phones (FV).

### Later

- **Add-ons catalogue** (`/add-ons/`), once the first add-on exists and the licence format carries
  the list.
- **Account portal:** licences by email sign-in (magic link to the order address), setup-package
  download for an office, renewal, and a link to the provider's billing portal. It runs on `api.`,
  never on Pages. It holds no licence codes (re-issue, as above).
- A translated site, a status page, and universal links (open question 6).

---

## Tests (the headless core)

**Site checks** (run by the stage script or a sibling in `pages.yml`, and runnable locally):

- **Legacy paths:** every line of `Scripts/site-legacy-paths.txt` exists in the staged tree. A
  removed or renamed legacy page fails the deploy.
- **Activation gate:** unchanged, plus a fixture showing that a non-hex file under `activation/` is
  still denied.
- **No third-party requests:** no `src`, `href` to a stylesheet, `@import`, or `url()` pointing off
  the site; outbound anchor links only to an allowlist (App Store, the payment provider's checkout,
  the repository, provider privacy policies already listed on `privacy.html`).
- **No purchase links on app-linked pages:** `privacy.html`, `support.html`, `/docs/…` and
  `/translations/` contain no link to `/pricing/`, `/licensing/` buy anchors or the checkout host
  (I5).
- **Internal links resolve** in the staged tree, fragments included.
- **Auth forwarding:** a small script test of the forwarding function: given a path, query and
  fragment, it produces the expected scheme URL; without the auth keys, it does nothing.
- **404:** the staged `404.html` exists. P0's script checks the live status code.

**App (P1):** the host guard, the path pins, `DiagnosticsReportBuilderTests` updated.

**Licensing contract (P4b):** fixtures of payload input → code under a **test** keypair, produced by
the issuance core and by any non-Swift signer, all decoded by `LicenseService.decode` in the app
suite. A fractional-second date is refused (documents the trap). An unknown claim is ignored. Tier
resolution fails safe. Activation-key fixtures (key → file name, sealed file → code) open in
`ActivationKey` tests. `licenseIDHash` of a minted code equals the ledger row's.

**Update manifest (P3, desktop repository):** schema fixtures; bad signature, downgrade and unknown
platform all refused.

---

## Non-goals

- Moving the apex off GitHub Pages, or a server-rendered site.
- Selling phone-app products on the web, or any purchase path inside the iOS app other than the
  App Store.
- A seat server, device binding, or a licence revocation list (EE and EI's positions stand).
- Hosting organisation data. Avenkin Office keeps it on the organisation's computer (FX); the website
  never sees jobs, manuals or reports.
- A relay for Office traffic. That belongs to FX and is not website work.
- Renaming any signing domain, bundle id or activation constant (FY D2).

---

## Risks

- **R1 — The redirect is not what we expect** (a lost query string, an extra hop, an `http://` hop,
  a changed content type). *Mitigation:* the P0 baseline and script; rollback by removing the custom
  domain.
- **R2 — The Meta auth page breaks when its pathname changes.** *Mitigation:* P0's live
  registration test; the fixed-path scheme URL in P2; `/` keeps forwarding.
- **R3 — The domain lapses or is hijacked,** and every shipped build loses catalogs, activation and
  privacy links at once. *Mitigation:* I2 (auto-renew, lock, two-factor, verified domain); P1 does
  not remove the dependency, so this stays a standing risk.
- **R4 — The GitHub redirect disappears** (a Pages setting changes, the repository is renamed,
  archived or made private). *Mitigation:* FY's rule that the public repository is never deleted or
  made private while it hosts the site; P1 so that current builds stop depending on the redirect.
- **R5 — The public repository stops receiving pushes** (FY moves work to the private repository),
  but it is the site's only publisher. *Mitigation:* FY's site-only push; the P4c function commits
  only `activation/`.
- **R6 — Pages terms and limits.** Commercial transactions and large downloads are not what Pages is
  for. *Mitigation:* checkout on the provider, binaries off Pages, the site describes and links.
- **R7 — Signing-key exposure** when issuance moves to a host. *Mitigation:* EI's isolation,
  least-privilege secrets, ledger, short terms, and the rotation decision made before automation.
- **R8 — Anti-steering.** A purchase link reachable from inside the iOS app could fail review.
  *Mitigation:* I5 and the site check.
- **R9 — An individual developer account on a company product.** Developer ID signatures show the
  owner's name. Moving to an organisation account later changes the Team ID, which affects keychain
  groups, App Group and entitlements for the phone app. *Mitigation:* decide before the first
  production Office release (open question 3).
- **R10 — Legal text written without review** (EULA, terms, privacy covering Office and payments).
  *Mitigation:* legal review before P3's first public download and P4's first sale.

---

## Open questions for Greig

1. **Mac App Store now or later?** Recommendation: later, as a second channel, once the sandbox, the
   background service and the licence-key rules (2.4.5(i), (iii), (vi), (vii)) are cheap to meet.
2. **Which payment provider?** A merchant of record (handles worldwide consumption tax, refunds and
   the billing portal) versus a plain payment processor plus our own tax handling. Lean: merchant of
   record. Enterprise stays on invoice either way.
3. **Developer account:** stay individual (Developer ID shows your name), or move to an organisation
   account for Skunkworks NZ Ltd before the first production Office release (needs a D-U-N-S number;
   see R9 for the phone-side cost)?
4. **Windows code signing:** an organisation-validated certificate on a hardware token, a cloud
   signing service, or both? It affects who can sign (only the machine holding the token) and how
   fast SmartScreen trust builds.
5. **Site copy before the app rename ships:** say "Avenkin" on avenkin.com from day one, with a
   plain "currently on the App Store as OpenGlasses" line, or keep OpenGlasses copy until FY P1?
   Legal pages must name the app as the store shows it on the day. Lean: Avenkin with the
   bridging line.
6. **Universal links on avenkin.com:** add `applinks:avenkin.com` in a future build so the Meta
   callback (and deliberate deep links) open the app directly? Requires the narrowed association
   file first.
7. **Licence-key rotation:** should the app accept a pre-published next public key before issuance
   moves to a hosted service, so a rotation does not strand customers? (EI treats a second key as a
   non-goal; this plan asks for the decision before P4c, not the change.)
8. **Translations host:** move downloadable languages to `/translations/` in P1 (recommended), or
   leave new builds on the raw GitHub URL?
9. **Binaries:** a public release-only repository (lean) or object storage behind `downloads.`?
10. **Measurement:** none at launch (lean), or a first-party cookieless counter disclosed on the
    privacy page?
11. **Legal review:** who reviews the Office EULA, the organisation licence terms, the website terms
    and the extended privacy policy, and in which jurisdictions beyond New Zealand?
12. **Mailboxes:** one shared mailbox with role aliases, or separate mailboxes per role from the
    start?
