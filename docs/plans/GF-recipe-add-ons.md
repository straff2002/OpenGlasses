# Plan GF — Recipe Add-ons (declarative, no-code skills with per-add-on permissions)

**Status:** 📝 Drafted (not scheduled), 2026-10-01; revised 2026-10-02 (organisation add-ons and
signed-only capabilities, below) — nothing built.
**Extends:** Plan [BX](BX-skill-packs.md) (signed skill packs; its P4 "JS handlers" is deferred).
**Related:** Plan [R](R-mcp-egress-and-tool-poisoning-screen.md) (egress screen, definition scanner),
Plan V (`MCPCatalog`), Plan DJ (composition floor, `OperationJournal`), Plan CT (org policy),
Plan [GO](GO-self-built-skills.md) (the agent authors recipes; depends on this plan),
Plan [HF](HF-office-stock-and-capture-contracts.md) (parts stock with Avenkin Office — not an add-on),
Plan [HG](HG-add-on-catalogue-and-premium-gating.md) (the catalogue, shelves and gating by pack).

---

## Revision 2026-10-02 — organisation add-ons and signed-only capabilities

Settled with the owner on 2026-10-02. Nothing below changes P0 or P1: the format, validator and
runner are built exactly as drafted. What changes is what comes before P2 ships, and what a
signature means.

**Two classes of add-on.**

| Class | Who signs | What it may hold |
|---|---|---|
| **Community** | nobody (a file, link or QR) | The four drafted permissions and nothing else: `network` to public HTTPS hosts, coarse `location`, write-only `memory`, `display` |
| **Signed** | the vendor, or an organisation (its administrator key, as verified through the organisation profile) | The four above, plus any **reserved capability** the signature covers |

**Reserved capabilities do not exist for unsigned files.** The validator refuses an unsigned file
that names one — it is not a permission the wearer can grant on a sheet. They are:

| Reserved capability | What it allows | Notes |
|---|---|---|
| `credentials` | Per-add-on secrets held in the Keychain and substituted into header values only | Flips drafted decision 5 from "later" to "with the organisation envelope", for signed add-ons only. A secret is never exported, never shown in the source view, never available to `say`, `remember` or `display`, and never substituted into a URL |
| `parts` | Read access to the vault parts index (`VaultPartsIndex`: number, description, fits, supersedes) | A new read step, to be specified with the envelope phase. Read-only; the vault's manuals are not reachable |
| `workRecord` | Write access to the job's work record (Plan EM): a part noted against the active task, a parts request raised | New write steps, to be specified. Every write is attributed to the add-on in the session log and follows EM's rule that base's answer is reported, never acted on |
| `office` | The Avenkin Office channel | Reserved here so no unsigned file can claim it; what rides the channel is Plan HF's contracts, not free-form add-on traffic |

**A signature covers the exact file.** A premium or organisation file that is copied and edited
no longer verifies, so it falls back to the community class and loses every reserved capability;
if it still names one, it does not install. This is what makes gating enforceable when the source
is readable: the thing gated is the capability, not the text. Plan HG builds the catalogue and
the pack-level entitlement on this.

**Organisation envelope (new phase P1b, before P2).** An organisation add-on arrives **by
reference, never embedded**:

- named by id and version in the Plan CT organisation profile, the way the profile already names
  skill packs and its vault pack (CT: a profile may reference a pack; it may not embed one), and/or
- delivered and signed through Avenkin Office over the signed-assignment channel Plan FX defines,
  with the same binding to organisation, office, enrolment and phone identity as a manual
  assignment.

It is installed at enrolment like a vault pack. The technician sees no approval sheet (the
organisation's signature and the profile review are the trust decision), cannot edit it (the
source view is read-only and says who manages it), and cannot remove it; removing the profile
removes it and its stored credentials. Updates follow the reference: a new signed version
replaces the old one without a diff sheet, and the change is written to the session audit log.

**Organisation policy is more than an off switch.** Plan CT gains three ceilings, each a
subtraction in the usual way:

1. add-ons disabled (the whole feature);
2. no community add-ons (signed only, from any signer the phone trusts);
3. organisation-signed only (nothing from the public catalogue either).

