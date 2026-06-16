# Plan R — MCP Egress & Tool-Poisoning Screen

**Source pattern:** The deterministic egress-screening + MCP tool-poisoning-scan idea, drawn from our own idea-source repo `~/Code/qaeros` (`plans/213-egress-traffic-screener.md`, `plans/200-agent-governance-toolkit.md`). Concept only — clean-room Swift; no code reused.

**Strategic fit:** Safety hardening. OpenGlasses already ships an MCP client ([MCPClient.swift](../../OpenGlasses/Sources/Services/MCPClient.swift)) that auto-discovers and calls tools from user-added servers, and a `MCPGlassesServer` exposing our own tools. The injection defense in [PromptInjectionPolicy.swift](../../OpenGlasses/Sources/Services/PromptInjectionPolicy.swift) already frames *inbound* MCP output as untrusted and gates high-impact actions. This plan adds the two halves an always-on wearable still lacks: **discovery-time scanning of attacker-authored tool definitions**, and an **outbound egress screen** so secrets/PII never leave the device for a third-party server. Continues the hardening shipped in `8405fff`.

**Effort:** ~3–4 days.

**Status:** ✅ Shipped (headless-validated). All three deterministic screens landed —
`SecretPatterns` (shared regex set), `EgressScreen` (pure `(args, EgressPolicy) → allow/redact/block`,
recursing nested args), and `ToolDefinitionScanner` (poisoned-description / native-shadow / typosquat /
bad-schema → `trusted/quarantined/blocked`). Wired into `MCPClient.discoverTools` (scan + trust) and
`NativeToolRouter` (egress screen at call time; `.block` → no network call + a no-retry `.failure`).
MCP tools are now offered to the model **only** under their sanitised `qualifiedName`, and blocked tools
are never offered. Added a per-server `EgressPolicy` (default `.redact`, backward-compatible decoder),
the `MCPServerTrustView` (policy picker + tool trust badges + recent egress decisions), and a
`systemPromptPolicy` note about untrusted external-tool definitions. 21 new headless tests; full suite
541 green; Debug + Release verified.

---

## The gap (what's missing today, verified)

| Risk | Today | This plan |
|---|---|---|
| **Tool poisoning** — a remote server authors tool `name`/`description`/`inputSchema`; a poisoned description can carry hidden instructions, and a tool can typosquat or *shadow* a native high-impact name (advertise `send_message`). | `MCPClient.discoverTools` ([:29](../../OpenGlasses/Sources/Services/MCPClient.swift)) ingests them verbatim into `discoveredTools`. | Scan every definition at discovery; quarantine or namespace-isolate suspicious ones. |
| **Outbound exfiltration** — args sent to an external server may contain API keys, tokens, health-vault text, contacts. | `MCPClient.executeTool` ([:62](../../OpenGlasses/Sources/Services/MCPClient.swift)) POSTs `arguments` unfiltered via `mcpRequest`. | Pre-call egress screen: block/redact secrets + PII before the request leaves the device. |
| **Name collision / shadowing** — router matches MCP tools on **raw** name. | `NativeToolRouter` checks native first ([:45](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift)) then `mcp.discoveredTools.contains { $0.name == name }` ([:53](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift)). A server advertising `send_message` is masked by the native one (good) but still pollutes the model's tool list. | Enforce `serverLabel__toolName` (`MCPTool.qualifiedName` already exists, [:169](../../OpenGlasses/Sources/Services/MCPClient.swift)) as the *only* name the model and router ever see. |

`PromptInjectionPolicy.isUntrustedOutput` already returns `true` for any non-native tool ([:44](../../OpenGlasses/Sources/Services/PromptInjectionPolicy.swift)) — so inbound MCP results are already enveloped. This plan is the **outbound + discovery** mirror of that.

---

## Files

- New: `Sources/Services/Security/EgressScreen.swift` — pure, deterministic screen over outbound arg dictionaries (secrets, PII/PHI, encoded blobs). Returns `.allow | .redact(args) | .block(reason)`.
- New: `Sources/Services/Security/ToolDefinitionScanner.swift` — scans an `MCPTool` definition at discovery (hidden-instruction patterns in description, native-name shadowing, schema sanity). Returns a `ToolTrust` verdict.
- New: `Sources/Services/Security/SecretPatterns.swift` — shared regex set (`sk-…`, `ghp_…`, bearer tokens, AWS keys, JWT, email, NZ/IRD-style ids) reused by both.
- New: `Sources/App/Views/MCPServerTrustView.swift` — per-server panel: discovered tools with trust badges, last egress decisions, per-server PII policy toggle (`block | redact | allow`).
- Touch: [MCPClient.swift](../../OpenGlasses/Sources/Services/MCPClient.swift) — run `ToolDefinitionScanner` inside `discoverTools`; run `EgressScreen` at the top of `executeTool`; store `qualifiedName` as the routed name; add `var policy: EgressPolicy` to `MCPServerConfig`.
- Touch: [PromptInjectionPolicy.swift](../../OpenGlasses/Sources/Services/PromptInjectionPolicy.swift) — extract `SecretPatterns` usage; expose `systemPromptPolicy` addendum line about quarantined tools (keeps one policy home).
- Touch: [NativeToolRouter.swift](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift) — match MCP tools on `qualifiedName`; treat a `.block` egress verdict like a declined confirmation (return a `.failure` the model is told not to retry).

---

## Architecture

