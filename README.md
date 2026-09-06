# OpenGlasses

### Look up. Ask anything. Keep going.

Turn your smart glasses into an AI assistant for the world in front of you. Ask about what you see, translate a conversation, remember the details, and get things done—without reaching for your phone.

**Your choice of AI. Hands-free by voice. Offline when you need it.**

[Get started](#quick-start) · [Explore capabilities](docs/CAPABILITIES.md) · [For teams](#expertise-where-the-work-happens) · [简体中文](README.zh-CN.md)

---

## A little help, right when you need it

### See it. Understand it. Act on it.

Read a sign, ask about a piece of equipment, or turn a business card into a contact. OpenGlasses brings the camera into the conversation, with scene descriptions, text recognition, smart capture, and live visual coaching.

*“What am I looking at?” · “Save this card.” · “Log this receipt.”*

[Explore vision and capture →](docs/CAPABILITIES.md#see-and-capture)

### Keep the conversation flowing

Ask a quick question or settle into a live voice conversation. Translate spoken language, follow along with captions, and switch between assistants with their own voices, models, and wake words. Start with your voice, Siri, or a tap.

*“Start translating Spanish to English.” · “Hey Jarvis…”*

[Explore voice and translation →](docs/CAPABILITIES.md#talk-and-translate)

### Remember the details that matter

Save where you parked, keep notes about people and places, and turn captured conversations into meeting notes. With memory rewind enabled, catch up on what was just said. Your saved context becomes something you can ask about later.

*“Remember my car is in lot B, level 3.” · “What did they just say?”*

[Explore memory and recall →](docs/CAPABILITIES.md#remember-and-recall)

### Say it. Get it done.

Check your calendar, set a reminder, find directions, control your music, or turn on the lights. Connect Home Assistant, Siri Shortcuts, MCP tool servers, and OpenClaw to bring your own services into the conversation. Teach the assistant a routine, then call it by name.

*“What's on my calendar?” · “Turn on the living room lights.”*

[Explore actions and integrations →](docs/CAPABILITIES.md#take-action)

### Share your point of view

Capture photos and video by voice, broadcast over RTMP, or share a live view in a browser over WebRTC. Compatible display glasses can put answers, captions, and the next task in your line of sight.

[Explore capture →](docs/CAPABILITIES.md#see-and-capture) · [Check display support →](docs/CAPABILITIES.md#devices-and-displays)

## Your assistant. Your choice.

Use a cloud model, run a model on your own server, or keep the voice loop on your iPhone. OpenGlasses lets you choose the AI, speech recognition, and spoken voice separately—and route different requests to different models.

### Offline AI, right on your iPhone

Take your assistant beyond Wi-Fi and mobile coverage. Run compatible local models with **Apple MLX** or **llama.cpp**, including support for importing **GGUF** models. Pair them with **SenseVoice** speech recognition and **Kokoro** voices for an on-device voice conversation—no cloud API key required.

Download the models once, select the local engines, and enable Offline Mode for tools. Model fit and performance depend on your iPhone; vision and tool calling depend on the selected model. Connected services still need a network.

You also control which tools are enabled, inspect the context sent to the assistant, and review network activity.

[Choose your AI →](docs/CAPABILITIES.md#choose-your-ai) · [Privacy controls →](docs/CAPABILITIES.md#privacy-and-control)

## Expertise where the work happens

**Field Assist** puts procedures and reference knowledge within speaking distance. Follow guided steps, report a reading, look up a fault, and bring in a remote expert when the job needs another pair of eyes.

Teams can add their own manuals and knowledge vaults for answers with source references and exportable session records. Clinical recording features add biometric access, retention controls, audit records, and medical export options.

These features have separate access tiers. [Explore professional capabilities](docs/CAPABILITIES.md#field-and-clinical-work), [build a field knowledge vault](docs/field-assist-vault-guide.md), or [contact Skunkworks NZ](mailto:g@skunkworks.kiwi) about team access.

## Quick Start

Start on an **iPhone running iOS 26+**. Pair compatible **Meta smart glasses** for hands-free camera and audio use; phone-based features and camera fallback also let you explore without glasses.

1. **Build the app.** Follow the [source setup guide](docs/BUILDING.md) for Xcode 26+, dependencies, signing, and Meta developer configuration.
2. **Choose your AI.** Open **Settings → AI Models** and connect a provider or download a compatible local model.
3. **Connect your glasses.** Pair them in the Meta AI app, complete developer setup, then connect and grant camera access in OpenGlasses.
4. **Start talking.** Enable listening and say **“OpenGlasses”**, or tap the microphone. Try asking about something in front of you.

Camera and display features depend on the device and SDK support. Ray-Ban Display has an in-lens display path; **EVEN G2 support is experimental**. See [device notes](docs/CAPABILITIES.md#devices-and-displays) before choosing a setup.

## Go further

| Make it yours | Start here |
|---|---|
| Explore features, examples, and configuration | [Capability guide](docs/CAPABILITIES.md) |
| Build, configure, or troubleshoot the app | [Building from source](docs/BUILDING.md) |
| Bring your own field manuals and procedures | [Field Assist vault guide](docs/field-assist-vault-guide.md) |
| Create reusable assistant capabilities | [Skill pack authoring](docs/skillpack-authoring.md) |
| Publish packs | [Skill packs](skillpacks/README.md) · [Vault packs](vaultpacks/README.md) |
| Explore engineering work and future plans | [Development plans](docs/plans/README.md) |

## Build with us

Contributions are welcome—from new tools and integrations to better local inference, translations, and everyday usability. Fork the project and open a pull request.

OpenGlasses is **source-available under [BSL 1.1](LICENSE)**, with non-commercial use permitted and a stated change date of March 24, 2030 to Apache 2.0. Commercial use requires a separate licence: [g@skunkworks.kiwi](mailto:g@skunkworks.kiwi).

Built by [Skunk0](https://github.com/straff2002) at **Skunkworks NZ**. Independent of Meta and Anthropic.