**What an add-on still cannot do.** Add-ons do not reach private or LAN addresses — the
`BoundedHTTPClient` address check stands for signed add-ons too — and Avenkin Office exposes no
HTTP surface to the phone: FX replaced HTTP delivery with signed messages over the embedded sync
transport. So a live parts check against the firm's own stock is **not an add-on**; it is Plan
[HF](HF-office-stock-and-capture-contracts.md). Add-ons remain the answer for systems outside
Office, for example a supplier's stock API called with an organisation-held key.

**MCP stays the alternative.** An organisation that would rather run one MCP server than maintain
several add-ons uses P4's MCP-entry add-on; the envelope above applies to it unchanged.

**Order.** P0 → P1 → **P1b (organisation envelope and signed-only capabilities, pure)** → P2 → P3
→ P4. P1b adds `AddOnSignature` (verification over the exact file bytes, reusing the skill-pack
signature scheme), `AddOnTrustClass` (`community` / `vendorSigned` / `organisationSigned`),
`AddOnReservedCapability` and its validator rules, `AddOnPolicy` (the three ceilings, pure over an
injected policy value), and the reference shape a profile or an Office assignment carries. Tests:
`AddOnSignatureTests` (an edited byte demotes to community; a demoted file naming a reserved
capability is refused), `AddOnReservedCapabilityTests`, `AddOnPolicyTests` (each ceiling against
each class), `AddOnReferenceTests`. The Keychain store for `credentials`, the new step types and
the enrolment install land with P2, where the store and the tool wrapper are.

---

## Trigger

Most useful small skills are "call one public API, pick two fields out, say a sentence":
currency, sunrise, air quality, sea state, a Wikipedia summary, nearby earthquakes. Today each is
either a native Swift tool (an app release) or a skill pack (a signed zip whose bindings can only
prompt, compose native tools, start a procedure or call the gateway; none can fetch a URL). A
wearer or a small author has no way to add one, and BX's answer (JavaScript handlers) is the
wrong trade for App Review and for trust.

## Outcome

An **add-on** is one JSON file anyone can write, read and share. It declares skills as a short
list of steps (fetch, extract, decide, say) and the **permissions** it needs, none by default.
Installing always shows a plain-words sheet; updating never happens silently; every add-on's
source is visible and editable on the phone. It is data interpreted by a small, bounded engine,
not downloaded code.

## What exists today (verified 2026-10-01)

- **Skill packs:** `Models/SkillPackManifest.swift` (`SkillPackBinding`: `prompt`, `tool`,
  `procedure`, `gateway`), `Services/SkillPacks/` (`SkillPackStore`, `SkillPackValidator` with the
  Plan R screen at reject severity, `SkillPackSignature` ed25519, `SkillPackCatalog` signed
  envelope, `SkillPackSideload` for `openglasses://skillpack?url=`), `NativeTools/SkillPackToolWrapper`
  (`pack_<id>_<action>` names), `AppState.refreshSkillPackTools()`.
- **User HTTP-ish tools:** `CustomToolWrapper` runs a Siri Shortcut or URL scheme only; it has no
  HTTP step. `ToolDispatchSeam` (`Security/ToolEffectClass.swift`) has `native`, `mcpServer`,
  `gateway`, `custom`.
- **Hardened fetch:** `Security/BoundedHTTPClient.swift` — GET only, resolves once, refuses private
  addresses, parses redirects itself, per-profile byte/MIME/redirect/deadline caps (`qrContext`,
  `skillPack`, `signedCatalog`, …). `URLFetchGuard`, `EndpointPolicy`, `NetworkRouteRegistry`
  (`NetworkRoute`, `NetworkDataClass`), `MedicalEgressGuard`.
- **Screens:** `EgressScreen.evaluate(_:policy:)`, `ToolDefinitionScanner.scan(name:description:inputSchema:nativeNames:)`,
  `ToolDefinitionDigestStore`, `PromptInjectionPolicy.wrap(toolName:content:)`.
