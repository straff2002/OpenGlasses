# Plan V — Curated MCP Catalogue & Transport Breadth

**Source pattern:** The single-governance-path "wrapped tool marketplace" idea from our idea-source repo `~/Code/qaeros` (`plans/575-wrapped-tool-marketplace.md`) — taken as *concept only*. We don't need a marketplace; we need a **curated, one-tap catalogue** over the MCP client we already ship.

**Strategic fit:** UX + reach. Today adding an MCP server means hand-typing a URL and an auth header in [MCPServersView.swift](../../OpenGlasses/Sources/App/Views/MCPServersView.swift) — fine for a developer, a non-starter for a field engineer or a casual user. This plan adds (1) a **curated catalogue** of vetted servers with one-tap install that prefills the editor you already have, and (2) **transport breadth** so hosted servers actually connect: SSE in addition to the current Streamable-HTTP, and an OAuth device-code flow instead of pasting bearer tokens. Lands *after* [Plan R](R-mcp-egress-and-tool-poisoning-screen.md) so every catalogue install inherits the egress/poisoning screen.

**Effort:** ~3–4 days.

**Status:** 🚧 Core shipped (`feat/mcp-catalogue-transport`). Deterministic core complete and headless-tested:
- **Catalogue** — `MCPCatalog` (versioned model + lossy per-entry decode so one bad row can't sink the list + semantic validation) and a bundled `Resources/mcp-catalog.json` (Home Assistant, Slack, Notion, GitHub, Linear — exercising both transports × both auth kinds). `url_template` field substitution with missing-value guards.
- **One-tap install** — `MCPCatalogEntry.makeServerConfig` produces an ordinary `MCPServerConfig` that defaults to the **safe `.redact` egress policy** (never `.allow`) and flows through the *exact* discovery → Plan R `ToolDefinitionScanner` → router path a manual add uses. `MCPCatalogView` + install screen + prefilled `MCPServerEditorView` + a "Browse catalogue" entry in `MCPServersView`.
- **Transport parsing/selection** — `MCPTransportKind`/`MCPAuthKind` added to `MCPServerConfig` (backward-compatible decode — old saved servers keep loading). `MCPTransport` protocol with `HTTPTransport` extracted byte-identical from `mcpRequest` and a factory; `MCPClient.mcpRequest` now selects per server. Pure `SSEEventParser` (wire framing + chunk reassembly + JSON-RPC `id` correlation) shipped as the foundation for the deferred live stream.
- **Tests:** 37 headless (`MCPCatalogTests` 17, `MCPTransportTests` 9 incl. a `URLProtocol` request-shape stub, `SSEEventParserTests` 11). Full suite 631 green, Debug + Release.

**Deferred — re-scoped 2026-07-10:**
- The `SSETransport` streaming **initialize handshake** — **no longer blocked on "a real server."**
  Plan BL makes this load-bearing (its P2 alert channel is an outbound SSE subscription reusing
  `SSEEventParser`, with `Last-Event-ID` replay pinned in the peer contract) and supplies
  `MockOpsPeer`, a headless peer double to build the handshake against. Schedule with or before BL
  PR2, which depends on it; live validation is then a one-off. (Selecting an SSE server still
  throws `notYetSupported` cleanly today.)
- The `MCPOAuth` device-code/PKCE flow + Keychain token refresh — **keep deferred, deprioritized
  below the header item**: nothing on the current roadmap needs it (BL uses `X-API-Key`; every
  catalog OAuth entry has the paste-token fallback).

**Shipped since (`40341e0` / PR [#200](https://github.com/straff2002/OpenGlasses/pull/200), Plan BM P6, 2026-07-11):** the
catalog-expressible custom auth-header kind — `MCPAuthKind.header` (`{"kind": "header", "header": "X-API-Key"}`) with a
`makeServerConfig` branch + install-screen field, so a user can pick an `X-API-Key` peer from the
catalog instead of hand-adding one; this was the prerequisite for Plan BL P1's one-tap peer
install. Also shipped: `MCPClient.rediscoverAtLaunch()`, closing the launch-time re-discovery gap
noted below.

**Trust-model clarifications (2026-07-10):** the poisoning screen runs at **manual discovery time
only** — `discoverAllTools`'s sole caller is the "Discover Tools" button (`MCPServersView.swift:156-163`),
verdicts live in memory, and after relaunch MCP tools were previously simply *absent* until the user
re-tapped discover (quietly breaking "tap Notion, done"). **Resolved:** `MCPClient.rediscoverAtLaunch()`
now re-runs the scan at launch, closing this gap; per-call protection is solely the Plan R egress
screen in `NativeToolRouter`. And
"vetted" attaches to the catalog *template*, not the user-filled endpoint (`{host}` entries) —
`.redact` + the scanner still apply, but the trust language shouldn't be read as endpoint vetting.

---

## The gap (verified)

- `MCPClient` speaks **only** JSON-RPC over HTTP POST (`mcpRequest`, [:120](../../OpenGlasses/Sources/Services/MCPClient.swift)). Many hosted MCP servers use SSE / streamable transport with a session handshake — they won't connect today.
- Auth is a **static header** the user types (`MCPServerConfig.headers`, [:152](../../OpenGlasses/Sources/Services/MCPClient.swift)). Hosted servers increasingly want OAuth; pasting a long-lived token is both worse UX and worse security.
- Discovery is manual (`MCPServersView` has an "Add" sheet + a "Discover Tools" button). There's **no catalogue** — no curated list of "servers that are known to work", no setup hints, no one-tap.

---

## Files

- New: `Sources/Services/MCP/MCPCatalog.swift` — loads a bundled, versioned `mcp-catalog.json` (vetted entries: id, label, transport, base URL template, auth kind, scopes, setup hint, icon).
- New: `Sources/Services/MCP/MCPTransport.swift` — `protocol MCPTransport { func send(_:) async throws -> Data }`; conformers `HTTPTransport` (extract from current `mcpRequest`) and `SSETransport`.
- New: `Sources/Services/MCP/MCPOAuth.swift` — OAuth device-code / PKCE flow; stores tokens in Keychain, refreshes on 401.
- New: `Sources/App/Views/MCPCatalogView.swift` — browsable curated list; tap → prefilled `MCPServerEditorView` ([already exists](../../OpenGlasses/Sources/App/Views/MCPServersView.swift)) or straight into OAuth.
- New: `Resources/mcp-catalog.json` — the curated data (Home Assistant, Notion, GitHub, Slack, Linear, …).
- Touch: [MCPClient.swift](../../OpenGlasses/Sources/Services/MCPClient.swift) — `MCPServerConfig` gains `transport: MCPTransportKind` + `authKind`; `mcpRequest` delegates to the chosen `MCPTransport`; refactor `discoverTools`/`executeTool` to be transport-agnostic.
- Touch: [MCPServersView.swift](../../OpenGlasses/Sources/App/Views/MCPServersView.swift) — add a "Browse catalogue" entry above the manual "Add"; keep manual add as the escape hatch.

---

## Catalogue entry

```json
{
  "id": "home_assistant",
  "label": "Home Assistant",
  "transport": "sse",
  "url_template": "http://{host}:8123/mcp_server/sse",
  "auth": { "kind": "bearer", "hint": "Long-Lived Access Token from your HA profile" },
  "fields": [{ "key": "host", "label": "HA host / IP", "placeholder": "192.168.1.10" }],
  "scopes": ["control devices", "read sensors"],
  "icon": "house.fill",
  "notes": "Discovered tools are screened by Plan R before use."
}
```

Install = render `fields` → fill the `url_template` → either prefill `MCPServerEditorView` (bearer) or kick off `MCPOAuth` (oauth). The result is an ordinary `MCPServerConfig` that flows through the exact path that exists today — the catalogue is *convenience over the existing primitive*, not a new subsystem. This is the "single governance path" lesson from qaeros 575: one install funnel, one screen (Plan R), one router.

---

## Transport abstraction

```swift
enum MCPTransportKind: String, Codable { case http, sse }

protocol MCPTransport {
    func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data
}
```

- `HTTPTransport` — today's `mcpRequest` body, unchanged behavior.
- `SSETransport` — opens the SSE stream, performs the initialize handshake, correlates the `tools/list`/`tools/call` responses, applies the same auth headers / OAuth token.
- `MCPClient.discoverTools`/`executeTool` call `transport.request(...)` instead of the inline POST — a one-line indirection, so the egress screen (Plan R) and inbound framing (`PromptInjectionPolicy.wrap`) stay in exactly one place.

---

## Build order

1. Extract `HTTPTransport` from `mcpRequest`; introduce `MCPTransport` + `MCPTransportKind`; no behavior change (regression-guard with the existing path).
2. `SSETransport` + handshake + tests against a mock SSE server.
3. `MCPOAuth` device-code/PKCE + Keychain storage + 401 refresh; wire `authKind` into transports.
4. `MCPCatalog` + bundled `mcp-catalog.json` (start with 5–6 vetted servers).
5. `MCPCatalogView` → prefill editor / launch OAuth; "Browse catalogue" entry in `MCPServersView`.
6. Verify each catalogued server end-to-end: install → discover → screened (Plan R) → callable.

---

## Tests
- `MCPTransport` — HTTP path byte-identical to today; SSE handshake + response correlation; auth headers applied.
- `MCPOAuth` — device-code happy path, refresh on 401, token in Keychain not UserDefaults.
- `MCPCatalog` — `url_template` field substitution; malformed entry rejected.
- Integration — catalogue install produces a working `MCPServerConfig` that discovers tools through the Plan R screen.

---

## Open questions / decisions needed
- **Catalogue source:** bundled-only (ship in app, update via app update) or remotely-fetched (fresh, but another network trust surface)? *Recommendation: bundled in v1 — simpler, no new trust surface; revisit a signed remote feed later.*
- **Curation bar:** which servers ship in the first catalogue? *Recommendation: Home Assistant, Notion, GitHub, Slack, Linear — high-utility, well-known, and they exercise both bearer + OAuth.*
- **OAuth redirect on iOS:** `ASWebAuthenticationSession` vs device-code? *Recommendation: device-code where the server supports it (cleanest hands-free/companion UX); `ASWebAuthenticationSession` otherwise.*
- **Gating:** is MCP a general feature or `agentModeEnabled`-only? Today the local MCP *server* is agent-gated; the *client* is general. *Recommendation: keep the client + catalogue general (it's just tools the AI can call), per the existing split.*

---

## Dependencies / prereqs
- [MCPClient.swift](../../OpenGlasses/Sources/Services/MCPClient.swift) + [MCPServersView.swift](../../OpenGlasses/Sources/App/Views/MCPServersView.swift) (existing) — the client, config, and settings UI this extends. `MCPServerEditorView` is the prefill target.
- **[Plan R](R-mcp-egress-and-tool-poisoning-screen.md)** (prereq) — must land first so every catalogue install is screened. A one-tap install of an unscreened server would be a regression.
- Keychain (system) — OAuth token storage.

---

## Why this matters specifically for you
You already built the MCP client and a management UI; the reason it isn't useful yet to anyone but you is that connecting a real hosted server means knowing its URL, its transport, and pasting a token. A curated catalogue + SSE + OAuth turns "I have an MCP client" into "tap Notion, sign in, done" — which is the difference between a developer feature and something a Field Assist customer or a casual user actually switches on. Sequenced after Plan R, the convenience never outruns the safety.
