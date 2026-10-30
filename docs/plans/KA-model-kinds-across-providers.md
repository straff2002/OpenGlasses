# Plan KA — Model Kinds and Roles Across Providers (what a listed model is for, and which job uses it)

**Status:** 🚧 P1 built 2026-10-30 — roles. `ModelRoleCatalog` (pure, tested headless) decides which
roles a saved key offers (its provider's transports, less any its loaded list shows it can't do),
each role's candidates across every saved key plus the on-phone options (Kokoro and the iOS voice,
the on-device and Apple recognisers), each provider's default per role (the cheaper OpenAI live
model from a suggestion, decision 6), and the limits: under Medical local-only nothing that leaves
the phone is listed and a role left with nothing is off (Live always; Vision without an on-phone
model that sees); HIPAA keeps dictation on the phone; an organisation's cloud-dictation pin removes
the cloud recognisers, and a whole-role pin is read-only. Settings › AI & Personality has a Roles
section under AI Models with the Assistant, Vision, Voice, Live and Dictation pickers. The roles are
the existing settings (active model, `ttsEnginePreference`, `activeRealtimeModelID`,
`asrEnginePreference` with the cloud-dictation switch); the one new value is
`Config.visionRoleModelId` (the dead `localTextModelId`/`localVisionModelId` keys are gone). The
Voice & Triggers screen's voice-engine and recogniser pickers now open the role pickers. A photo
turn tries the Vision model first, then today's order; with none set the order is exactly today's;
the Vision picker lists only models that take images, and the ChatGPT subscription never does. The
Vision model answers the photo turn itself (decision 5 default). The "this key can also…" card shows
when a key is added in Settings and once in onboarding, after the key step: one tap per role and
"Use all", each naming where the data goes and whose quota it spends (decision 4 default); nothing
is switched on until tapped, and a role already set isn't offered. Plan JZ's Gemini speech-model
picker reads the classifier's `.speech` (its URL-safety check stays). Roles reuse routes already
registered and disclosed, so no privacy copy changed. Owed: P2 (live lists with real keys, and on
the device each role's default per provider and one photo turn through a chosen Vision model); a
catalog sync for the new strings; Images later (Design 12). Under Auto, a saved Gemini key already
turns the Gemini voice on (Plan JZ's order) — the card offers Voice only when it isn't chosen
explicitly; whether Auto should stop doing that is an owner call.
**P0:** 🚧 built 2026-10-29 — `ModelKindClassifier` labels every provider's list, each chat
picker shows a "Can't be your assistant" section, a typed non-chat id gets a warning (not a
refusal: the classifier can't know every server's names), and a saved one is flagged in Settings.
The xAI and Gemini name lists are the classifier's rows, and PR 887's no-thinking ids
(`GeminiThinkingStyle.takesNoThinking`) are read from the classifier too. Owed: a catalog sync for
the new strings; P1 and P2; device checks. Earlier: Owner decision the same day: chat pickers
**label** non-chat models rather than hide them; PR 885 stays as it is (hiding Gemini's by name)
until P0 replaces it. A second owner decision, also the same day, added **roles** (P1): one key can
cover several jobs (assistant, vision, voice, live, dictation, later images), each with its own
picker, offered in onboarding and in Settings. The owner is also content for the main picker to
hide non-chat models once roles give them a home.
**Origin:** the 2026-10-29 support report on build 581. A speech-only Gemini model was chosen as the
chat assistant, so every turn was refused. PR 885 fixes it for Gemini by name. The owner asked for
one approach across every provider, because the same thing can happen elsewhere, and Plan
[JZ](JZ-gemini-cloud-voice.md)'s speech-model picker needs the opposite filter on the same lists.
**Related:** Plan [JZ](JZ-gemini-cloud-voice.md) (Gemini voice), Plan
[ID](ID-ecosystem-review-hardening-bundle.md) item 5 (OpenAI and xAI voices), PR 885 (the Gemini
chat-picker filter and model-form check).

---

## Why

Each provider's model list is shown in the chat picker as it comes, except in two places:

- xAI drops image, video, voice and embedding ids by name (`XAIOAuth.isChatModel`).
- Gemini drops speech, image and embedding ids by name (PR 885, `ModelFetcher.isGeminiChatModel`).

OpenAI, Groq, Mistral, Z.ai, Qwen, MiniMax, OpenRouter and custom servers are not filtered. An OpenAI
key's list carries speech (`tts-1`, `gpt-4o-mini-tts`), transcription (`whisper-1`,
`gpt-4o-transcribe`), realtime (`gpt-realtime*`), image (`gpt-image-*`), embedding and moderation
models. Any of them can be picked as the assistant, and every turn then fails the way the report's
did. Two hand-kept name lists also drift: each was written for one provider's naming.

## What the providers give us (docs checked 2026-10-29)

| Provider | Kind in the list itself | Non-chat kinds that appear | Speech (TTS) |
|---|---|---|---|
| OpenAI | none (`id`, `owned_by`, `shutdown_date`) | speech, transcription, realtime/audio, image, embedding, moderation | `/v1/audio/speech`; **`tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` removed 2027-01-06**, replacement `gpt-realtime-2.1-mini` |
| Anthropic | feature flags only; chat-only list | none | none |
| Gemini | `supportedGenerationMethods` | speech (`*-tts`), live/native-audio, embedding, image, video, music | `generateContent` / interactions (Plan JZ) |
| Groq | none | transcription (`whisper-*`), speech (`canopylabs/orpheus-*`), guard models | OpenAI-shaped `/audio/speech`; English and Saudi Arabic only, wav, 200-character input |
| DeepSeek | `input_modalities` / `output_modalities` | none | none |
| Mistral | `capabilities` flags (`completion_chat`, `audio_speech`, `audio_transcription`, `ocr`, `moderation`, …) | transcription, speech, OCR, embedding, moderation | `/v1/audio/speech` (Voxtral), voices from `/v1/audio/voices`, base64 in JSON |
| Z.ai | list shape undocumented | transcription, OCR, image, video documented; presence in the list unconfirmed | none documented |
| Qwen | list shape undocumented | speech, transcription, realtime/omni, embedding, rerank, image, video | DashScope's own API, not OpenAI-shaped |
| MiniMax | list shape undocumented | speech (`speech-*`), music, image, video | `/v1/t2a_v2`, not OpenAI-shaped |
| xAI | modalities on `/v1/language-models`; `/v1/models` mixes in image/video | image, video, voice | `/v1/tts` (shipped) |
| OpenRouter | `architecture.output_modalities` (text, image, audio, speech, transcription, embeddings, rerank, video) | every kind, but the list defaults to text output | OpenAI-shaped `/api/v1/audio/speech`; speech models via `?output_modalities=speech` |

Four lists say what a model is for: Mistral, DeepSeek, OpenRouter, and xAI's language-model list.
Gemini's methods come close. For the rest, the id is all there is.

## Design

1. **One pure classifier.** `ModelKind` is one of `chat`, `speech`, `transcription`, `realtime`,
   `image`, `video`, `music`, `embedding`, `rerank`, `moderation`, `ocr` or `other`.
   `ModelKindClassifier.kind(provider:id:metadata:)` reads, in order:
   1. **The list's own field** where there is one: Mistral's `capabilities`, OpenRouter's and
      DeepSeek's `output_modalities`, Gemini's `supportedGenerationMethods`. Anthropic's list is
      chat by construction.
   2. **Shared id words** for the rest. An id is split on `-`, `.`, `_`, `/` and `:`, and whole
      words are matched, never substrings. That keeps `tts` from matching inside another word, and
      `speech` from a chat model's name. Examples: `tts`, `orpheus` → speech; `whisper`,
      `transcribe`, `asr` → transcription; `realtime`, `live`, `native-audio`, `audio-preview` →
      realtime; `image`, `imagen`, `dall-e`, `cogview`, `imagine` → image; `video`, `veo`, `sora`,
      `hailuo` → video; `lyria`, `music` → music; `embed`, `embedding` → embedding; `rerank`;
      `moderation`, `guard`, `safeguard` → moderation; `ocr`.
   3. **A short per-provider table** for families the shared words miss (MiniMax `speech-*`, Qwen
      `qwen3-tts-*`, `wan*`).
2. **Unknown means chat.** A custom server's or a new provider's id that matches nothing is shown
   as an ordinary chat model. The classifier only labels what it recognises as something else; a
   wrong label on the wearer's own model is worse than an odd model offered as chat.
3. **Every chat picker labels, never hides (owner decision, 2026-10-29).** For every provider,
   the chat picker shows chat models as today. Below them, non-chat models sit in a dimmed "Can't
   be your assistant" section, where they can't be selected. Each one carries a label naming where
   it can be used: live voice mode, speech output (a voice), transcription, images, embeddings,
   safety filters. Once Plan JZ's Gemini voice lands, the speech-output label points to the voice
   picker. The xAI and Gemini name lists (`XAIOAuth.isChatModel`, PR 885's
   `ModelFetcher.isGeminiChatModel`) become the classifier's rows, with their tests carried over.
   PR 885 hides Gemini's non-chat models until P0 replaces that with the label.
4. **Every voice picker reads it.** A cloud voice's model picker offers its provider's `.speech`
   models. Plan JZ's Gemini picker is the first. OpenAI's voice can do the same if it keeps a
   speech-endpoint model.
5. **A typed id gets the same warning.** The model form uses the classifier, so a speech or image
   id typed by hand gets the label's warning: what the model is for, and where it can be used.
   PR 885's Gemini check becomes the general rule. No plan letters appear in the wording.
6. **A saved model that can't answer is flagged.** A model already saved as the assistant whose id
   the classifier calls non-chat shows a warning in Settings, with the same label. That reaches a
   wearer who saved one before any filter existed, such as the report's saved `gemini-3.8-flash-tts`.
7. **Pure and fixture-tested.** Each provider gets a list fixture built from its documented
   shape, with invented ids where real ones aren't needed. Each family above gets its expected
   kind, plus one test that unknown ids stay chat.

## Roles (owner decision, 2026-10-29)

The classifier says what a model is; a role says which job in the app uses it. Most providers' keys
now reach models of several kinds, and live speech is becoming the default way people use them, so
one key should be able to serve several jobs without the wearer hunting through settings.

| Role | Kind it takes | Today |
|---|---|---|
| **Assistant** | chat | one model, any provider (unchanged) |
| **Vision** | chat that accepts images | implicit: a photo turn falls to the first vision-capable model in the fallback order |
| **Voice** (spoken replies) | speech | the voice-engine setting (ElevenLabs, OpenAI, xAI, Gemini per Plan JZ) |
| **Live** | realtime | OpenAI Realtime, Gemini Live, Qwen Omni, Qwen Audio, Doubao (`RealtimeProviderCatalog`) |
| **Dictation** | transcription | Deepgram, OpenAI transcription (`ASREnginePreference`) |
| **Images** (later) | image | no cloud image tool exists; Plan AL (on-device) is unbuilt |

8. **A role picker per job.** Settings › Intelligence gets a Roles section under the assistant model,
   with one picker per role. Each picker lists models of the role's kind from every provider with a
   saved key, plus the role's on-device or built-in option where it has one (Kokoro and the iOS
   voice for Voice, the on-device recogniser for Dictation). Each provider has a default model per
   role, the one its docs recommend for that use (e.g. `gemini-3.8-flash-lite-tts` for voice, Gemini's
   `native-audio` model for Live). The default is filled in so choosing a role is one tap. Roles
   that exist as settings today (voice engine, Live provider, dictation engine) become those
   pickers; they don't gain a second copy.
9. **A new key suggests its roles; it never switches them on.** When a key is added, in onboarding or
   in Settings, one short card names what else that key can do: "This Gemini key can also speak
   replies and run Live mode". The card has a tap for each role and a "Use all" button. Nothing is
   switched on silently, because each role spends that key's quota and is a new destination for the
   wearer's data. That follows the house rule that a new egress is off until chosen and disclosed.
   Onboarding shows the card once, after the key step, and keeps it short. A role already set is
   not offered again.
10. **Vision is a choice, not a fallback order.** A text-only assistant gets a chosen model for its
    photo turns. The ChatGPT subscription model is marked text-only here, because image input on
    that backend was never confirmed; a cheap, fast model such as Claude Haiku would then look at
    the photos. A photo turn tries the Vision model first, ahead of the fallback order, and the
    rest of the conversation stays on the assistant. The picker lists only models that accept
    images (`supportsVision`). With no Vision model set, today's fallback order still applies.
    *Handoff:* the Vision model answers the photo turn itself, which is today's mechanism, keeps
    full detail and is the default. Describing the photo for the assistant to answer is a later
    option (decision 5).
11. **Live follows the key.** Live is where providers are heading: OpenAI names a realtime model as
    its speech replacement (Plan [KB](KB-openai-voice-after-speech-models.md)), and Gemini, Qwen
    and xAI have speech-to-speech models. The Live role offers every saved key's realtime models,
    so adding a Gemini key can mean Gemini Live with no other setup.
12. **Images wait for a tool.** OpenAI (`gpt-image-*`), Gemini (`…-image`, Imagen), xAI
    (`grok-imagine-image`) and Qwen all have image models, so the role is only a provider choice.
    The tool itself, with its camera, privacy and cost wording, is its own plan. Until then the
    Images role isn't shown.
13. **What roles never do.** Roles respect Medical local-only and an organisation profile's limits:
    a role whose only options leave the phone is off under local-only, and a role an organisation
    pins can't be changed. Embeddings are not a role: manual search and memory embed on the phone,
    and sending them to a cloud model would be a privacy step backwards for little gain.

## Phases

- **P0 — the classifier and labelled chat pickers (one PR, after PR 885 merges).** This is the
  labelling PR the owner asked for after PR 885. It is built from `main` by the session that owns PR
  885. It covers:
  - the classifier, the shared words and the per-provider rows;
  - every provider's chat picker with the "Can't be your assistant" section and its labels;
  - the typed-id warning and the saved-model warning in Settings;
  - folding in the xAI and Gemini name lists.

  **Cleanup:** PR 887's `GeminiThinkingStyle.none` marker list (tts, native-audio, embedding,
  imagen, veo, aqa ids get no `thinkingConfig`) comes from the classifier instead of being a second
  list. Full unit suite and Release build.
