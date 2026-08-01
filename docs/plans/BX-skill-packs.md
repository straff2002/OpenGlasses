# Plan BX — Skill Packs & In-App Catalog

**Status: 🚧 P1 shipped (2026-07-31)** — `SkillPackManifest` (+ `lossyDecode` with named-action drop
report), `SkillPackValidator` (caps, shapes, native-collision, Plan R screen **at reject severity** —
for a pack, install *is* the trust decision, so quarantine-level scanner findings refuse rather than
badge), `SkillPackSignature` (ed25519 over manifest + sorted payload hashes; production key is a
placeholder until P2 mints the catalog key — safe because unsigned installs are already a distinct
dev-mode-only path), `SkillPackStore` (install/upgrade/remove under `Documents/skillpacks/`,
`JSONStore` salvage semantics, path-traversal refusal, unreadable-state write lock),
`SkillPackToolWrapper` + registry merge/rebuild (`registerSkillPackTools`/`removeSkillPackTools`,
`AppState.refreshSkillPackTools()`). **Deviation from plan:** registered names are
`pack_<id-with-underscores>_<action>` not `pack:<id>/<action>` — LLM function-name charsets on both
provider wires exclude `:` and `/`; the no-shadowing property holds unchanged. Prompt/tool/gateway
bindings execute (gateway refuses without Agent Mode; pack output rides `PromptInjectionPolicy`
framing — the router skips framing for registry tools, so the wrapper frames its own); procedure
binding parses and answers honestly pending P2. P2 (catalog + Settings UI) and P3 (QR/LAN sideload)
next.

**P2 shipped (2026-07-31)** — `SkillPackCatalog` (signed envelope: signature over exact base64-wrapped
payload bytes, so no JSON-canonicalization hazard; explicit refusal of newer index versions),
`SkillPackArchive` (pack zip → install shape via the Plan BT `ZipArchiveReader`, no new dependency;
zip-bomb entry cap), `SkillPackHardwareGate` (ready/degraded/blocked against connected hardware),
`SkillPackCatalogService` (download → sha256 → extract → install with injectable fetch; every stage
failure is a visible per-pack state), `SkillPackSettings` (settings-as-schema persisted under
`skillpack.<id>.<key>`, reaching bindings via `{{setting.<key>}}` — only *declared* keys flow),
Settings → Skill Packs UI (installed rows w/ kill switch + unsigned/partial-load badges + per-pack
settings sheet rendered from schema; catalog browse/install; developer-mode toggle), and
`Scripts/skillpack-sign.swift` (keygen / sign-pack / sign-catalog — private key stays off-repo, the
Field Assist rule). **Hosting decision resolved:** repo-served static JSON on the existing GitHub
Pages deployment (`Config.skillPackCatalogURL`, overridable). **Catalog signing is never loosened**
— developer mode admits unsigned *packs* only; a poisoned index is a fleet-level attack. **Production keypair minted 2026-08-01** — public key embedded, private half off-repo with the
Field Assist key; first signed (empty) `skillpacks/catalog.json` committed, with a test pinning the
committed envelope against the embedded key so the two can't drift, and `skillpacks/README.md`
documenting the publish flow.

