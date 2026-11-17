# Plan GO — Self-Built Skills ("Build yourself a skill for that")

**Status:** 🚧 P0–P3 built 2026-11-18, device checks owed — the pure core, the building service
with its consent gate, dry-run mode, drafts and the Tested panel, the `build_addon` tool with update
mode, and add-on ideas in the suggestions inbox. Owed: three real builds against keyless public APIs
on cellular, one approval and one rejection on the sheet, VoiceOver on the Tested panel, and the
catalog sync of the new strings. Drafted 2026-10-01.
**Depends on:** Plan [GF](GF-recipe-add-ons.md) P0–P2 (the `avenkin.addon/1` format, `RecipeAddOnValidator`,
`RecipeRunner`/`RecipeSandbox`, `AddOnStore`, the install and update-diff sheets). GO writes GF
add-ons; it adds no new runtime.
**Extends:** Plan [AW](skill-self-evolution.md) (`SkillEvolutionService`, which today only *proposes*
prompt-level skills from failures for human review).
**Related:** Plan R (`EgressScreen`, `ToolDefinitionScanner`, `PromptInjectionPolicy`), Plan CT (org
policy can turn it off).

---

## Trigger

The wearer asks for something no tool covers ("what's the tide at Plimmerton?"), the assistant says
it can't, and the wearer says: *build yourself a skill for that*. Today the best the app can do is
AW's loop, which may, after several failures, propose a *prompt instruction* — it cannot give the
assistant a new capability, and a new capability that fetches data is exactly what GF add-ons are.

## Outcome

- On request, the assistant finds a suitable public API, drafts a GF recipe add-on (steps, typed
  parameters, **minimal** permissions), **tests it against the real service once**, and shows the
  wearer the result next to the normal add-on approval sheet.
- It is kept **only if the wearer approves** on the phone; otherwise the draft and its test trace
  are deleted.
- The finished add-on is ordinary: visible source, editable, removable, updated only through GF's
  diff sheet, marked "Built by your assistant".

## What exists today (verified 2026-10-01)

- `Services/Skills/`: `SkillEvolutionService` (`@MainActor`, `.shared`, Agent-Mode-gated `record` /
  `noteUserTurn` / `evolveIfNeeded` over a `SkillEvolutionAnalyzer` seam; `approve(id:)` writes a
  `VoiceSkill`), `EvolvedSkillStore` (SQLite pending/approved/dismissed; `enqueue`, `approve`, `pending`),
  `SkillProposal.validate`, `SkillDeduplicator`, `EvolutionTrigger`, `ToolFailureFilter`,
  `UserCorrectionDetector`, `SkillRetriever`. Output is a three-line trigger/instruction draft; no
  capability, no network, no test.
- **No GF code yet** (GF is drafted on this branch): no manifest type, runner, store or sheet.
- Research tools: `web_search` (Perplexity when keyed, else DuckDuckGo). There is **no page-fetch
  tool**; `Security/BoundedHTTPClient.swift` is the hardened fetch (GET, private-address refusal,
  per-profile caps) and GF adds a `.recipeAddOn` profile.
- Native coverage check material: `NativeToolRegistry` names/descriptions and `SkillRetriever`
  embeddings. Note `convert_currency` already exists natively, so the obvious first demo (currency)
  must be refused as already covered.

## Design

### The authoring session (`AddOnAuthoringSession`, pure state machine)

`idle → preflight → researching → drafting → validating ⇄ repairing (≤ 2) → awaitingTestConsent →
testing → assessing ⇄ repairing (≤ 2, shared budget) → awaitingApproval → installed | discarded | gaveUp`.
Every transition is a pure function of the previous state and an event, so the whole flow is table-
tested with a fake model and fake transport. Hard caps per session: 10 model calls, 3 docs fetches,
1 test run per draft revision, 10 minutes wall clock.

1. **Preflight (`AddOnAuthoringPreflight`).** Is it already covered? The goal is matched against
   native tool descriptions and installed add-ons (`SkillRetriever`-style similarity with a fixed
   threshold). Covered → "I can already do that: …" and the session ends. Needs contacts, camera,
   health, messages, calendar, photos or mic → refused with GF's fixed sentence, because no add-on
   can reach them. Needs arithmetic or loops → "That needs a built-in tool; I can't build it as an
   add-on."