- **Extraction:** a dot-path `JSONPath` exists inside `AgentHarness/Adapters/CustomHarnessConfig.swift`
  (no array indexing). **MCP:** `MCPServerConfig` persisted in the Keychain (`Config.mcpServers`),
  `MCPAuthKind` `none/bearer/oauth/header`, `MCPCatalog`.

## The file (format `avenkin.addon/1`)

```json
{
  "format": "avenkin.addon/1",
  "id": "dev.frankfurter.currency",
  "name": "Currency",
  "version": "1.0.0",
  "author": { "name": "Jo Example", "web": "https://example.org" },
  "description": "Converts money between currencies using daily European Central Bank rates.",
  "icon": "dollarsign.arrow.circlepath",
  "coverage": ["*"],
  "slow": false,
  "permissions": { "network": ["api.frankfurter.dev"] },
  "skills": [{
    "name": "convert_currency",
    "description": "Use when the wearer asks to convert an amount of money, e.g. 'fifty euros in dollars'.",
    "parameters": {
      "amount": { "type": "number", "min": 0, "max": 1000000000, "required": true },
      "from":   { "type": "string", "pattern": "^[A-Z]{3}$", "description": "ISO 4217 code" },
      "to":     { "type": "string", "pattern": "^[A-Z]{3}$" }
    },
    "steps": [
      { "http": { "method": "GET", "as": "fx",
                  "url": "https://api.frankfurter.dev/v1/latest?amount={{amount}}&from={{from}}&to={{to}}" } },
      { "extract": { "from": "fx", "jsonpath": "$.rates.{{to}}", "as": "result" } },
      { "if": { "op": "empty", "var": "result",
                "then": [ { "say": "I couldn't find a rate for {{to}}." } ],
                "else": [ { "say": "{{amount}} {{from}} is {{result}} {{to}}." } ] } }
    ]
  }]
}
```

**Top level.** `format` (exact), `id` (reverse-DNS, ≤ 64 chars), `name` (≤ 30), `version` (semver),
`author.name`, `author.web` (https only, shown as its domain), `description` (1–2 sentences, ≤ 240
chars), optional `icon` (SF Symbol name, validated against a bundled allowlist), optional `coverage`
(ISO 3166-1 alpha-2 codes or `"*"`; outside coverage the skills are not declared to the model),
optional `slow` (the assistant says "one moment" first), optional `minAppBuild`, `permissions`, and
**either** `skills[]` (1–10) **or** `mcp`, never both. Unknown top-level keys reject the file (a
typo in `permissions` must not silently grant nothing or everything).

**Parameters** are flat: `string` (`maxLength` ≤ 200, default 100; optional `enum`, `pattern`),
`number`/`integer` (`min`/`max`), `boolean`. No objects or arrays, so the model cannot be asked to
pass "the conversation so far".

## Step semantics

Variables are strings in one flat namespace per run: the parameters, each step's `as`, and the
built-ins `{{now}}`, `{{today}}`, `{{locale}}`, `{{units}}`; `{{lat}} {{lon}} {{city}} {{country}}`
exist only with `location`. `{{name}}` is the only template form: no expressions, no filters.
**Escaping is by context, never by the author:** percent-encoded in URL paths and queries,
JSON-string-escaped inside a `json` body, CR/LF stripped in header values. A variable that is used
before any step defines it is an install-time error.