**P3 shipped (2026-08-01)** — sideload/dev loop: `openglasses://skillpack?url=…&sig=…` handled
outside the `DeepLinkTrust` token gate *by design* (a QR link can't carry the app-group token); the
compensating control is that the link never acts — `SkillPackSideloadService` fetches, previews,
and raises a confirmation alert with identity + signature status, and the human tap is the gate.
Source policy: HTTPS anywhere, plain HTTP only to private/LAN hosts (RFC 1918 / loopback /
link-local / `.local`, pinned by table test); unsigned packs still require Developer Mode; signed
sideloads verify via the `sig` param. `Scripts/serve-skillpack.sh` (zip + LAN serve + QR via
qrencode) closes the author loop; `docs/skillpack-authoring.md` is the manifest reference. First
catalog content shipped alongside: `com.openglasses.barista` + `com.openglasses.focus` under
`skillpacks/src|packs/`, drift-pinned into the test suite — authoring the focus pack exposed and
fixed the bound-arg typing gap (string→Int/Bool coercion). **Plan complete except** P4 (JS
handlers, deliberately deferred) and the Plan Q export-format migration open decision.

Make OpenGlasses extensible by *installable content*, not app updates: a **skill pack** is a
signed zip the app downloads (or sideloads), validates, and merges into the assistant at
runtime — new voice-invocable actions, prompt/persona content, procedures, and settings,
browsable from an in-app catalog. Think "app store", but the units are data-driven skills
running through the existing tool router, not executable programs — which is what keeps it
squarely inside App Review rules (no downloaded native code; any future scripted handlers are
confined to JavaScriptCore/WKWebView, the sanctioned runtimes).

## Why now, and what it unifies

The pieces already exist as islands:

| Today | Where | Gap |
|---|---|---|
| Custom tools (user-defined, LLM-callable) | `Config.customTools` + `CustomToolWrapper` | Hand-authored one at a time on-device; not shareable, not versioned |
| Skills library export/import | Plan Q | File round-trip only; no discovery, no metadata, no trust model |
| One-tap MCP server install from a curated catalog | Plan V `MCPCatalog` | Catalog pattern proven, but only for MCP servers |
| Custom vault import (enterprise packs) | Plan H | Domain knowledge only; separate pipeline |
| Gateway skills discovery | `OpenClawSkillsTool` | Remote-only; requires a gateway |
| Runtime Siri action catalog | Plan BQ `SiriActionCatalog` | Proves runtime-extensible action registries work end-to-end |

A skill pack is the umbrella artifact over all of these: one manifest that can carry actions,
prompts, procedures, vault fragments, and settings — installed, versioned, listed, and removed
as a unit.

## The artifact

`skillpack.json` (manifest) + payload files, zipped:

```json
{
  "id": "com.example.barista",
  "version": "1.2.0",
  "name": "Barista Coach",
  "summary": "Espresso dial-in guidance through the glasses",
  "icon": "icon.png",
  "minAppBuild": 326,
  "hardware": [ {"type": "camera", "level": "optional"} ],
  "actions": [
    {
      "name": "dial_in_shot",
      "description": "Use when the user wants help dialing in espresso — e.g. 'my shot ran in 18 seconds'.",
      "parameters": { "type": "object", "properties": { "shot_time_s": {"type": "number"} } },
      "binding": { "kind": "prompt", "template": "…" }
    }
  ],
  "settings": [ {"key": "roast_level", "type": "select", "options": ["light","medium","dark"]} ],
  "content": { "procedures": ["procedures/backflush.json"], "prompts": ["prompts/persona.md"] }
}
```

Key decisions:

- **`actions[]` are JSON-Schema tool declarations with LLM-oriented descriptions.** They merge
  into `NativeToolRegistry` via a `SkillPackToolWrapper` (the `CustomToolWrapper` precedent) and
  flow into both prompt builders through the existing `SystemPromptBuilder` path — zero new
  prompt plumbing. Per-tool activation phrases can additionally surface through the Plan BQ
  `SiriActionCatalog` so installed skills are Siri-reachable.
- **Bindings, v1:** `prompt` (canned instruction through the normal assistant turn), `tool`
  (composition over existing native tools with bound args), `procedure` (starts a pack-supplied
  or existing procedure), `gateway` (delegate to the remote agent — **gated behind
  `agentModeEnabled`**, refused otherwise). **No arbitrary code in v1.** A JS handler kind
  (JavaScriptCore, headless, per-pack context) is P4 — the seam exists in the binding enum from
  day one so nothing needs re-architecting.
- **Settings-as-schema:** the host renders each pack's settings page from typed declarations —
  no per-pack UI.
- **Hardware requirements** (`camera`/`display`, `required`/`optional`) drive catalog filtering
  and graceful degradation, mirroring how `supportsDisplay()` gates HUD features today.
- **Signing:** ed25519 signature over the manifest + payload hashes, verified against an
  embedded public key — the exact Curve25519 pattern Field Assist licensing already ships.
  Unsigned packs install only in developer mode, loudly labeled.

## Trust & safety posture

- Tool names are namespaced (`pack:com.example.barista/dial_in_shot`) so a pack can never
  shadow a native tool.
- Pack-supplied text (prompts, templates, descriptions) is untrusted input: descriptions run
  through the `ToolDefinitionScanner` (Plan R) poisoning screen at install; execution output
  rides the existing `PromptInjectionPolicy` framing.
- Per-pack kill switch + the existing `ToolCallBreaker` covers runaway behavior; a pack whose
  actions keep failing gets surfaced in Settings, not silently retried.
- `gateway` bindings are inert without Agent Mode (standing rule for autonomous/gateway
  features).

## Distribution

- **Catalog:** a static, signed JSON index fetched from a CDN (title, summary, icon, hardware
  needs, download URL, hash) — the Plan V catalog pattern, generalized. Browsing UI in
  Settings → Skills; install = download → verify → unzip → validate → register.
- **Sideload/dev loop:** `openglasses://skillpack?url=…` URL scheme + QR code. A companion
  `Scripts/serve-skillpack.sh` serves a pack folder over LAN with the QR printed to the
  terminal — install-to-glasses-loop in seconds, no store round-trip.
- **Bundled packs:** first-party packs ship in the binary and register through the same
  pipeline (one code path, and the pipeline is exercised on every launch).

## Phases

### P1 / PR1 — Deterministic core 🟢
Pure, fully headless-testable; no UI, no network.
- `SkillPackManifest: Codable` + `SkillPackValidator` (schema/version/hardware checks, action
  JSON-Schema validation, namespacing, size caps) with a lossy-decode report — a pack with one
  bad action loads the rest and *says so* (BB lesson: never silent-drop).
- `SkillPackSignature` — ed25519 verify (reuse the licensing primitives).
- `SkillPackStore` — install/upgrade/remove under `Documents/skillpacks/<id>/<version>/`,
  active-version pointer, `JSONStore`-backed state (BB salvage semantics).
- `SkillPackToolWrapper` + registry merge; `prompt`/`tool` bindings execute; `gateway` binding
  refuses without Agent Mode.
- Tests: manifest round-trip, validator refusals (bad schema, name collision, oversized,
  unsigned), signature verify, registry merge + prompt-builder listing, agent-mode gate,
  lossy-decode report.

### P2 / PR2 — Catalog + install pipeline + Settings UI
- Catalog fetch/parse (signed index), download+verify+unzip pipeline, Settings → Skills
  (browse, install, per-pack settings from schema, kill switch, uninstall).
- Hardware-requirement filtering against the connected device.
- Tests: catalog parsing, pipeline state machine over a local fixture server, filter logic.

### P3 / PR3 — Sideload + dev loop
- URL scheme + QR install path, dev-mode unsigned installs, `serve-skillpack.sh`.
- Docs: a "build a skill pack" page with the manifest reference.

### P4 (deferred) — Scripted handlers
- `js` binding kind: headless JavaScriptCore context per pack (tight API surface: args in,
  string out, fetch via a policied bridge), WKWebView settings/detail surfaces. Deliberately
  deferred: v1 proves the distribution + trust rails on data-only packs first, and App Review
  posture is cleaner introduced separately.

## Open decisions
- Catalog hosting (repo-served static JSON vs. existing web infra) — P2 blocker, cheap either way.
- Whether Plan Q's export format migrates into pack format (leaning yes: an exported skill
  library *is* an unsigned local pack).
- Paid packs: out of scope for v1 (catalog is free-only); IAP-gated packs would ride the
  existing entitlement checks if ever wanted.