- **P1 — roles (one PR, after P0).** Covers Design 8–13:
  - the Roles section in Settings › Intelligence, with the Assistant, Vision, Voice, Live and
    Dictation pickers;
  - each provider's per-role defaults;
  - the "this key can also…" card in onboarding and in Settings;
  - the Vision model tried first for photo turns;
  - folding the voice-engine, Live-provider and dictation settings into their role pickers;
  - Plan JZ's Gemini speech-model picker reading `.speech`, replacing its own filter (its URL-safety
    check on the id stays).

  The core is deterministic and tested headless: which roles a key offers, each role's candidate
  list, the default per provider, and the photo-turn order with and without a Vision model. Full
  unit suite and Release build.
- **P2 — live lists.** Fetch the real list with a key for every provider, above all Z.ai, Qwen and
  MiniMax, whose list shapes are undocumented. Correct the rows, and record each provider's shape
  in this plan. On the device, check each role's default model per provider and one photo turn
  through a chosen Vision model.
- **Later — Images.** A cloud image tool, as its own plan, then the Images role (Design 12).

## Decisions

Taken (owner, 2026-10-29):
- Chat pickers label non-chat models, and a typed non-chat id gets the same warning. A saved one
  that can't answer is flagged in Settings.
- PR 885 stays as it is, and the labelling is P0, a separate PR after it. Hiding in the main picker
  is also acceptable to the owner once roles give the models a home.