2. **Research.** The model uses `web_search`, then `AddOnDocsFetcher` (new `BoundedHTTPClient`
   profile `.addOnAuthoring`: GET, HTML/JSON/text, ≤ 256 KB, ≤ 3 per session) to read an API's
   documentation. Fetched text is wrapped with `PromptInjectionPolicy.wrap` and treated as data.
   **v1 accepts only keyless HTTPS APIs** (GF defers per-add-on secrets); a keyed API ends with
   "That service needs an account key; I can't build that yet."
3. **Draft.** The model returns one `avenkin.addon/1` JSON document and nothing else. Authoring
   fields GO fills deterministically, not the model: `id` = `local.assistant.<slug>` (reverse-DNS,
   collision-suffixed), `version` `1.0.0`, `author.name` "Built on this phone", `author.web` = the
   HTTPS documentation page it used (so the sheet's domain line shows where the data comes from).
   Provenance (`selfBuilt`, session id, goal, date) is `AddOnStore` metadata, not a file field, so
   the file stays a plain GF file.
4. **Validate and minimise.** `RecipeAddOnValidator` (GF) runs unchanged; its messages go back to
   the model for up to two repairs. Then **`PermissionMinimizer`** (pure) recomputes the permission
   set from the steps: `network` = the literal hosts in `http` URLs (a templated host is rejected),
   `location` only if `{{lat}}`/`{{lon}}`/`{{city}}`/`{{country}}` appear, `memory` only with a
   `remember` step, `display` only with a `display` step. Anything the draft declared beyond that is
   removed; anything missing is added. Minimal permissions are therefore enforced, not trusted.
5. **Test consent.** Before any request to the new service: one line on the phone and by voice —
   "To test it, I'll contact **api.example.org** once with a sample question. OK?" The domains listed
   are exactly the minimised `network` set. No request happens without a yes.
6. **Test (dry run).** `RecipeRunner` with the real transport and GF's sandbox, `dryRun: true`:
   `remember` steps are simulated (nothing written), `display` renders into the review preview only,
   sample parameters come from the model but pass `EgressScreen` (a credential or a value matching
   the wearer's stored facts blocks the test) and location, if used, is the coarse 2-decimal value.
   The result is a `DryRunTrace`: per step status, bytes, redirect hops, extracted values (truncated),
   the final spoken sentence, elapsed time.
7. **Assess (`DryRunAssessor`, pure).** Pass when the success path was taken, every `extract` on it is
   non-empty, the `say` output has no unresolved `{{…}}`, and all sandbox limits held. Fail → the
   trace summary goes back for a repair (shared budget), then one more consented test. Still failing
   → "I couldn't get that service to answer reliably" and the draft is discarded.
8. **Approval.** GF's install sheet (name, author line, skills, permissions in plain words, the fixed
   "can never reach…" line) plus a **Tested** panel: the sample question, the spoken answer, domains
   contacted, time, and "View source". Voice says "It works — check your phone to approve it." The
   sheet on the phone is the only approval path (decision 2). Unapproved drafts expire after 24 h.

### After install

- Badge "Built by your assistant" (never GF's "Reviewed", which needs a signature).
- "Improve the tide add-on" re-enters the session in update mode: GO drafts version + 1, re-tests
  with consent, and GF's update-diff sheet shows added/removed domains and permissions.
- Removal, kill switch, editing: exactly GF's.

### Tie-in with AW

`SkillEvolutionService` gains a second proposal kind. When a failure batch is dominated by "no tool
could get X" (a `ToolFailureFilter`-style pure classifier over the samples), the analyzer may return
`addon-idea: <goal>`; `EvolvedSkillStore` stores it with `kind = addOnIdea` (a new column, default
`voiceSkill` for existing rows) and the Suggested Skills inbox shows "Build an add-on for: tides
at the coast?" with **Build it** / Dismiss. Nothing is drafted or fetched until the wearer taps
Build it; that starts a normal session. Voice skills keep today's path.

### Gates and modes

- **Agent Mode required** for sessions and for evolution-originated ideas (autonomous research and
  network probing). Installed self-built add-ons then run like any GF add-on (GF does not require
  Agent Mode to run).
- **HIPAA mode and local-only mode:** GO is unavailable (GF hides network add-ons under HIPAA; the
  research and test calls are egress). The tool is not declared.
- **Org policy (CT):** a key disables self-built add-ons; installed ones follow GF's community-add-on key.
- **Rate:** ≤ 3 sessions a day; each session's model calls are recorded off-turn in the cost tracker.
- **Offline (GE):** unavailable; says so.

### Surfaces

Tool `build_addon` (`start(goal)`, `status`, `cancel`), Agent-Mode-gated, whose description says it
creates a reviewed add-on and never installs silently. Progress is spoken sparingly ("Looking for a
tide service…", "Testing it now") and shown as a phone card; glasses are optional. Copy never names
plan letters; the user-facing word is "add-on".

## Phases (one PR each; GO P1 needs GF P2 merged)

**P0 — Pure core.** `AddOnAuthoringSession`, `AddOnAuthoringPreflight` (injected matcher),
`PermissionMinimizer`, `DryRunTrace`, `DryRunAssessor`, `SelfBuiltIdentity` (id/slug/collisions).
Tests: `AddOnAuthoringSessionTests` (every transition, caps, repair budget, expiry),
`PermissionMinimizerTests` (templated host rejected, extras stripped, location vars detected),
`DryRunAssessorTests`, `AddOnAuthoringPreflightTests` (native `convert_currency` → covered; contacts →
refused), `SelfBuiltIdentityTests`.

**P1 — Service with fakes.** `AddOnAuthoringService` (model seam, `AddOnHTTPTransport` from GF, docs
fetcher profile), consent gate, dry-run mode in `RecipeRunner` (simulated `remember`, preview-only
`display`), draft storage and 24 h expiry, review sheet Tested panel. Tests:
`AddOnAuthoringServiceTests` (fake model returns invalid → repaired → valid; **no request before
consent**; consent domains equal the minimised set; discard deletes trace), `RecipeRunnerDryRunTests`.

**P2 — Voice and tool.** `build_addon` registered (Agent-Mode and HIPAA gates in declarations),
spoken progress, update mode. Device checks (owed): three real builds against keyless public APIs on
cellular, an approval and a rejection, VoiceOver on the Tested panel.

**P3 — Evolution-originated ideas.** `EvolvedSkillStore.kind` migration, analyzer prompt variant,
inbox row with Build it. Tests: `SkillEvolutionAddOnIdeaTests`, store migration test.

### What P0–P3 built (2026-11-18)

- **Pure core** (`Services/AddOns/Authoring/`): `AddOnAuthoringSession` (the phases above; 10 model
  calls, 3 documentation pages, 1 test per revision, 2 repairs shared between validation and testing,
  10 minutes of building, a tested draft waits 24 hours), `AddOnAuthoringPreflight` (injected matcher,
  default lexical with a name-subsumption rule, so `convert_currency` covers "fifty euros in dollars";
  private-data and arithmetic/loop phrases refuse first), `PermissionMinimizer` (literal hosts only,
  templated hosts and ports refused, extras stripped, location variables found in any template, memory
  and display only with their steps, an add-on that calls nothing refused), `DryRunTrace` and
  `DryRunAssessor`, `SelfBuiltIdentity` (`local.assistant.<slug>`, `-2`… on collision, `1.0.0` then
  minor + 1, `author.web` only a page actually read or the service's own address).
- **Service** (`AddOnAuthoringService`): the authoring model answers one JSON action per call
  (`AddOnAuthoringPrompt`: search, fetch, draft with a sample, needs-key, give-up); search results,
  fetched pages and the checker's report are framed with `PromptInjectionPolicy.wrap`;
  `AddOnDraftPreparation` writes the app's fields, recomputes permissions and runs the GF validator;
  the consent request names exactly the minimised `network` set before every test, including after a
  repair; the test is `RecipeRunner.dryRun` over the add-on transport (strict sample screen: any
  `EgressScreen` hit or a value containing a stored fact blocks it; `remember` simulated, `display`
  previewed, coarse location); a passing draft is saved in `AddOnDraftStore` and offered through
  `AddOnInstallService.receive(_:origin:tested:)`; accepting or cancelling the sheet deletes the draft
  and its trace either way. Documentation pages come over `BoundedAddOnDocsFetcher` on the new
  `BoundedHTTPClient.Profile.addOnAuthoring` (GET, HTML/JSON/text, 256 KB, 3 redirects) and its own
  route, `NetworkRoute.addOnAuthoringDocs` (public web, prompt text, blocked under Local Only); the
  test run reuses `NetworkRoute.recipeAddOn` through `BoundedAddOnHTTPTransport`, since it is exactly
  an add-on step. Web search goes through the router as an internal `web_search` call.
- **Model calls**: the wearer's cloud model over the isolated one-request route
  (`DraftCloudTransport`, now with a longer deadline for this caller), recorded in Usage as an
  estimate; a sign-in provider that route doesn't support falls back to `completeStateless`, as the
  suggested-skills analyser does; on-device models are refused.
- **Sheet**: the Tested panel (asked, answered, contacted, time, View Source; one VoiceOver element),
  "Built by your assistant · data from <domain>", never "Reviewed"; a self-built-shaped file received
  from someone else shows "Built by an assistant on another phone" (a note, not trust). Settings →
  Add-ons lists drafts waiting ("Built for You") to reopen or delete.
- **Tool** `build_addon` (`start`, `improve`, `status`, `cancel`): offered only with Agent Mode on, not
  under Medical Compliance or Local Only, add-ons on, a policy that allows unsigned add-ons, and no
  `organizationForbidsSelfBuiltAddOns` (the new ceiling key); `needsNetwork` offline; in
  `hipaaDisabledTools`; three sessions a calendar day. Progress is spoken and posted as a notice at
  three points only. Improve works only on add-ons the assistant built: same id, minor + 1, re-tested
  with its own consent, shown on GF's update-diff sheet.
- **Ideas** (P3): `EvolvedSkillStore.kind` (`voiceSkill` default, migrated with `ALTER TABLE`),
  `AddOnIdeaClassifier` (≥ 60 % of a batch of at least three is "no tool could get it"), a prompt
  variant offered only for such a batch, an `addon-idea:` answer accepted only when the classifier
  agrees, and the inbox row "Build an add-on for: …?" with Build It / Dismiss.
- Tests: `AddOnAuthoringSessionTests`, `PermissionMinimizerTests`, `DryRunAssessorTests`,
  `AddOnAuthoringPreflightTests`, `SelfBuiltIdentityTests`, `AddOnAuthoringServiceTests` (with
  `AddOnSelfBuiltSheetTests`), `RecipeRunnerDryRunTests`, `BuildAddOnToolTests`,
  `SkillEvolutionAddOnIdeaTests` (with the migration test), `NetworkRouteRegistryTests` update.

## Risks

- **Prompt injection via docs or API responses** steering the draft toward another host: the
  minimiser, the consent line naming every domain before any request, `EgressScreen` on sample
  values and the phone approval sheet are the layered defence. Worst case is a draft the wearer sees
  and rejects.
- **Low success rate.** Many APIs need keys or arithmetic; GO says so early (preflight/research) rather
  than burning calls.
- **Upstream terms.** A self-built add-on uses a third-party service under the wearer's own
  approval; the sheet shows the documentation domain; the gallery never lists self-built add-ons.
- **Cost.** Capped calls per session and sessions per day.

## Decisions for Greig

1. **Test consent every time** (recommended) or once per new domain?
2. **Approval only on the phone sheet** (recommended), or also a spoken "yes, keep it"?
3. **Provenance** in store metadata with `author.web` = the docs page (recommended), or add an
   optional `origin` field to the GF format?
4. **Keyless APIs only** until GF adds per-add-on secrets? *Recommend yes.*
5. **Share/export** of self-built add-ons allowed (it is just a GF file)? *Recommend yes, with the
   "Built by your assistant" note kept in the exported sheet.*

## Out of scope

Native tool or code generation, keyed or OAuth APIs, silent installs or updates, background
authoring without a request (AW ideas wait for Build it), and publishing to the gallery.
