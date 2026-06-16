# Plan V — Curated MCP Catalogue & Transport Breadth

**Source pattern:** The single-governance-path "wrapped tool marketplace" idea from our idea-source repo `~/Code/qaeros` (`plans/575-wrapped-tool-marketplace.md`) — taken as *concept only*. We don't need a marketplace; we need a **curated, one-tap catalogue** over the MCP client we already ship.

**Strategic fit:** UX + reach. Today adding an MCP server means hand-typing a URL and an auth header in [MCPServersView.swift](../../OpenGlasses/Sources/App/Views/MCPServersView.swift) — fine for a developer, a non-starter for a field engineer or a casual user. This plan adds (1) a **curated catalogue** of vetted servers with one-tap install that prefills the editor you already have, and (2) **transport breadth** so hosted servers actually connect: SSE in addition to the current Streamable-HTTP, and an OAuth device-code flow instead of pasting bearer tokens. Lands *after* [Plan R](R-mcp-egress-and-tool-poisoning-screen.md) so every catalogue install inherits the egress/poisoning screen.

**Effort:** ~3–4 days.

**Status:** 🚧 Core shipped (`feat/mcp-catalogue-transport`). Deterministic core complete and headless-tested:
- **Catalogue** — `MCPCatalog` (versioned model + lossy per-entry decode so one bad row can't sink the list + semantic validation) and a bundled `Resources/mcp-catalog.json` (Home Assistant, Slack, Notion, GitHub, Linear — exercising both transports × both auth kinds). `url_template` field substitution with missing-value guards.
- **One-tap install** — `MCPCatalogEntry.makeServerConfig` produces an ordinary `MCPServerConfig` that defaults to the **safe `.redact` egress policy** (never `.allow`) and flows through the *exact* discovery → Plan R `ToolDefinitionScanner` → router path a manual add uses. `MCPCatalogView` + install screen + prefilled `MCPServerEditorView` + a "Browse catalogue" entry in `MCPServersView`.
- **Transport parsing/selection** — `MCPTransportKind`/`MCPAuthKind` added to `MCPServerConfig` (backward-compatible decode — old saved servers keep loading). `MCPTransport` protocol with `HTTPTransport` extracted byte-identical from `mcpRequest` and a factory; `MCPClient.mcpRequest` now selects per server. Pure `SSEEventParser` (wire framing + chunk reassembly + JSON-RPC `id` correlation) shipped as the foundation for the deferred live stream.
- **Tests:** 37 headless (`MCPCatalogTests` 17, `MCPTransportTests` 9 incl. a `URLProtocol` request-shape stub, `SSEEventParserTests` 11). Full suite 631 green, Debug + Release.

**Deferred (risky live-network bits, not in this PR):** the `SSETransport` streaming **initialize handshake** against a real server (the parser ships and is tested; selecting an SSE server currently throws `notYetSupported` cleanly rather than silently no-op'ing), and the `MCPOAuth` device-code/PKCE flow + Keychain token refresh (OAuth catalogue entries install today by pasting a token into the prefilled editor). Both are pure live-network work that needs a real server/IdP to exercise — to be picked up as the Plan V fast-follow.

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
