# OpenGlasses

[中文文档 (Chinese)](README.zh-CN.md)

A source-available voice-powered AI assistant for Meta smart glasses — Ray-Ban Meta, Ray-Ban Display, Oakley Meta (HSTN / Vanguard), and Meta's own frames — with the EVEN Realities G2 supported as an alternate in-lens HUD. 85+ built-in tools, multi-LLM support (cloud + on-device) with automatic model routing, a **fully offline voice mode** (on-device speech-to-text, AI, and voice), personas with simultaneous wake words, an in-lens HUD with hands-free task control on Ray-Ban Display glasses, an on-device knowledge graph, live translation, hands-free field-service guidance, real-time vision coaching, MCP tool servers, and CarPlay + Apple Watch companions — all controlled hands-free by voice.

> **Note**: The Meta Wearables SDK is currently in **developer preview**. App Store distribution is pending approval — each user must build the app from source with their own Meta developer credentials.

<!-- TODO(gallery): "## See It" section goes here — captioned rows of device screenshots in docs/media/
     (voice tab, Settings hub, Developer panel, modes; then lens HUD photo/GIF, live translation,
     walking navigation banner). Capture on a device with glasses connected — no error banners. -->


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
4. Pair your Ray-Ban or Oakley Meta glasses via the Meta AI app
5. Say **"OpenGlasses"** and ask anything

---

## Features

At a glance — every item links to its section below:

