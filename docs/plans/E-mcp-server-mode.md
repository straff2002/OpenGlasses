# Plan E — Claude Code MCP Server Mode

**Strategic fit:** Developer-only feature. Lets a Claude Code session on a Mac "see through" OpenGlasses by exposing camera frames + display broadcast as MCP tools. Gated behind existing `agentModeEnabled` toggle (per Agentic Toggle memory pattern).

**Effort:** ~2 days

---

## Files

- New: `Sources/Services/MCPServer/MCPGlassesServer.swift` — local HTTP + WebSocket server on port 8765
- New: `Sources/Services/MCPServer/MCPProtocolBridge.swift` — MCP stdio protocol mapping for Claude Code client
- New: `Sources/Services/MCPServer/MCPTools.swift` — three MCP tool handlers
- New: `Sources/Views/MCPServerSettingsView.swift` — toggle + LAN URL display + tunnel docs link
- Touch: `Sources/Utils/Config.swift` — `mcpServerEnabled` flag (only effective when `agentModeEnabled` is also on)
- Touch: `Sources/App/OpenGlassesApp.swift` — start/stop server with config flag

---

## MCP tools exposed

| Tool | Args | Returns | Notes |
|---|---|---|---|
| `see_glasses` | none | latest JPEG as base64 | Reads from `CameraService.framePublisher` |
| `glasses_status` | none | `{ connected, frame_age_ms, viewer_count, last_frame_iso }` | Diagnostic |
| `send_to_glasses` | `{ text: string, mode: "tts"|"display" }` | confirmation | TTS speaks or pushes to display app |

---

## WebSocket protocol

Single HTTP server on `:8765` with two paths:

- **`/frames`** — internal-only ingest from iOS app. iOS pushes binary JPEG; bridge stores latest + ISO timestamp
- **`/display`** — egress to Claude Code or web display app. Receives JSON `{ type, text }` or `{ type, image_b64 }`

MCP client (Claude Code) talks to the bridge over stdio using Anthropic's MCP SDK.

---

## Architecture

```
Claude Code (Mac) ─ stdio ─> MCPProtocolBridge
                                 │
                                 ▼
                          MCPGlassesServer (:8765)
                            ┌───────┴───────┐
                       /frames           /display
                            │                │
                       iOS app             Claude Code
                       (push JPEGs)        (consume + send)
```

For remote access (outside LAN), user runs `cloudflared tunnel --url http://localhost:8765` themselves and configures the public URL in Claude Code. No tunneling shipped in-app.

---

## Build order

1. `MCPGlassesServer` — HTTP + WS endpoints, frame store, broadcast list
2. Wire `CameraService.framePublisher` → `/frames` ingest
3. `MCPProtocolBridge` — stdio MCP server using `MCP-Swift` or equivalent SDK
4. Three tool handlers
5. Settings UI + Config flag (gated behind `agentModeEnabled`)
6. End-to-end test: Claude Code on Mac calls `see_glasses` → returns recent frame

---

## Open questions

- **MCP SDK:** Is there a usable Swift MCP server SDK, or do we hand-roll the JSON-RPC? *Check Anthropic's MCP repo for Swift options.*
- **Auth:** One-time pairing code displayed in Settings, required on first Claude Code connection? Or bind to localhost only by default + user-opted tunnel for remote?
- **Frame rate / token cap:** Should `see_glasses` rate-limit to prevent token blowout if Claude Code polls in a tight loop? *Recommendation: serve same frame for 1s minimum.*
- **Tunneling docs:** Just link to cloudflared docs, or write a short OpenGlasses-specific setup guide?

---

## Dependencies / prereqs

- `agentModeEnabled` must be on (Settings gate — see Agentic Toggle memory)
- Existing `CameraService.framePublisher`
- Existing `TextToSpeechService` for `send_to_glasses` TTS mode
- Existing `WebRTCStreamingService` plumbing is reusable for the `/display` WebSocket pattern

---

## Why this matters specifically for you

You build a lot of features for OpenGlasses *with* Claude Code. This makes Claude Code itself see what you're seeing during development — debugging UI in your hand while Claude reads it, or letting Claude analyze a real-world scene without you typing what you see. Niche, but uniquely high-utility given your workflow.
