# Plan BP — Web App HUD Mirror (Ray-Ban Display, entitlement-free path)

**Status:** ✅ P1+P2 shipped (2026-08-02); P3/P4 hardware-deferred as designed. P1:
`WebHUDPayload` (Codable DTO, stable wire names) + `WebHUDRenderer` (pure single-file HTML —
additive-black asserted, amber non-cyan focus, `mrbd-web-app-capable` meta, D-pad keyboard nav,
inline/polling modes sharing one client-side render function, `</`-escape so payload text can't
close the script block, textContent-only DOM so markup never executes). P2:
`GlassesDisplayService.mirrorScreen` tap at the render-queue resolution point (ambient content
wraps to a lines-only screen; **mirror-only mode**: with `hudMirrorEnabled` the queue resolves
frames even without a native display — the backend send is capability-gated, which IS the
entitlement-free story), `WebHUDMirrorServer` (NWListener :8766 per the Plan E pattern, Keychain
token, pure tested router: page unauthenticated/data token-gated/405 on non-GET/404, HIPAA →
503 everywhere + listener killed on mode flip), settings surface (registration URL with
hash-riding token, rotate, desktop-preview HTML export). Gated
`agentModeEnabled && hudMirrorEnabled` (default off). 14 tests. P3 (LAN/tailnet/relay
reachability) and P4 (enrollment, optics legibility, poll-vs-battery, web-view lifecycle)
remain the 1-hour hardware experiments they were scoped as.

## Why this might matter

The native DAT display path (`MWDATDisplay`, Display Phases 1–4, Plans X/Y) is gated behind Meta's
dev-mode permission flow — the single thing blocking real on-glasses testing of everything we've
shipped. Meta sanctions a **second, entitlement-free surface: Web Apps.** The glasses render a
600×600 HTML page in a built-in web view; the page is enrolled by registering a single HTTPS URL in
Developer Mode (QR deep-link via the Meta AI app). No DAT display entitlement, no `Wearables`
session, no waiting on the permission gate.

Two payoffs:

1. **Real hardware, now.** A 600×600 web mirror of one read-mostly vertical (Teleprompter, Now/Next
   task cards) could run on shipping Ray-Ban Display hardware before the native entitlement lands.
2. **Hardware-free dev loop.** The surface is previewable in any desktop browser: 600×600 viewport,
   arrow keys stand in for the D-pad. That is the fastest render-iterate loop we have for HUD
   content — faster than the phone-side `HUDPreviewView`, and it exercises a genuinely different
   renderer.

## What this is NOT (architecture honesty)