- Roles: Assistant, Vision, Voice, Live and Dictation, with Images later. They are offered when a
  key is added, in onboarding and in Settings, and never switched on silently. Vision is a chosen
  model for a text-only assistant's photo turns.

Open:

1. **Order against Plan JZ.** *Default: Plan JZ's code PR ships with its own Gemini speech filter*,
   and P1 switches it to the classifier once P0 is in. That way neither waits on the other.
   *Alternative:* JZ's code waits for P0.
2. **The OpenAI voice after 2027-01-06.** OpenAI removes every model its speech endpoint takes, and
   names a realtime model as the replacement. That is a different transport (a session, not a POST
   per sentence). *Options:* move the OpenAI voice to the realtime model; or retire it, saying so
   to anyone who chose it, and offer OpenRouter's or another provider's voice instead. Planned in
   Plan [KB](KB-openai-voice-after-speech-models.md) (PR 889).
3. **More voices.** Mistral (Voxtral, multilingual, a voice list), MiniMax, Qwen and OpenRouter (one
   key for several vendors' voices) all have speech. Groq's is English and Saudi Arabic only.
   *Default: none scheduled;* each would be its own plan in the shape of Plan JZ. Once roles exist,
   each new voice is just another option in the Voice picker.
4. **"Use all" in onboarding.** *Default: offered, with each role's cost and destination named on
   the card.* *Alternative:* one role at a time only, so nothing is accepted in bulk.
5. **Vision handoff for tools.** *Default: the Vision model answers the photo turn.* *Later option:*
   it describes the photo and the assistant answers. That keeps the assistant's tools and manuals in
   play (useful for "what's this part number") at the cost of detail and a second request.
6. **Live default per provider.** *Default: the provider's documented realtime model.* Where a
   provider has more than one (OpenAI's mini and full realtime models), the cheaper one is the
   default for a role switched on from a suggestion.