| | |
|---|---|
| **Talk** | [Personas](#personas--multiple-ai-personalities) · [Hey Siri](#hey-siri--ask-by-voice-without-the-wake-word) · [Fully Offline Voice](#fully-offline-voice-mode) · [Text-to-Speech](#text-to-speech) · [Realtime Modes](#realtime-modes) · [Barge-In](#barge-in) |
| **Think** | [85+ Native Tools](#85-native-tools) · [On-Device LLM](#on-device-local-llm) · [Self-Hosted Server](#self-hosted-local-server-ollama-llamacpp-vllm) · [Smart Routing](#smart-model-routing) · [Prompt Presets](#prompt-presets) · [Custom Tools](#custom-tools) · [MCP Servers](#mcp-servers-model-context-protocol) · [Voice-Taught Skills](#voice-taught-skills) |
| **See** | [Live Coach](#live-coach--real-time-vision-coaching) · [Smart Capture](#smart-capture) · [Object Memory](#object-memory) · [Live Translation](#live-translation) · [Camera & Streaming](#camera--streaming) · [Display HUD](#ray-ban-display-hud) |
| **Remember** | [Social Context](#social-context) · [Knowledge Brain](#on-device-knowledge-brain) · [Meeting Recorder](#meeting-recorder) |
| **Connect** | [Home Assistant](#home-assistant-integration) · [CarPlay & Apple Watch](#carplay--apple-watch) · [Transparency & Privacy](#transparency--privacy) |
| **Work** | [Field Assist](#field-assist--guided-field-service) · [Medical Compliance](#medical-compliance) |

### Personas — Multiple AI Personalities

Each persona has its own wake word, AI model, and personality. All listen simultaneously.

| Say | What Happens |
|-----|-------------|
| "Hey Claude" | Routes to Claude Sonnet with your professional prompt |
| "Hey Jarvis" | Routes to a local on-device model with a concise style |
| "Hey Computer" | Routes to GPT-4o with a technical personality |

**Configure:** Settings → Personas → Add. Pick a wake word, assign a model and prompt preset.

### "Hey Siri" — Ask by Voice Without the Wake Word

OpenGlasses ships App Intents + Siri Shortcuts, so you can drive it straight from Siri — handy when the glasses' own "Hey Meta" is busy, or to start a query hands-free without waiting for the in-app wake word:

| Say | What Happens |
|-----|-------------|
| "Hey Siri, ask **Claude** on OpenGlasses what's on my calendar" | Runs the question under that **persona's** model + prompt, **Siri reads the answer back**, then restores your active model |
| "Hey Siri, ask OpenGlasses a question" | Siri asks **"What would you like to ask?"**, you speak the question, it's answered under your active persona |
| "Hey Siri, OpenGlasses take a photo" | Captures via the glasses and describes the scene |
| "Hey Siri, OpenGlasses describe surroundings" | Accessibility scene description |

Beyond the pre-made phrases above, **Capture Glasses Photo** (a silent capture saved to your library) and **Record Glasses Video** are available as **Shortcuts actions** you can add to Siri, the Action button, or your own automations.

The first time, iOS surfaces these in the **Shortcuts** app and the Siri phrase picker (you can rename the phrase to anything you like). A **persona name** can ride in the phrase ("ask Claude…") because it's a fixed, resolvable choice; the **question** can't (iOS only lets App Shortcut phrases embed fixed choices, not free-form text), so it's asked **two-step** — Siri prompts and awaits your spoken reply. Consecutive asks within a few minutes continue the **same conversation thread**, and Siri shows the answer in a result card. The intent runs in the background and speaks the result — no need to bring the app forward. If Siri ever says OpenGlasses isn't running, enable **Settings → Voice → Open App for Siri Questions** to have it launch the app first.

#### Choose What Siri Can Run — and Add Your Own Actions

**Settings → Siri & Search** is the control panel for the whole Siri surface:

- **Built-in actions** — photo, recording, live modes, listening, **daily briefing**, **memory rewind** ("what did they just say?"), **teleprompter**, **meeting summary**, **save this location**, **broadcast** — each individually toggleable. Anything you turn off, Siri politely refuses.
- **Your capabilities** — capture flows, procedures, playbooks, and custom tools you've authored appear automatically as candidates (off by default). Turn one on and **"Run *pump inspection* on OpenGlasses"** works by voice — no extra setup.
- **Custom actions** — invent your own: a spoken name (plus synonyms) bound to a canned instruction for the assistant or a single tool call. "Run *morning rundown* on OpenGlasses."

#### Your Content in Spotlight

Notes, meeting summaries, saved locations, teleprompter scripts, playbooks, and study decks appear in **Spotlight and Siri search** — "the compressor job from Tuesday" finds the field session, and opening a result deep-links into the app. Privacy-tiered: **conversations** (titles only) and **Field Assist sessions** (metadata only, opted in per vault) are off until you enable them; health data, recognized people, and audio are **never indexed**; Medical Compliance Mode disables all donation and purges the index.

#### Pre-Trained Siri Phrasing (App Schemas)

OpenGlasses adopts Apple's **camera** and **assistant** App Intent schemas, so Apple-trained phrasing works with no custom shortcut: "take a photo", "start recording a video". Siri can also resolve **"this"** against the open chat thread — "summarize this" just works.

The assistant schema additionally registers OpenGlasses for the **side-button voice-assistant slot** (replace Siri with OpenGlasses) — currently a **Japan-only** surface (iOS 26.2+, Apple Account region set to Japan, required by Japan's Mobile Software Competition Act; expected to reach more regions as regulation spreads). Everywhere else, the Action button route via **Settings → Action Button → Shortcut → "Ask OpenGlasses"** works today.

### On-Device Local LLM

Run AI models entirely on your iPhone — no internet, no cloud, no API keys.

1. Settings → AI Models → Add Model → pick **"Local (On-Device)"**
2. **Download & Manage Models** → download from HuggingFace
3. Select your downloaded model and tap **Add**

**Recommended models:**

| Model | Size | Best For |
|-------|------|----------|
| **Gemma 4 E2B** (default agent) | 3.6 GB | Best on-device agent — vision, tool calling, 140+ languages (8 GB RAM minimum, 12 GB recommended — uses ~4 GB while running) |
| SmolVLM2 2.2B | 1.5 GB | Vision — sees photos + video |
| Qwen 2.5 3B | 1.8 GB | Strong text reasoning + tool use |
| Gemma 2 2B | 1.5 GB | Lightweight general purpose |
| Qwen 2.5 0.5B | 0.4 GB | Ultra-light, basic |

**Gemma 4 E2B** is the default on-device agent — it runs automatically when no cloud model is configured. Models are stored persistently and work fully offline after download. Toggle **Offline Mode** in Settings → Tools to disable internet-dependent tools.

**Memory:** a loaded model occupies its full weight size in RAM plus working memory while generating — Gemma 4 E2B uses ~4 GB, a real load even on a 12 GB iPhone with other apps open. OpenGlasses checks available headroom before loading: if the model won't fit it tells you how much to free (swipe apps away in the app switcher) instead of letting iOS silently kill the app, and voice requests automatically fall over to a cloud model if one is configured. **Settings → AI Models → Download & Manage Models** shows the app's live memory use and remaining headroom.

### Self-Hosted Local Server (Ollama, llama.cpp, vLLM…)

Prefer to run a bigger model on a desktop or home server and keep everything on your own network? Point OpenGlasses at any **OpenAI-compatible** endpoint — no cloud, no API key:

1. Settings → AI Models → Add Model → pick **"Custom (OpenAI-compatible)"**
2. Set the **Base URL** to your server, e.g. `http://your-mac.local:11434/v1` (Ollama), and **leave the API Key blank**
3. Tap **Fetch models** to list what the server has, or type a model ID (e.g. `llava` for vision). Turn on **Vision** to send glasses photos.

Works with **Ollama, llama.cpp server, LM Studio, vLLM, and LocalAI**. Your photos, voice, and conversations never leave the machine running the server.

> **Reaching the server:** use the host's **`.local` mDNS name** (`http://mymac.local:11434/v1`) or a **Tailscale** address (`*.ts.net`, already allow-listed) rather than a raw `192.168.x.x` IP — iOS App Transport Security can block cleartext `http://` to a bare private IP, but allows `.local`, loopback, and the Tailscale exception.

### Fully Offline Voice Mode

Run the **entire voice loop on-device** — nothing leaves your iPhone:

- **Speech-to-text** — an on-device SenseVoice recognizer (multilingual, ~240 MB). No audio is sent to any server.
- **The AI** — a local LLM (Gemma / Qwen via MLX, or Apple Intelligence).
- **Text-to-speech** — an on-device Kokoro neural voice (~185 MB) — natural, far better than the robotic system voice.

Speech recognition and the spoken voice are CPU/ONNX (not Metal), so they keep working **even while the app is backgrounded**. Choose the engines under **Settings → Services → Speech Recognition / Voice Engine** and download the models once — then you have a private assistant that works on a plane, in a tunnel, or anywhere with no signal. Each tier also degrades gracefully: with no model (or no cloud), it falls back to Apple Speech and the iOS voice.

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

**No telemetry — ours or the SDK's.** OpenGlasses has no developer backend and no account, so no usage analytics and no crash reports ever reach us — in any build. The glasses SDK collects its own (connection sessions, camera streams, permission checks, crashes) and uploads them to Meta by default; the app opts out in its `Info.plist` *and* blocks those uploads from leaving the phone, because an opt-out is only a request to a closed-source binary. Settings shows whether anything had to be blocked, and the self-test in Diagnostics & Support shows how much. Pairing still contacts Meta once to verify the app may talk to your glasses — that's what makes the connection work, and it carries no usage data.

The agentic path is hardened against **prompt injection** — untrusted content (web pages, scanned text, tool output) can't hijack the assistant into running sensitive tools. High-impact actions stay behind explicit confirmation and the agent-mode gate.

### Camera & Streaming

- **Voice-Activated Photo Capture** — "take a picture" or "what's this?"
- **QR/Barcode Scanner** — "scan this code" (Vision framework, works offline)
- **Live Camera Preview** — real-time view of glasses POV
- **Video Recording** — MP4 with configurable bitrate, glasses-mic audio muxed in, optional live transcription. **No recording time limit** — say "record a video" and it runs until you say "stop recording" (built for meetings and long sessions; the practical limits are glasses battery/thermals and phone storage, not the app). If storage is low it warns with the estimated minutes left, and if the glasses stop mid-recording (battery, thermal shutdown, out of range) it automatically stops, saves everything captured, and tells you.
- **RTMP Broadcasting** — live stream to YouTube, Twitch, Kick
- **Chat Read-Aloud** — while broadcasting, Twitch chat is spoken into your ear (read-only, no OAuth): rate-capped and de-duplicated, mentions jump the queue, assistant speech always wins, and it goes quiet during realtime sessions. Opt-in, with a mentions-only mode
- **WebRTC Browser Streaming** — shareable URL for peer-to-peer viewing
- **Privacy Filter** — auto-blurs bystander faces before a frame leaves the device: AI providers, recordings, RTMP broadcast, browser streaming and expert calls all get the blurred frame from one shared pass. Detection and blurring are on-device. On video the blur tracks faces between detections, so someone stepping into shot can be briefly visible before the next pass; faces you've enrolled are matched unblurred so recognition still works

### Meeting Recorder

One tap on the **Record button** in the quick actions bar (or by voice) captures a meeting through the glasses mic — with live captions on screen while it records, even if wake-word listening is off. Recordings are **preserved** in an in-app library with playback, and each one gets a transcript automatically: speaker-labeled cloud transcription when Deepgram is configured, with the downloaded on-device model as the private/offline fallback. Medical Compliance Mode keeps transcription fully on-device.

### Ray-Ban Display HUD

On **Ray-Ban Display** glasses (the Meta frames with an in-lens display + Neural Band), OpenGlasses mirrors content into the heads-up display and lets you act on it hands-free. Additive and off by default (Settings → Hardware → Glasses Display). It's gated on the device's display capability — not the brand — so camera/audio frames like Ray-Ban Meta and Oakley Meta are simply unaffected. The same HUD can instead render on an **EVEN Realities G2** (Settings → Hardware → Display Backend): display + temple-gesture control only, over open Bluetooth with no Meta permission gate — voice stays on the phone, and there's no camera.

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
- **Apple Watch** — companion app and widget for quick control and glanceable status, including **taking a photo or starting/stopping a video recording on the glasses** straight from your wrist.

---

## Enterprise

Commercial features for teams and regulated industries. These are licensed separately from the source-available core — see [License](#license) or contact Skunkworks NZ at [g@skunkworks.kiwi](mailto:g@skunkworks.kiwi).

### Field Assist — Guided Field Service

Hands-free, step-by-step guidance for technicians and other hands-busy work. Procedures branch on what you report or what the camera sees, surface safety reminders before each step, cite their source material, and write an audited session log you can export. Stuck? Escalate to a live remote expert with glasses video. Domain knowledge lives in **vaults** (e.g. refrigeration, HVAC, electrical) you author and extend yourself.

| Say | What Happens |
|-----|-------------|
| "Start a refrigeration session" | Loads the vault and begins the procedure |
| "The gauge reads 38 psi" | AI evaluates the reading and branches to the right next step |
| "Next step" / "Go back" / "Repeat that" | Navigate the procedure hands-free |
| "Call an expert" | Bridges to a remote human with live glasses video |

**Access:** Field Assist unlocks with a signed license code (teams — issued with your purchase order) or a one-time in-app purchase. TestFlight builds unlock through the StoreKit sandbox at no charge, so beta testers don't need a code. Want to evaluate it? [Email us](mailto:g@skunkworks.kiwi?subject=Field%20Assist%20trial%20license) for a temporary trial license.

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
- **Meta smart glasses** — Ray-Ban Meta, Ray-Ban Display, Oakley Meta HSTN / Vanguard, and Meta's own frames (paired via the Meta AI app); full functionality on all, in-lens HUD on display-equipped models such as **Ray-Ban Display**
- **EVEN Realities G2** (optional, no Meta account needed) — alternate **HUD backend only**: cards, captions, navigation, and hands-free task control render on the G2; voice stays on the phone/earbuds and camera features are unavailable (the G2 has no camera). Can run alongside Meta glasses — Meta camera + G2 HUD works
- At least one LLM: API key (Anthropic, OpenAI, Gemini, etc.) OR a downloaded local model

---

## Building from Source

Meta developer credentials, Universal Links, personal signing, in-app configuration
(API keys + services), and troubleshooting all live in **[docs/BUILDING.md](docs/BUILDING.md)**.

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

Contributions welcome! This is source-available under the Business Source License 1.1 (free for non-commercial use; converts to Apache 2.0 in 2030). Fork, improve, submit PRs.

Key areas for contribution:
- New native tools
- Local model optimization
- Translation quality improvements
- Additional MCP server integrations
- UI/UX improvements

## License

Business Source License 1.1 — free for non-commercial use. Commercial use requires a separate license from Skunk0 / Skunkworks NZ — contact [g@skunkworks.kiwi](mailto:g@skunkworks.kiwi). Converts to Apache 2.0 on March 24, 2030. See LICENSE file for details.

## Credits

Built by [Skunk0](https://github.com/straff2002) at Skunkworks NZ

Powered by [Anthropic Claude](https://www.anthropic.com/), [Meta Wearables SDK](https://wearables.developer.meta.com/), [Apple MLX](https://github.com/ml-explore/mlx-swift), [ElevenLabs](https://elevenlabs.io/), [HaishinKit](https://github.com/shogo4405/HaishinKit.swift)

---

**Note**: Independent source-available project, not affiliated with Meta or Anthropic.