| Step | Shape | Behaviour |
|---|---|---|
| `http` | `method` GET/POST, `url`, optional `headers`, `json` or `form` body, `as` | https only; the URL is re-validated against the network allowlist **after** substitution and on every redirect (≤ 3); 15 s timeout; sets `<as>` (body), `<as>.status`, `<as>.ok`, `<as>.error`. Never throws; failure is data for `if`. |
| `extract` | `from`, `jsonpath` **or** `regex`, `as`, optional `fallback`, `limit` | JSONPath subset: `$`, `.key`, `['key']`, `[n]`, `[*]` (lists joined with ", ", ≤ `limit` ≤ 10). Regex: first capture group, pattern ≤ 200 chars, no backreferences, input ≤ 1 MB. Miss → `fallback` or empty. |
| `say` | template ≤ 500 chars after substitution | The skill's result, returned to the model as **data** (wrapped by `PromptInjectionPolicy`). At least one `say` must be reachable on every path (checked at install). |
| `remember` | `key`, `value` | Needs `memory`. Writes through the memory store under the add-on's own namespace and `BrainStore.shared.ingest(…, sourceKind: "addon")`, ≤ 3 per run. Add-ons can **never read** memory. |
| `display` | `kind` `text`/`list`/`markers`, `title`, `items` or `markers[{lat,lon,label}]` | Needs `display`. Phone card; glasses display if present (`GlassesDisplayService`); watch when Plan GM lands. Speech never depends on it. |
| `if` | `op` (`exists`, `empty`, `equals`, `notEquals`, `greater`, `less`, `contains`), `var`, `value`, `then`, `else` | Numeric ops parse both sides as numbers or take `else`. Nesting ≤ 3. |

Per skill ≤ 40 steps (counted through branches). No loops, no arithmetic, no string functions:
anything that needs them belongs in a native tool.

## Sandbox

- ≤ **3** HTTP requests per run, ≤ **1 MB** per response (JSON or text MIME only), **30 s** per run.
- **One run at a time per add-on**; a second call queues (at most 2 waiting, then "busy").
- `network` allowlist: ≤ 30 entries; each an exact host or `*.host` (one leading wildcard label,
  not over a public suffix — `*.github.io` and `*.co.uk` are refused); no IPs, ports, paths, query
  or userinfo. Private/reserved addresses are refused at connect time by the `BoundedHTTPClient`
  address check (DNS-rebinding safe), whatever the allowlist says.
- Forbidden headers: `Host`, `Content-Length`, `Connection`, `Transfer-Encoding`, `Proxy-*`,
  `Cookie`, `User-Agent` (the app sets its own). Ephemeral session: no cookies, no cache, no
  credentials.
- Parameter values pass `EgressScreen.evaluate` (policy `.redact`; a credential hit blocks the
  run) before substitution. Coarse location by default: `lat`/`lon` rounded to 2 decimals (~1 km).
- Responses reach the model only through `say`, framed as untrusted data. Add-on names and
  descriptions pass `ToolDefinitionScanner` at reject severity, as packs do.
- Add-on tools cannot be called from pack `tool` bindings or other composition (the DJ floor
  already refuses `pack_` chaining; `addon_` joins it).

## Permissions, in plain words

None are granted by default. Speaking is always allowed. The sheet lists what the add-on can do:

| Permission | Sheet wording |
|---|---|
| `network` | "Connect to: api.frankfurter.dev" (every domain listed) |
| `location` | "Use your approximate location (about 1 km) when you ask it something" |
| `memory` | "Save things to your memory. It can't read what's already there." |
| `display` | "Show cards on your phone, watch and glasses display" |

and one fixed line: "It can never reach your contacts, camera, health data, messages, calendar,
photos or microphone." Those are not permissions that exist in the format.

## Install, update, edit

- **Sources:** `openglasses://install-addon?url=https://…` (a QR code carries the same link), a file
  opened from Files, AirDrop or Mail (document type for `.json` plus an `.addon` extension), and the
  gallery. Like the skill-pack deep link, the link is outside the `DeepLinkTrust` token gate because
  it never acts on its own: fetch (new `BoundedHTTPClient` profile `.recipeAddOn`: ≤ 256 KB, JSON,
  ≤ 3 redirects) → decode → validate → **approval sheet** (name, author domain, each skill's
  description, permissions as above, "Reviewed" badge only if signed) → install.
- **Update:** same `id` and a higher `version` shows a diff sheet — permissions and domains added
  (highlighted) or removed, skills added/removed/changed — and replaces only on accept. Lower or
  equal version is refused. The gallery may show "Update available"; nothing is fetched or applied
  in the background.
- **Source view/edit:** Settings → Add-ons → add-on → Source shows the JSON; editing validates live,
  marks it "Edited on this phone", drops any "Reviewed" badge, and re-shows the sheet if permissions
  grew. Export shares the file (never tokens).
