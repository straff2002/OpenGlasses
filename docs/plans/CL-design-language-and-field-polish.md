# Plan CL — Design Language & Field Polish

**Status:** 🚧 In progress (2026-08-04)
**One PR** per house style.

## Why

The app's screens grew one feature at a time: 35+ stock `Form` screens, per-row ad-hoc
status colors (green/orange/red/gray hardcoded per view), and every surface reinventing
its own pill/badge/chip inline. The approved core identity — status card with merged
pills, coral waveline + ambience, capsule primary dock, Settings as a parent hub — is
strong, but nothing around it shares a visual language. Meanwhile the README is 560
lines of dense text with zero images for an app whose whole point is visual.

This plan gives the app **one design language** and closes three field gaps surfaced by
ecosystem study (techniques described on their own merits).

## P1 — Design system (`OGDesign`)

A single presentation-only file of primitives every screen composes. Rules the
primitives enforce:

- **One accent per screen.** Everything tints from the environment accent
  (`\.appAccent`) — the user's chosen preset keeps working; coral stays the default AI
  accent. Never a rainbow of per-row system colors. Status semantics (ok/warn/error)
  keep their colors but only as **dots**, never as row-icon tints.
- **Liquid Glass, not flat cards.** Cards and chrome use the iOS 26 glass materials
  already proven in the bottom dock — layered on a subtly warm adaptive canvas.
- **Continuous-corner grouped cards** (22pt), hairline dividers, 52pt rows.
- **Semantic type.** Dynamic-Type-safe (`.body`, `.footnote`, …), never fixed sizes.

Primitives: `OGCard` / `OGSection` (header+card+footer), `OGRow` (accent-tinted icon
tile, title/subtitle, trailing value, chevron), `OGIconTile`, `OGChip`, `OGBadge`,
`OGStatusPill` (dot + label capsule), `OGHeroDeviceCard` (dark hero: device name, live
battery/thermal/connection, capability chips), `OGStatTile`, `OGNotice`,
`ogFormStyle()` (warm canvas + accent tint for legacy Form screens).

Applied in this PR: Settings hub (hero device card + icon-tile rows with trailing value
summaries), the seven category screens (icon tiles + `ogFormStyle()`), Developer panel
and mic-route picker (built from primitives). The Voice tab's approved elements are
untouched. Remaining screens adopt incrementally later.

Also: delete dead `ConnectionBanner` (superseded by the merged status card; its debug
log moves to the Developer panel).

## P2 — Developer test panel (Settings → Advanced → Developer)

Cold-start, one-tap verification that each subsystem is alive, so field debugging
doesn't start from "say the wake word and guess":

- Tests: **Glasses link**, **Camera photo**, **HUD render**, **AI query** (tiny live
  round-trip on the active model), **TTS**, **Wake word**.
- Each: spinner → ✓/✗ + failure message inline; timings recorded; results appended to
  the persistent field log (`debug-events.log`).
- Deterministic core first: `SubsystemTestRunner` with injected async probes, unit
  tested; the view is a thin shell. Live probes wired via existing services
  (`CameraService`, `GlassesDisplayService.showNotification`, `LLMService`,
  `TextToSpeechService`, `WakeWordService` state).
- Debug-event tail view (monospace, copy button) lives here too.

## P3 — Headset mode (three-way mic route)

On Display glasses, holding the glasses' hands-free (HFP) mic link makes the firmware
put its call screen over the lens HUD — mic and HUD fight. New unified route setting
replaces the `useGlassesMicForWakeWord` boolean (migrated):

- `MicRoute: phone | glasses | headset`.
  - **phone** — session options exclude Bluetooth entirely so iOS cannot silently
    re-route input to the glasses.
  - **glasses** — today's behavior (BT options + prefer glasses-named HFP/BLE port).
  - **headset** — BT options + prefer the first HFP input that is **not** the glasses;
    **never** falls back to the glasses (that would resurface the call screen); falls
    back to phone mic with an honest notice if no headset materializes. HFP being
    bidirectional, TTS rides to the earbuds too — mic + voice in the ear, lens HUD
    free. The pocket setup.
- Route reconciliation after every switch: report the route that actually took, not
  the one requested.
- Picker in Settings → Glasses & Privacy, built from `OGRow`.

## P4 — README revamp (demo-first)

Restructure: pitch paragraph → gallery slot → verb-grouped feature index → quick start;
dense setup detail (Meta credentials, Universal Links, signing overlays, configuration,
troubleshooting) moves to `docs/BUILDING.md`. Gallery ships as a placeholder comment:
simulator captures showed error banners and test content (no glasses, fresh install),
so real screenshots are captured manually on a device with glasses connected and added
to `docs/media/` later.

## P5 — Hermes agent bridge backend

Optional LAN "brain": a WebSocket client for the Hermes agent bridge protocol (JSON
frames — `query`/`response`/`capture_photo`/`photo`/`new_session`/`ping`; binary PCM
declined, the app always speaks replies with its own TTS stack). Pure
`HermesBridgeProtocol` codec (unit tested) + `HermesBridgeService` live edge with an
injected photo provider (bridge asks for eyes mid-query → glasses camera JPEG).
Turn routing: when enabled, the bridge leads the turn and any failure falls through to
the normal local/cloud path. Gateway-class feature — gated behind Agent Mode per house
rule. Settings → Connections → Hermes Bridge (host/port/optional token, probe, session
reset).

## P6 — Brave Search provider

`web_search` gains Brave Search API as a third configured tier (Perplexity → Tavily →
Brave → DuckDuckGo): independent index, snippets stitched with sources, key in
Settings → Services → Web Search (Keychain).

## Out of scope

Restyling all 89 view files (incremental adoption follows); Chat/personas screens;
any live-device HFP verification (device-pending, tests cover the route-selection
logic headlessly).

## Test gate

`MicRoutePolicy` (route → session options + preferred-input selection, pure) and
`SubsystemTestRunner` unit suites; full suite + Release build green before PR.