This is **not a third `GlassesDisplayBackend`** (Plan AH's seam). The seam models a *push* channel:
the phone calls `Display.send(...)` and the glasses fire `onClick` back into `HUDRouter`. The web
surface is the opposite — a **pull** channel: the glasses fetch a page, the page polls for data, and
there is no callback path into the app process. Forcing it through the AH seam would corrupt the
seam's contract. It's a *mirror*, not a backend: read-mostly, eventually-consistent, phone remains
the source of truth. `HUDItem.action` closures are not representable; item *labels* render, actions
don't fire (v1).

## Platform constraints (drive every design choice)

- **600×600, additive display — black = transparent.** Pure-black background is mandatory (it's
  free, invisible pixels); high-contrast light-on-black text only. No photos/gradients. Focus
  indicator must be high-contrast but **not cyan** (house rule) — use white/amber weight+outline.
- **Input arrives as plain keyboard events.** D-pad maps to arrow keys / Enter / back. The focus
  model is therefore ordinary DOM keyboard nav — deterministic and unit-testable in a headless DOM.
- **No typing on glasses.** All mutation happens phone-side; the mirror only reads.
- **Exactly one URL is registered.** Everything else — auth token, app route — rides the URL hash
  (`#t=<token>&app=<route>`), which conveniently never appears in HTTP requests or server logs.

## Phases

### P1 — Deterministic core: `WebHUDRenderer` (the one PR if we stop here)

A pure function `HUDScreen → String` producing a **self-contained single-file HTML page** (inline
CSS/JS, no build step, no external fetches):

- Input is the existing SDK-free DSL (`HUDScreen`/`HUDLine`/`HUDItem`,
  `Sources/Services/Display/HUDScreen.swift`) — same fixtures the native renderer uses. `HUDIcon`
  maps to inline glyphs; `HUDEmphasis`/`HUDButtonStyle` map to an additive-safe stylesheet.
- Keyboard nav baked into the page: ▲▼ moves focus across items, page scroll for overflow; Enter is
  a no-op in v1 (renders items as a focusable list, not live buttons).
- A `data` mode: the page either inlines a JSON payload (static export) or polls a relative
  `hud.json` every 1–2 s and re-renders — same render function client-side, so the poll path adds
  no second layout implementation.
- **Tests:** golden-fixture snapshots of the emitted HTML for the existing HUD fixture corpus;
  property checks (black background asserted, no external URLs, every `HUDItem` present exactly
  once, renderKey → stable output). Fully headless, no `Wearables`, no network.
- **Dev harness:** a debug action that writes the rendered file to disk / shares it, for the
  desktop-browser 600×600 preview loop.

### P2 — Phone serving edge (flag-gated), first mirrors

Serve the page + `GET /hud.json` from the phone, reusing the Plan E listener pattern
(`MCPGlassesServer`, `NWListener` on :8765, gated `agentModeEnabled && mcpServerEnabled`): either a
second route set on that server or a sibling listener, gated `agentModeEnabled && hudMirrorEnabled`
(default **off**), bearer token checked against the hash-provided `t`.

- First mirrors (read-mostly by construction): **Teleprompter** (`TeleprompterScreen` already
  renders through the DSL; scroll position streams naturally through the poll) and the **Now/Next
  task cards** (`HUDTaskSource`).
- The mirror source taps the same render queue `GlassesDisplayService` feeds — whatever screen is
  current is what `hud.json` serves. No parallel content pipeline.
- **Privacy hard line:** HIPAA mode hard-disables the mirror (vault/health content must not cross a
  network surface); token is read-only scope; no conversation content beyond what the HUD already
  shows.
- Check-off / interactive mutations are explicitly **out of scope** (needs a POST-back + conflict
  story; only worth designing after P4 proves the surface).

### P3 — Reachability (the honest unknown; decide at hardware contact)

Whether the glasses web view can reach a phone-LAN URL at all, and whether Developer-Mode
registration demands public HTTPS, is unvalidated. Options ladder, cheapest first:

1. **LAN HTTP** to the phone's address (works ⇒ P2 is complete as-is).
2. **Tailnet HTTPS** — Tailscale serve/funnel in front of the phone listener (real cert, no cloud
   code).
3. **Cloud relay** — publish `hud.json` through the gateway / ops-platform bridge (Plan BL) and
   serve the static page from the relay. Most robust, most moving parts; only if 1–2 fail.

This phase is deliberately unresolved on paper; it is a 1-hour experiment with hardware in hand,
not a design problem.

### P4 — On-glasses validation

Developer-Mode URL registration + QR enrollment; smoke: legibility at 600×600 optics, D-pad nav
feel, poll cadence vs. battery, web-view lifecycle (does the page survive glance-away/return, does
`localStorage` persist).

### P5 — Push transport & pairing polish (follow-up, post-P4)

Field evidence from other apps on this surface says WebSocket/fetch are the network
primitives available to the glasses web view — which means the 2 s poll in
`WebHUDMirrorServer` is probably not the ceiling:

- **Push over WebSocket:** a minimal, dependency-free WS client inlined in the rendered page
  (no bundler, no client library — the page stays a single self-contained file per P1's
  contract), falling back to the existing poll when the socket can't connect. Server side is
  one upgrade route on the existing listener. Poll cadence vs. battery (P4's question)
  largely dissolves if push works.
- **D-pad room-code pairing:** if URL-hash enrollment proves awkward on-device, a 6-char
  code editor driven entirely by D-pad (left/right cursor, up/down character cycle, Enter
  submit) is the keyboard-less fallback — a pure reducer, fixture-testable like the rest of
  the renderer.
- **Embedding gotcha (recorded for whenever third-party content appears):** iframes steal
  D-pad focus unless `tabindex="-1"` is set — the focus model must keep arrow keys on our
  own focusables.

## Open questions

- LAN reachability / HTTPS requirement (P3 — the gating unknown).
- Does the glasses web view support SSE/WebSocket, or is polling the ceiling? (P5 bets yes
  on WebSocket; verify at hardware contact.)
- Web-view lifecycle: process kept alive between glances? poll timers throttled?
- Input surface beyond arrows/Enter (touchpad swipe mapping, any extra keys).
- Whether the registered-URL hash survives enrollment round-trip intact.

## Relationship to other plans

- **AH (EVEN G2):** complementary, not competing. AH is a true second *push* renderer behind the
  seam; BP is a pull mirror that sidesteps the entitlement on Meta's own hardware. P1's renderer
  shares the DSL and fixtures with both.
- **X/Y (interactive HUD / launcher):** BP mirrors their screens read-only; it does not replace
  band interaction.
- **E (MCP server):** P2 reuses its listener pattern and gating precedent.
- **BL (ops-platform bridge):** the P3 cloud-relay option, if LAN/tailnet fail.
