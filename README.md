# OpenGlasses

[中文文档 (Chinese)](README.zh-CN.md)

An open-source voice-powered AI assistant for Ray-Ban Meta smart glasses. 85+ built-in tools, multi-LLM support (cloud + on-device) with automatic model routing, personas with simultaneous wake words, an in-lens HUD with hands-free task control on Ray-Ban Display glasses, an on-device knowledge graph, live translation, hands-free field-service guidance, real-time vision coaching, MCP tool servers, and CarPlay + Apple Watch companions — all controlled hands-free by voice.

> **Note**: The Meta Wearables SDK is currently in **developer preview**. App Store distribution is not yet supported — each user must build the app from source with their own Meta developer credentials.

---

## Quick Start

1. **Clone and generate the Xcode project** — `OpenGlasses.xcodeproj` is not in git; each developer creates it locally with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (avoids `project.pbxproj` merge conflicts):

   ```bash
   git clone https://github.com/straff2002/OpenGlasses.git
   cd OpenGlasses
   brew install xcodegen
   ./Scripts/generate-xcodeproj.sh
   open OpenGlasses.xcodeproj
   ```

   After `git pull`, run `./Scripts/generate-xcodeproj.sh` again if `project.base.yml` changed. Meta credentials, team ID, and signing: [Building from Source](#building-from-source) (optional `./Scripts/setup-local-dev.sh` for a personal overlay).

2. **Build on your iPhone** from Xcode (⌘R) — set signing team if prompted
3. Add an AI model in **Settings → AI Models** (Anthropic, OpenAI, Gemini, or a local model)
4. Pair your Ray-Ban Meta glasses via the Meta AI app
5. Say **"Hey OpenGlasses"** and ask anything

---

## Features

### Personas — Multiple AI Personalities

Each persona has its own wake word, AI model, and personality. All listen simultaneously.

| Say | What Happens |
|-----|-------------|
| "Hey Claude" | Routes to Claude Sonnet with your professional prompt |
| "Hey Jarvis" | Routes to a local on-device model with a concise style |
| "Hey Computer" | Routes to GPT-4o with a technical personality |

**Configure:** Settings → Personas → Add. Pick a wake word, assign a model and prompt preset.

### On-Device Local LLM

Run AI models entirely on your iPhone — no internet, no cloud, no API keys.

1. Settings → AI Models → Add Model → pick **"Local (On-Device)"**
2. **Download & Manage Models** → download from HuggingFace
3. Select your downloaded model and tap **Add**

**Recommended models:**

| Model | Size | Best For |
|-------|------|----------|
| **Gemma 4 E2B** (default agent) | 3.6 GB | Best on-device agent — vision, tool calling, 140+ languages (needs 8 GB RAM) |
| SmolVLM2 2.2B | 1.5 GB | Vision — sees photos + video |
| Qwen 2.5 3B | 1.8 GB | Strong text reasoning + tool use |
| Gemma 2 2B | 1.5 GB | Lightweight general purpose |
| Qwen 2.5 0.5B | 0.4 GB | Ultra-light, basic |

**Gemma 4 E2B** is the default on-device agent — it runs automatically when no cloud model is configured. Models are stored persistently and work fully offline after download. Toggle **Offline Mode** in Settings → Tools to disable internet-dependent tools.

### 85+ Native Tools

All voice-activated. Say what you need naturally — the AI picks the right tool.

| Category | Tools |
|----------|-------|
| **Information** | Web Search (Perplexity + DuckDuckGo), News, Weather, Date/Time, Dictionary, Currency |
| **Productivity** | Calendar, Reminders, Alarms, Timers, Pomodoro, Notes, Contextual Notes (GPS+time tagged), Clipboard |
| **Communication** | Phone Calls, iMessage, WhatsApp, Telegram, Email, Contact Lookup |
| **Navigation** | Directions (Apple/Google Maps), Nearby Places, Save Locations, Geofencing Alerts |
| **Media** | Music Control (play/pause/skip + search by song/artist), Shazam Song ID, Open Apps |
| **Smart Home** | HomeKit (lights, switches, fans, thermostats, locks, scenes), Home Assistant (REST API), Siri Shortcuts |
| **Vision** | QR/Barcode Scanner, Face Recognition, Smart Capture (business cards/receipts/flyers → action), Money/Medication/Color ID (accessibility), Privacy Filter |
| **Memory** | Object Memory ("where are my keys?"), Social Context (per-person facts), User Memory, Voice-Taught Skills |
| **AI Features** | Live Translation, Live Coach (real-time vision coaching), Memory Rewind (ambient audio recall), Ambient Captions, Meeting Summaries, Conversation Summaries |
| **Fitness** | Workout Tracking, Exercise Logging, HealthKit, Pose Analysis, Step Goals |
| **Device** | Flashlight, Brightness, Device Info, Step Count |
| **Safety** | Emergency Info (local numbers + GPS), Daily Briefing, Navigation Assistance (accessibility preset) |
| **Integration** | OpenClaw Gateway (50+ skills), MCP Servers (universal tool protocol), Custom Tools |

### Live Coach — Real-Time Vision Coaching

The glasses watch what you're doing and give short, spoken corrections on a loop — one tight sentence at a time, no repetition. Built-in domains: posture, cooking technique, guitar, climbing, sports tactics — or define your own.

| Say | What Happens |
|-----|-------------|
| "Coach my posture" | Periodic spoken feedback on your alignment |
| "Watch my knife technique" | Live cooking-form coaching |
| "Stop coaching" | Ends the session |

### Smart Capture

Point at a business card, receipt, or event flyer — OpenGlasses reads it on-device and offers to act.

| Say | What Happens |
|-----|-------------|
| "Save this card" | Extracts name/company/phone/email → save to Contacts |
| "Log this receipt" | Extracts merchant/total/date → log the expense |
| "Add this event" | Extracts title/date/location → create a calendar event |

### Voice-Taught Skills

Teach the AI new behaviors at runtime — no code needed.

| Say | What Happens |
|-----|-------------|
| "Learn that when I say expense this, create a note tagged EXPENSE" | Skill saved, auto-applies forever |
| "Learn that when I say goodnight, turn off all lights" | Triggers HomeKit/HA on the phrase |
| "List skills" | Shows all taught skills |
| "Forget expense this" | Removes the skill |

### Object Memory

Remember where you put things. Uses GPS to calculate distance.

| Say | What Happens |
|-----|-------------|
| "Remember my car is in lot B level 3" | Saves with GPS + timestamp |
| "Where are my keys?" | "Your keys were on the kitchen counter, 2 hours ago. That's very close to where you are now." |
| "Where did I park?" | Retrieves car location with distance |

### Live Translation

Continuous real-time translation of spoken foreign language.

| Say | What Happens |
|-----|-------------|
| "Start translating Spanish to English" | Begins continuous translation |
| "Stop translating" | Ends session, reports count |
| "Switch to Japanese to English" | Changes languages on the fly |

Supports 25+ languages including Spanish, French, German, Japanese, Chinese, Korean, Arabic, and more.

### Social Context

Build dossiers about people you meet.

| Say | What Happens |
|-----|-------------|
| "Remember Sarah works at Google and likes hiking" | Fact saved |
| "What do I know about Sarah?" | "About Sarah: works at Google, likes hiking. First noted 3 days ago." |

Works alongside face recognition — when the AI recognizes someone, it can recall your notes about them.

### On-Device Knowledge Brain

A private, on-device knowledge graph that quietly connects what you tell it — people, places, things, and how they relate — with zero cloud calls. Notes, social context, face encounters, and meeting summaries all feed it, and the AI can query the whole graph in one step.

| Say | What Happens |
|-----|-------------|
| "Who did I meet at the conference?" | Recalls people and where/when you encountered them |
| "How do I know Sarah?" | Traces the facts and relationships linking you |

Native-first — it works without any external gateway, and everything stays on the phone.

### Barge-In

Interrupt the AI mid-sentence by saying any wake word. It stops immediately and starts listening to your new question.

### Prompt Presets

Switch AI personality without reconfiguring. Built-in presets:

| Preset | Style |
|--------|-------|
| **Default** | Balanced, 2-4 sentences, conversational |
| **Concise** | 1-2 sentences max, no filler |
| **Technical** | Precise, jargon-appropriate, data-dense |
| **Creative** | Playful, witty, expressive |
| **Navigation Aid** | Spatial awareness, obstacle detection, sign reading |

Create your own in Settings → System Prompt.

### Custom Tools

Define new tools without writing code. Map to Siri Shortcuts or URL schemes.

Settings → Transparency → Custom Tools → Add:
- **Shortcut tool**: triggers a Siri Shortcut by name
- **URL tool**: opens a URL with parameter substitution

Example: a "log_water" tool that runs your "Log Water" shortcut when the AI decides you need it.

### MCP Servers (Model Context Protocol)

Connect to any MCP-compatible tool server directly from your phone.

Settings → Transparency → MCP Servers → Add:
- Enter server URL + auth headers
- Tap "Discover Tools" — all tools auto-appear
- The AI can call them alongside native tools

Popular MCP servers: Home Assistant, Notion, GitHub, Slack, Todoist, and hundreds more.

### Home Assistant Integration

Direct REST API control of your HA instance — works alongside or instead of HomeKit.

Settings → Services → Home Assistant:
- **HA URL**: e.g. `http://192.168.1.100:8123`
- **Token**: Long-Lived Access Token (HA → Profile → Security)

Voice commands: "Turn on the living room lights", "Set thermostat to 72", "Run the goodnight automation", "List all sensors"

### Transparency & Privacy

See exactly what data the AI receives and what network calls are made.

| Setting | What It Shows |
|---------|--------------|
| **Tools** | All 85+ tools with enable/disable toggles |
| **Prompt Inspector** | Full system prompt, injected context, token estimate |
| **Network Activity** | All HTTP requests categorized by Meta/AI/App/Other |
| **Offline Mode** | One toggle disables all internet-requiring tools |

The agentic path is hardened against **prompt injection** — untrusted content (web pages, scanned text, tool output) can't hijack the assistant into running sensitive tools. High-impact actions stay behind explicit confirmation and the agent-mode gate.

### Camera & Streaming

- **Voice-Activated Photo Capture** — "take a picture" or "what's this?"
- **QR/Barcode Scanner** — "scan this code" (Vision framework, works offline)
- **Live Camera Preview** — real-time view of glasses POV
- **Video Recording** — MP4 with configurable bitrate
- **RTMP Broadcasting** — live stream to YouTube, Twitch, Kick
- **WebRTC Browser Streaming** — shareable URL for peer-to-peer viewing
- **Privacy Filter** — auto-blurs bystander faces

### Ray-Ban Display HUD

On Ray-Ban **Display** glasses, OpenGlasses mirrors content into the in-lens heads-up display — and lets you act on it hands-free with the **Neural Band**. Additive and off by default (Settings → Hardware → Glasses Display); a safe no-op on glasses without a display.

- **AI responses & live captions** — spoken answers and the ambient-caption line appear in-lens as they happen.
- **Notification & navigation cards** — calendar and geofence reminders, plus turn-by-turn Navigation Assist guidance, rendered with icons and a safety treatment.
- **Interactive task cards** — run a workflow or a Field Assist procedure as a **Now / Next** card and complete steps with the Neural Band (Done / Skip / Back, or branch choices) or by voice ("next", "done", "skip", "back").

Built on Meta's on-device display design system, so contrast, colour, and legibility are tuned for the waveguide automatically.

### Text-to-Speech

24 ElevenLabs voices (10 female, 14 male) with iOS fallback:
- **Female**: Rachel, Sarah, Matilda, Emily, Charlotte, Alice, Lily, Dorothy, Serena, Nicole
- **Male**: Brian, Adam, Daniel, George, Chris, Charlie, James, Dave, Drew, Callum, Bill, Fin, Liam, Thomas

**Emotion-Aware TTS** adjusts tone automatically — warmer for good news, calmer for instructions, concerned for warnings.

### Realtime Modes

| Mode | How It Works |
|------|-------------|
| **Voice Mode** | Wake word → transcription → any LLM → TTS (most flexible) |
| **Gemini Live** | Real-time audio/video streaming with Google Gemini |
| **OpenAI Realtime** | Real-time audio/video streaming with OpenAI |

### Smart Model Routing

Assign models to **Fast**, **Balanced**, and **Best** tiers, then let OpenGlasses pick per request — a quick local model for live coaching, your best cloud model for hard diagnostics. Or turn routing off and pin everything to one model.

**Configure:** Settings → AI Models → Model Routing.

### CarPlay & Apple Watch

- **CarPlay** — hands-free voice assistant on your car's display.
- **Apple Watch** — companion app and widget for quick control and glanceable status.

---

## Enterprise

Commercial features for teams and regulated industries. These are licensed separately from the open-source core — see [License](#license) or contact Skunkworks NZ.

### Field Assist — Guided Field Service

Hands-free, step-by-step guidance for technicians and other hands-busy work. Procedures branch on what you report or what the camera sees, surface safety reminders before each step, cite their source material, and write an audited session log you can export. Stuck? Escalate to a live remote expert with glasses video. Domain knowledge lives in **vaults** (e.g. refrigeration, HVAC, electrical) you author and extend yourself.

| Say | What Happens |
|-----|-------------|
| "Start a refrigeration session" | Loads the vault and begins the procedure |
| "The gauge reads 38 psi" | AI evaluates the reading and branches to the right next step |
| "Next step" / "Go back" / "Repeat that" | Navigate the procedure hands-free |
| "Call an expert" | Bridges to a remote human with live glasses video |

### Medical Compliance

Professional-grade safeguards for clinical recordings, available as an in-app subscription.

- **Encryption at rest** — recordings and transcripts protected with `NSFileProtectionComplete`
- **Biometric app lock** — Face ID / Touch ID required on every launch
- **Audit logging** — every data-access event timestamped and exportable
- **Medical export** — FHIR R4, HL7, and PDF export to Epic, Cerner, and more
- **Data retention** — configurable auto-purge with secure deletion
- **Leakage prevention** — cloud tools disabled, excluded from iCloud backup
- **International frameworks** — HIPAA, GDPR, AU Privacy Act, NZ HIPC, PIPEDA, UK DPA

---

## Requirements

- **iOS 26+**
- **Xcode 26+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`)
- **Physical iPhone** (Bluetooth, camera, microphone required)
- **Ray-Ban Meta smart glasses** (paired via Meta AI app)
- At least one LLM: API key (Anthropic, OpenAI, Gemini, etc.) OR a downloaded local model

---

## Building from Source

### 1. Clone

```bash
git clone https://github.com/straff2002/OpenGlasses.git
cd OpenGlasses
```

### 2. Meta Developer Credentials

1. Go to [wearables.developer.meta.com](https://wearables.developer.meta.com/)
2. Create an account, organization, and app
3. Note your **Meta App ID** and **Client Token**
4. In Meta dashboard → iOS settings, enter your Apple Team ID, Bundle ID, and Universal Link URL

### 3. Configure Meta keys (Info.plist)

Put your Meta **App ID**, **Client Token**, and universal-link URL in the `MWDAT` section. Either:

- **Recommended:** run `./Scripts/setup-local-dev.sh`, edit `Config/Info/Info.personal.plist` (gitignored), then `./Scripts/generate-xcodeproj.sh` again; or
- Edit the shared template `OpenGlasses/Info.plist` if you are not using a personal overlay.

```xml
<key>MWDAT</key>
<dict>
    <key>AppLinkURLScheme</key>
    <string>https://YOUR-DOMAIN/YOUR-PATH</string>
    <key>MetaAppID</key>
    <string>YOUR_META_APP_ID</string>
    <key>ClientToken</key>
    <string>AR|YOUR_META_APP_ID|YOUR_CLIENT_TOKEN_HASH</string>
    <key>TeamID</key>
    <string>$(DEVELOPMENT_TEAM)</string>
</dict>
```

### 4. Universal Links

Host an `apple-app-site-association` file at `https://YOUR-DOMAIN/.well-known/apple-app-site-association`:

```json
{
  "applinks": {
    "details": [{
      "appID": "YOUR_TEAM_ID.YOUR_BUNDLE_ID",
      "paths": ["/YOUR-PATH/*"]
    }]
  }
}
```

### 5. Enable Developer Mode

On iPhone: Meta AI app → Settings → About → tap version number **5 times** → toggle Developer Mode on.

### 6. Build & Run

Same as [Quick Start](#quick-start) step 1. The repo ships [`project.base.yml`](project.base.yml) plus optional [`project.local.yml`](project.local.yml.example); XcodeGen writes `OpenGlasses.xcodeproj` locally. Do not commit the generated project.

```bash
brew install xcodegen
./Scripts/generate-xcodeproj.sh
open OpenGlasses.xcodeproj
```

[Xcode Cloud](https://developer.apple.com/documentation/xcode/xcode-cloud) runs `./Scripts/generate-xcodeproj.sh` in `ci_scripts/ci_post_clone.sh` (full app + watch + tests).

Default generate includes **watch** and **unit tests**. To build a slimmer project locally (iPhone + widget only):

```bash
cp .openglasses-generate.env.example .openglasses-generate.env   # gitignored
./Scripts/generate-xcodeproj.sh
```

Or one-off: `OPENGLASSES_SKIP_WATCH=1 OPENGLASSES_SKIP_TESTS=1 ./Scripts/generate-xcodeproj.sh`

#### Optional: personal signing & Meta config

Team ID, entitlements, and Meta keys differ per developer. Those settings live in **gitignored** files (never committed), merged on top of the shared spec via `project.local.yml`:

| File (gitignored) | Purpose |
|-------------------|---------|
| `project.local.yml` | Team ID + `DEVELOPMENT_TEAM`; personal entitlements / Info.plist paths (see `project.local.yml.example`) |
| `Config/Entitlements/Personal/*.entitlements` | Capabilities your provisioning profile supports |
| `Config/Info/Info.personal.plist` | Full app `Info.plist` when you need your own Meta `ClientToken` / URL schemes |

First-time setup from the templates:

```bash
./Scripts/setup-local-dev.sh
```

Edit `project.local.yml` (`developmentTeam`) and the files under `Config/` as needed, then run `./Scripts/generate-xcodeproj.sh` again.

If you only need Xcode’s automatic signing with the shared entitlements, skip the local overlay and set your team in Xcode after opening the generated project.

Select your iPhone, fix signing if prompted, and run (⌘R).

---

## Configuration

All settings are in-app — no source code editing needed.

### API Keys (Settings → AI Models)

| Service | Purpose | Where to Get |
|---------|---------|--------------|
| Anthropic | Claude LLM | [console.anthropic.com](https://console.anthropic.com/) |
| OpenAI | GPT + Realtime | [platform.openai.com](https://platform.openai.com/) |
| Google Gemini | Gemini Live | [aistudio.google.com](https://aistudio.google.com/) |
| Groq | Fast inference | [console.groq.com](https://console.groq.com/) |
| ElevenLabs | Natural TTS | [elevenlabs.io](https://elevenlabs.io/) |
| Perplexity | Web search | [perplexity.ai/settings/api](https://perplexity.ai/settings/api) |

### Services (Settings → Services & Integrations)

| Service | Settings |
|---------|----------|
| **ElevenLabs** | API key + voice selection (24 voices) |
| **Perplexity** | API key (DuckDuckGo fallback if not set) |
| **Live Streaming** | Platform + RTMP URL + stream key |
| **OpenClaw** | Enable + connection mode + host/port + token |
| **Home Assistant** | URL + Long-Lived Access Token |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Wake word not detecting | Tap mic button to restart; check Bluetooth audio routing |
| No audio through glasses | Verify Bluetooth connection in iOS Settings |
| Glasses not connecting | Tap "Connect to Glasses"; enable Developer Mode in Meta AI app |
| HomeKit not finding devices | HomeKit initializes on first tool call — say "list smart home devices" and wait 10s |
| Local model crashes | Gemma 4 E2B needs ~8 GB RAM; on 6 GB devices use a smaller model (0.5B–2B) |
| Model download stuck | Keep app in foreground; downloads continue if briefly backgrounded |
| "Untrusted Developer" | Settings → General → VPN & Device Management → Verify (requires internet) |

---

## Dependencies

| Package | Purpose |
|---------|---------|
| [meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios) | Glasses connection + camera |
| [HaishinKit](https://github.com/shogo4405/HaishinKit.swift) | RTMP broadcasting |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | On-device LLM inference |
| [WebRTC](https://github.com/stasel/WebRTC) | Peer-to-peer browser streaming + expert video |
| [SystemNotification](https://github.com/danielsaidi/SystemNotification) | In-app notification banners |

---

## Contributing

Contributions welcome! This is fully open-source. Fork, improve, submit PRs.

Key areas for contribution:
- New native tools
- Local model optimization
- Translation quality improvements
- Additional MCP server integrations
- UI/UX improvements

## License

Business Source License 1.1 — free for non-commercial use. Commercial use requires a separate license from Skunk0 / Skunkworks NZ. Converts to Apache 2.0 on March 24, 2030. See LICENSE file for details.

## Credits

Built by [Skunk0](https://github.com/straff2002) at Skunkworks NZ

Powered by [Anthropic Claude](https://www.anthropic.com/), [Meta Wearables SDK](https://wearables.developer.meta.com/), [Apple MLX](https://github.com/ml-explore/mlx-swift), [ElevenLabs](https://elevenlabs.io/), [HaishinKit](https://github.com/shogo4405/HaishinKit.swift)

---

**Note**: Independent open-source project, not affiliated with Meta or Anthropic.
