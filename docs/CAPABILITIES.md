# OpenGlasses capability guide

Practical examples, setup notes, and device requirements for the capabilities introduced in the [English README](../README.md) and [中文 README](../README.zh-CN.md).

[Talk](#talk-and-translate) · [See](#see-and-capture) · [Accessibility](#accessibility) · [Remember](#remember-and-recall) · [Act](#take-action) · [Work](#field-and-clinical-work) · [AI choices](#choose-your-ai) · [Devices](#devices-and-displays) · [Privacy](#privacy-and-control)

## Talk and translate

Use the microphone button, an enabled wake word, or Siri to start a request. Standard voice mode combines speech recognition, your selected AI model, and text-to-speech. Gemini Live and OpenAI Realtime provide separate live conversation modes with their respective provider configuration.

### Make the assistant your own

In **Settings → Personas**, give an assistant its own wake word, model, and prompt preset. For example, set up “Hey Jarvis” for short answers from a local model and “Hey Claude” for a cloud assistant. Wake words can listen together; saying an enabled wake word can also interrupt a spoken answer.

Prompt presets adjust the response style. Model routing can assign requests to your configured Fast, Balanced, or Best tier, or you can keep one model selected.

### Siri and shortcuts

Try “Hey Siri, ask OpenGlasses a question.” Siri prompts for the question, then returns the answer. Configure built-in actions and opt your own capabilities into **Settings → Siri & Search**. Photo and video actions are also available in Shortcuts, including for the Action button.

If Siri reports that the app is not running, enable **Settings → Voice → Open App for Siri Questions**. Available Siri phrasing depends on iOS and your language settings.

### Translation and captions

Try “Start translating Spanish to English,” then “Stop translating” when finished. Ambient captions provide a running transcript; compatible displays can show captions in the lens. Language coverage and offline availability depend on the selected speech and translation engines and downloaded language assets.

## See and capture

Camera-assisted questions use a captured image or a stream frame. A vision-capable AI model is needed to interpret scenes; text and barcode recognition also have on-device paths.

| Try saying | What it does |
|---|---|
| “What am I looking at?” | Ask the assistant about the camera view |
| “Save this card” | Extract contact details; native contact creation is not yet implemented |
| “Log this receipt” | Extract the merchant, total, and date for an expense note |
| “Add this event” | Read an event flyer and offer a calendar action |
| “Scan this code” | Recognize a QR code or barcode |
| “Coach my posture” | Start periodic spoken visual feedback |

Smart capture performs OCR on the phone, then passes extracted fields to the assistant. Note and calendar writes use separate tools and permissions; the current contacts tool only looks up existing contacts. Receipt extraction is not a dedicated structured expense store. Local OCR does not make the rest of a cloud-model conversation local.

The automatic “handle this” recommendation, review, confirmation and undo experience—including contact creation and structured expense/tracking records—is [planned in FH](plans/FH-handle-this-visual-actions.md). QR recognition exists today; the unified no-fetch preview-and-confirm flow is also planned.

Live coaching can also use cooking, guitar, climbing, sports, or a custom topic. Say “Stop coaching” to end it. The quality of visual responses depends on the view, lighting, and selected model.

### Photos, recording, and sharing

- Capture photos and record video with voice controls or app controls.
- Keep audio recordings in the recording library for playback and transcription.
- Configure an RTMP destination and stream key for broadcasting.
- Share video to a browser over WebRTC; remote expert sessions use the configured expert transport.
- Optionally read Twitch chat aloud during a broadcast, with rate and mentions-only settings.

Streaming destinations and remote expert connections need their own network configuration. [Build and service setup](BUILDING.md) covers the app settings; the repository includes a [WebRTC signaling server](webrtc/signaling-server.js) and [expert browser client](webrtc/expert-client.html).

## Accessibility

Reading Assistant and Blind Assistant are selectable live presets. Reading tools can extract text
from signs, menus and documents; visual descriptions require a capable model and usable camera view.
Try “Read this label” or “What does this sign say?” VoiceOver semantics, spoken feedback, Siri and
Action Button shortcuts are implemented, with availability depending on the selected mode and setup.

Accessibility features have no separate paid unlock. Cloud provider usage may cost money; professional
Field Assist and clinical features have their own access tiers. Accessibility access does not change
the project's commercial licence terms.

The complete setup, correction and recovery journey still needs blind-participant and hardware
validation. Automated UI checks do not establish independent everyday usability. Descriptions can
be incomplete or incorrect and are supplementary to existing mobility aids, not clearance to move
or cross a road.

Offline operation requires compatible downloaded AI, speech and voice assets. Automatic takeover
from a failed cloud visual session is not established; phone lock/background restrictions also
limit local inference. Test the intended setup before relying on it. See [setup and first use](BUILDING.md#availability-and-first-use)
and [the readiness plan](plans/FF-blind-assistant-readiness.md) for the remaining work.

## Remember and recall

OpenGlasses combines explicit notes, saved locations, conversation records, and an on-device knowledge graph so you can return to useful context later.

| Try saying | What it uses |
|---|---|
| “Remember my car is in lot B, level 3” | An object-memory entry, with location when permitted |
| “Where did I park?” | Your previously saved location |
| “Remember Sarah likes hiking” | A saved fact about a person |
| “What do I know about Sarah?” | Facts you have recorded |
| “Summarize the meeting” | Available ambient-caption history |
| “What did they just say?” | Recent audio, when memory rewind is enabled |

**Enable capture before you need recall.** Memory rewind uses an opt-in rolling audio buffer; it cannot recover speech from before buffering started. Meeting summaries need a captured transcript—start ambient captions before the conversation. Audio recording is a separate capture path with its own library.

Local storage and local search do not determine where an AI answer is generated. If you choose a cloud assistant, retrieved context may be included in its request. Choose local engines when you want processing to stay on the phone.

## Take action

The assistant can call enabled tools as part of a conversation. Services and permissions determine which actions are available.

| Use case | Examples |
|---|---|
| Plan your day | Calendar, reminders, timers, notes, daily briefing |
| Find your way | Directions, nearby places, saved locations |
| Stay connected | Contact lookup, calls, message and email workflows |
| Control your environment | Music, HomeKit, Home Assistant |
| Find information | Web search, weather, news, calculations, unit conversion |
| Extend the assistant | Siri Shortcuts, custom tools, MCP servers, OpenClaw |

### Connect your services

**Home Assistant:** add your instance URL and a long-lived access token in its service settings. Ask to list devices or control a configured entity.

**MCP:** add a compatible remote server URL and authentication in MCP settings, then discover its tools. Availability depends on the server's transport and authentication requirements.

**Custom tools:** map a named tool to a Siri Shortcut or a URL with parameter substitution. Voice-taught skills can save instructions for familiar phrases. Execution still depends on the underlying tools and permissions.

**Skill packs:** package reusable prompts, tools, and workflows. Start with [skill pack authoring](skillpack-authoring.md); maintainers can use the [catalog publishing guide](../skillpacks/README.md).

Review enabled tools and action confirmations in the app. Some communication actions open another app or a compose screen to complete the task.

Connections expose only the operations supported and authorised by that service. Broader enterprise
sign-in and independently usable connected business workflows are [planned in FG](plans/FG-workflow-vaults-and-enterprise-auth.md);
adding an MCP server does not automatically provide access to every feature of a business application.

## Field and clinical work

### Field Assist

Field Assist combines domain knowledge, guided procedures, session records, and remote expert escalation. Procedures can branch on reported readings or visual findings and provide source references alongside guidance.

Try “Start a refrigeration session,” report a reading, then use “Next step,” “Go back,” or “Repeat that.” Expert escalation requires an available expert and a configured connection.

| Access tier | Capability |
|---|---|
| Solo | Bundled vaults, guided procedures, domain calculators, session log, expert escalation |
| Team | Solo capabilities plus custom vaults and manuals, and audited export |
| Enterprise | Team capabilities with separately agreed commercial terms |

Use **Settings → Field Assist** to review access and activate a signed licence. Purchase and trial availability depend on the build and distribution channel. Contact [Skunkworks NZ](mailto:g@skunkworks.kiwi) for team or evaluation access.

For your own reference material, follow the [Field Assist vault guide](field-assist-vault-guide.md). It covers PDF, scanned manuals, EPUB, Markdown, and plain text, including source-page references. The [vault pack guide](../vaultpacks/README.md) covers packaging and publishing.

### Clinical recording controls

The Medical Compliance feature has separate subscription access and provides protected recordings and transcripts, biometric access controls, audit records, retention settings, and FHIR, HL7, and PDF export options.

Its **Local LLM Only** setting enforces local model selection when Medical Compliance Mode is active. If no usable local model is available, the request is refused instead of sent to a cloud model. Configure export destinations and retention to match the intended workflow; these are application controls, not a claim of regulatory certification.

## Choose your AI

Choose models under **Settings → AI Models**. Speech recognition and spoken voice have separate service settings.

| Run the AI | Setup | Considerations |
|---|---|---|
| Cloud provider | Add provider credentials and select a model | Network access; provider terms and usage charges apply |
| On your iPhone | Download or import a compatible local model | No cloud API key; model size, memory, and capability must fit the device |
| On your server | Add a Custom (OpenAI-compatible) endpoint | Your iPhone must reach the server; speech services are configured separately |

Local inference includes MLX and a llama.cpp path for compatible GGUF models. Use the model manager to check downloads and memory fit. Vision and tool calling depend on the model; not every local model supports both.

### Set up offline voice

1. Download a compatible local AI model and select it.
2. Select the on-device speech recognizer and download its SenseVoice assets.
3. Select a local voice engine, such as Kokoro with downloaded assets or the system voice.
4. Enable **Offline Mode** in tool settings to disable internet-dependent tools.
5. Try a voice request with the network disconnected before relying on the setup away from coverage.

Offline Mode is a tool control, not a replacement for selecting local AI and speech engines. Cloud live modes, web search, and remote integrations need a connection. Background availability varies by engine and iOS session state.

### Connect your own model server

Select **Custom (OpenAI-compatible)** and enter the server's base URL, such as `http://your-mac.local:11434/v1`. Fetch the available models or enter an ID. Supply authentication if your server requires it, and enable vision only for a model that supports images.

Use a reachable HTTPS endpoint or an allowed local hostname; iOS transport restrictions can block cleartext private-IP URLs. The model request goes to your server, while separately configured cloud speech or tools can still contact their providers.

## Devices and displays

The app targets **iOS 26+**; source builds require **Xcode 26+**. See [Building from Source](BUILDING.md) for dependency installation, personal signing, and Meta credentials.

| Device or surface | Role and limits |
|---|---|
| iPhone | Runs the app and models; provides microphone and camera fallback for phone-based use |
| Compatible Meta glasses | Hands-free audio and camera through the Meta integration; pair with Meta AI and complete registration and permissions |
| Ray-Ban Display | In-lens answers, captions, cards, and task controls on display-capable hardware |
| EVEN Realities G2 | Experimental alternate display backend; hardware protocol validation is incomplete |
| Apple Watch | Companion controls and status, including photo and video controls |
| CarPlay | Voice-assistant interface on the vehicle display |

**Meta display session limitation:** the current display backend owns a device session separately from the camera. While that display session is held, the camera may need the iPhone fallback. Do not assume simultaneous glasses-camera and HUD access.

**EVEN G2 status:** rendering and transport code exist, but the render service identifier is a placeholder awaiting validation and temple-gesture decoding is not implemented. Treat it as development support. It is a display backend, not a camera or audio replacement.

Camera availability depends on SDK and glasses firmware compatibility, registration, permissions, and session state. The [troubleshooting guide](BUILDING.md#troubleshooting) covers common connection and camera failures.

## Privacy and control

- **Tool switches:** choose which capabilities the assistant can use.
- **Prompt inspection:** review the system prompt and supplied context.
- **Network activity:** inspect recorded requests and their categories.
- **Offline configuration:** choose local engines and disable network-dependent tools.
- **Capture controls:** explicitly enable recording, captions, or memory rewind for their respective features.

The app includes Meta SDK telemetry opt-out configuration and a telemetry-blocking layer. That does not eliminate the connections needed for Meta registration or services you choose to use.

Cloud models, cloud speech, remote tools, and broadcasts each have their own data path. Review the selected services as well as where notes and recordings are stored.

Use this checklist when choosing a setup:

| Component | What to check |
|---|---|
| Camera/text | Whether captured images or extracted text are sent to the chosen model; local OCR alone does not keep subsequent requests local |
| Speech recognition | Which recognizer receives microphone audio and whether its language assets work offline |
| AI responses | The selected cloud provider, your server or a compatible model on the iPhone |
| Spoken voice | Whether synthesis uses downloaded/system voices or a remote service |
| Tools and sharing | Destinations for search, connected services, broadcasts and exports |

Network Activity shows observed requests; some SDK-internal traffic may not appear, so an empty
list does not prove that no data left the device. A guided in-app processing/readiness summary is
[planned under FF](plans/FF-blind-assistant-readiness.md). Choosing another AI does not remove Meta
registration or companion-app requirements. Provider credentials and subscription support depend
on the selected connection; do not assume a personal chat subscription supplies an API key.