```
discovery:  MCPClient.discoverTools(server)
                 │  for each tool def (attacker-authored)
                 ▼
          ToolDefinitionScanner.scan(tool, nativeNames:)
                 │  → .trusted | .quarantined(reason) | .blocked(reason)
                 ▼
          discoveredTools (quarantined tools are namespaced + flagged,
                           never offered under a bare/native-colliding name)

call:       NativeToolRouter.handleToolCall(name, args)   // name == qualifiedName for MCP
                 │ native? → run            (existing :45)
                 │ MCP?    → EgressScreen.evaluate(args, policy:)
                 │              .allow  → executeTool
                 │              .redact → executeTool(redacted)   + log
                 │              .block  → .failure("withheld: <reason>")  ← no network call
                 ▼
          inbound result → PromptInjectionPolicy.wrap(...)        (existing :54)
```

### Verdict types

```swift
enum ToolTrust: Equatable { case trusted; case quarantined(String); case blocked(String) }

enum EgressVerdict: Equatable {
    case allow
    case redact([String: Any], hits: [String])   // safe copy of args + what was masked
    case block(String)                            // human-readable reason
}

enum EgressPolicy: String, Codable, CaseIterable { case block, redact, allow }  // per server
```

`EgressScreen` is a pure function of `(args, EgressPolicy)` — no I/O, fully unit-testable, runs in <1 ms so it never adds perceptible latency to a tool call.

---

## Screening rules (deterministic, no LLM)

**Tool-definition scan** (discovery): flag a definition `.quarantined`/`.blocked` if the description contains imperative/meta patterns (`ignore previous`, `system:`, `<tool_output`, base64 over N bytes), if `name` equals or near-matches (Levenshtein ≤1) any `PromptInjectionPolicy.highImpactTools` entry, or if `inputSchema` is absent/non-object. Quarantined tools stay usable only under their fully-qualified name and never appear without a trust badge in the UI.

**Egress screen** (pre-call): scan all string leaves of `arguments` for `SecretPatterns`. On hit: `block` policy → withhold the call; `redact` policy → replace the match with `‹redacted›` and proceed; `allow` policy → proceed but record the hit. PII (emails, health-vault-shaped content) defaults to `redact`. Default per-server policy is **`redact`**.

---

## Build order

1. `SecretPatterns` + tests (regex coverage table).
2. `EgressScreen.evaluate` + tests (allow/redact/block per policy × pattern).
3. Wire `EgressScreen` into `MCPClient.executeTool`; add `EgressPolicy` to `MCPServerConfig` (default `.redact`); router treats `.block` as withheld.
4. `ToolDefinitionScanner` + tests (poisoned descriptions, shadow names, bad schema).
5. Wire scanner into `MCPClient.discoverTools`; route MCP tools on `qualifiedName`.
6. `MCPServerTrustView` — trust badges + per-server policy picker + recent-decision log.
7. System-prompt note in `PromptInjectionPolicy.systemPromptPolicy` ([:137](../../OpenGlasses/Sources/Services/PromptInjectionPolicy.swift)).

---

## Tests (mirror the green feature-test target)

- `SecretPatterns` — known-key fixtures hit; benign strings don't (no false-positive on ordinary prose).
- `EgressScreen` — every `(policy × pattern)` cell; nested-dict/array arg recursion; redaction preserves structure.
- `ToolDefinitionScanner` — poisoned description → quarantined; `send_message` shadow → blocked; `send_message` typosquat → quarantined; missing schema → blocked.
- Router — MCP `.block` returns the no-retry `.failure`; native tool of same name still wins.

---

## Open questions / decisions needed

- **Default policy:** ship per-server default as `redact` (proceed but mask) or `block` (fail closed)? *Recommendation: `redact` — fewer dead-ends, still no plaintext secrets leave the device; let the user tighten to `block` per server.*
- **PII source of truth:** should the screen know a value came from `health_vault`/`notes_vault` (taint-tracking) or just pattern-match? *Recommendation: pattern-match for v1; taint-tracking is a fast-follow if false-negatives show up.*
- **Quarantine UX:** silently namespace-isolate, or surface a one-time "this server's tools look unusual" prompt? *Recommendation: badge in `MCPServerTrustView` + a single non-blocking toast on first discovery.*
- **Local MCP server side:** do we also screen what `MCPGlassesServer` *returns* to a connected Claude Code client (camera frames could carry PII)? *Recommendation: out of scope here; note for a follow-on.*

---

## Dependencies / prereqs

- [MCPClient.swift](../../OpenGlasses/Sources/Services/MCPClient.swift) (existing) — discovery + execution seam; `MCPServerConfig`/`MCPTool`/`qualifiedName`.
- [PromptInjectionPolicy.swift](../../OpenGlasses/Sources/Services/PromptInjectionPolicy.swift) (existing) — inbound framing + high-impact list to dedup against; this is its outbound mirror.
- [NativeToolRouter.swift](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift) (existing) — routing + the declined-action `.failure` convention to reuse.
- [MCPServersView.swift](../../OpenGlasses/Sources/App/Views/MCPServersView.swift) (existing) — settings pattern for the trust view.

---

## Why this matters specifically for you

An always-on, always-listening device that auto-discovers and calls tools from servers a user pasted a URL for is the one genuinely dangerous combination in the MCP story. You already built the hard part (the client, the inbound framing). This closes the loop so a poisoned tool description can't smuggle instructions in, and a third-party server can't be handed your API keys or health-vault text. It's the smallest, highest-leverage safety plan and it directly extends the prompt-injection work already on `main`.