- **Remove / kill switch:** per add-on, as for packs.

## MCP-entry add-ons

`"mcp": { "url": "https://…", "auth": "none" | "bearer" | "header", "header": "X-API-Key" }` creates
an `MCPServerConfig` through the `MCPCatalog` path. The wearer types the token at install; it lives
in the Keychain with the other servers and is never exported. `oauth` is refused at install. The
MCP host must appear in `network`. Discovery then runs the normal Plan R scan, digest store and
egress policy.

## Relation to signed skill packs — recommendation

**One engine, two envelopes.** Add-ons are a separate artifact (`Services/AddOns/`, own store
under `Documents/addons/`), not a `SkillPackBinding` kind, because the trust models differ:
a pack is a signed zip that can compose native tools and whose unsigned form is Developer-Mode
only; an add-on can compose nothing, is bounded by its permissions and sandbox, and its sheet is
the trust decision — so an unsigned add-on installs in normal mode. They share the plumbing that
should not fork: registry merge/rebuild (prefix `addon_<id>_<skill>`), kill switch, the Plan R
screen, the DJ composition floor, `ToolCallBreaker`, and the signed-envelope format for the gallery
(`SkillPackCatalog`'s signature scheme, catalog key). Later, packs gain
`SkillPackBinding.recipe(file:)` so first-party signed packs use the same engine. **Recommend
retiring BX P4 (JavaScript handlers)** in favour of this: it gives packs HTTP without code.

## What happens under other modes

- **HIPAA mode:** add-ons with `network` are not declared to the model (transcript-derived
  parameters would leave the device). `NetworkRoute.recipeAddOn` is refused by
  `MedicalEgressGuard` in local-only mode.
- **Agent Mode:** not required; add-ons run only when the wearer asks. Nothing here schedules runs.
- **Org profiles (Plan CT):** three ceilings — add-ons disabled, no community add-ons, and
  organisation-signed only (Revision 2026-10-02). A profile may also *reference* organisation
  add-ons, installed at enrolment and removed with the profile; it never embeds one.
- **Offline (Plan GE):** add-on skills with `network` classify as `needsNetwork`.

## Phases (one PR each)

**P0 — Format and validator (pure).** `RecipeAddOnManifest` (strict decode), `RecipeAddOnValidator`
(limits, variables defined before use, `say` on every path, parameter shapes, icon allowlist),
`AddOnDomainRule` (parse/match, public-suffix refusal via a bundled suffix list), `AddOnPermissionSummary`
(plain-words lines), `RecipeTemplate` (context-aware escaping), `RecipeJSONPath` (subset with
indexing; the harness `JSONPath` moves onto it). Tests: `RecipeAddOnManifestTests`,
`RecipeAddOnValidatorTests`, `AddOnDomainRuleTests` (wildcards, IPs, ports, `*.github.io`),
`RecipeTemplateEscapingTests` (a `&`/`#`/`\r\n`/`"` in each context), `RecipeJSONPathTests`.

**P1 — Runner (pure, injected transport and clock).** `RecipeRunner`, `RecipeSandbox`,
`RecipeRunQueue`, `AddOnHTTPTransport` protocol + fake. Tests: `RecipeRunnerTests` (every step and
`if` op; http failure as data), `RecipeSandboxTests` (4th request refused, 1 MB cap, 30 s, redirect
off-allowlist refused, substituted host off-allowlist refused, forbidden headers stripped),
`RecipeRunQueueTests`, `RecipeEgressTests` (secret in a parameter blocks).

**P1b — Organisation envelope and signed-only capabilities (pure).** See *Revision 2026-10-02*:
`AddOnSignature`, `AddOnTrustClass`, `AddOnReservedCapability`, `AddOnPolicy`, the reference
shape. Tests: `AddOnSignatureTests`, `AddOnReservedCapabilityTests`, `AddOnPolicyTests`,
`AddOnReferenceTests`.

**P2 — Install and run for real.** `AddOnStore` (JSONStore salvage semantics), `AddOnToolWrapper`,
`ToolDispatchSeam.addOn(id:)`, `NetworkRoute.recipeAddOn` (+ privacy-manifest reconciliation),
`BoundedHTTPClient` POST and `.recipeAddOn` profile, deep-link/file/QR ingest, install and
update-diff sheets, Settings → Add-ons (list, kill switch, source view/edit, remove), HIPAA and
local-only gates. Tests: `AddOnStoreTests`, `AddOnUpdateDiffTests`, `AddOnRegistryTests` (names,
coverage, HIPAA hides network add-ons), `AddOnDeepLinkTests`, `NetworkRouteRegistryTests` update.

**P3 — Gallery and starter set.** Signed gallery index on the existing Pages site (allowlisted in
`Scripts/stage-pages-site.sh`), first-party add-ons under `addons/src/`, drift-pinned in tests,
`docs/addon-authoring.md`. Starter candidates: currency (Frankfurter/ECB), sunrise/sunset and
golden/blue hour (needs an API that returns them precomputed, since recipes do no arithmetic),
air quality + UV (Open-Meteo air quality), sea state (Open-Meteo marine), Wikipedia summary
(`*.wikipedia.org` REST summary), nearby earthquakes (EMSC seismic portal).

Device checks owed with P3: install from QR, AirDrop and Mail; a real run per starter add-on on
cellular; the update diff; VoiceOver on both sheets.

Plan [HG](HG-add-on-catalogue-and-premium-gating.md) takes P3's index and extends it (permission
summary per entry, shelves, `requiresPack`); P3 here remains the starter set, the authoring guide
and the free gallery screen.

**P4 — MCP entries and the pack `recipe` binding.**

## Risks

- **App Review 2.5.2.** Interpreted declarative steps with no code, a mandatory sheet and a
  curated gallery are the defence; community install stays an explicit file/link act.
- **Exfiltration through parameters.** Flat, length-capped parameters, the egress screen and the
  definition scanner reduce it; a parameter can still carry what the wearer said. The sheet names
  every domain for that reason.
- **Upstream terms.** Open-Meteo's free tier is non-commercial; the app is paid. Check each starter
  API's terms and attribution (Wikipedia content is CC BY-SA) before the gallery lists it.
- **Regex cost.** `NSRegularExpression` has no timeout; the pattern rules and 1 MB input cap bound
  it, and P1 fuzzes known catastrophic patterns.

## Decisions for Greig

1. **Envelope relation:** separate artifact sharing plumbing, packs later gain a `recipe` binding,
   BX P4 JS retired. *(Recommended.)*
2. **Unsigned add-ons in normal mode** (sheet is the trust decision) vs. Developer Mode only.
   *Recommend normal mode.*
3. Format tag `avenkin.addon/1` (product name) vs. `openglasses.addon/1`. *Recommend the product name.*
4. Coarse location (2 decimals) by default, no "precise" opt-in in v1? *Recommend yes.*
5. ~~Per-add-on secrets (API keys in the Keychain) — v1 or later?~~ **Settled 2026-10-02:** with
   the organisation envelope (P1b/P2), for signed add-ons only, as the reserved `credentials`
   capability. Community add-ons never hold a secret.
6. HIPAA mode: hide network add-ons (recommended) or allow with a per-add-on confirmation.
7. Gallery: first-party only at launch, or also reviewed community entries? *Carried by Plan
   [HG](HG-add-on-catalogue-and-premium-gating.md), which absorbs P3's index.*

**Settled 2026-10-02 (see the revision):** two classes with reserved capabilities for signed
add-ons only; organisation add-ons by reference, installed at enrolment, not editable; three CT
ceilings; a live stock check against Avenkin Office is Plan HF, not an add-on.

UI copy never names plan letters; "add-on" is the user-facing word.

## Out of scope

JavaScript or any code, loops and arithmetic, background or scheduled runs, reading memory,
OAuth, and access to contacts, camera, health, messages, calendar, photos or mic. Reaching private
or LAN addresses, and any HTTP call to Avenkin Office, stay out for every class (Plan HF covers
Office). A store product per add-on is out of scope here and in Plan HG: gating is by pack, and
it gates reserved capabilities, not the file.
