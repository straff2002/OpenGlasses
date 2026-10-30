# Plan KA — Model Kinds and Roles Across Providers (what a listed model is for, and which job uses it)

**Status:** 🚧 P2 built 2026-10-30 — provider lists, a usable-model check and current defaults.
The classifier reads a word that names a kind before the words that only say how a model is reached
(`gpt-live-transcribe`, `gpt-realtime-whisper` and `grok-voice-transcribe-2.0` are transcription),
and labels the families that fell through to chat (Gemini Nano Banana and Omni, Qwen Wan image,
HappyHorse, HappyOyster, CosyVoice and Paraformer, Z.ai CogVideoX, Mistral Shieldstral, MiniMax and
Qwen `t2v`, xAI's Imagine video). A separate, pure `ModelTransport` check says whether the app has a
connection that can use a model for a job: OpenAI Live takes only the realtime socket's
`gpt-realtime…` models (not `gpt-live-1` or `gpt-realtime-translate`), OpenAI Dictation only upload
models (not the streaming-session ones or the diarizing one), OpenAI Voice only `/v1/audio/speech`
models, and streaming-only speech or transcription models (Mistral's `…-tts-realtime-…`, Gemini's
`…-transcribe-live`) none. OpenAI's `shutdown_date` is read into `ModelListMetadata`, and the dates
its list returned on 2026-10-30 are kept for saved models (`ModelShutdownCalendar`): a retired model
can't be chosen anywhere and shows "Retired" in the dimmed section; one retiring within 90 days
stays choosable and says when; a saved one gets the warning in Settings beside the kind warning.
Role pickers, the "this key can also…" card and the defaults use both checks, and an unreachable
model shows "Needs a connection the app doesn't have yet". Defaults moved: see the provider table.
Gemini Live's fallback is `gemini-3.8-live`, its family counts as async-tool-capable, a stable id
with no date beats an old alias, and 3.8 Live is sent no thinking level (the docs say it must be
omitted). No new host or path is called. Owed: the device checklist below; a catalog sync for the
new strings; live list checks for the providers other than OpenAI and Anthropic (docs-based, by
owner decision); the open questions below; Images later (Design 12).
**P1:** 🚧 built 2026-10-30 — roles. `ModelRoleCatalog` (pure, tested headless) decides which
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

## What the providers give us (checked 2026-10-30)

OpenAI's row was **live-checked on 2026-10-30 with an owner-supplied key**: its `/v1/models` list
(140 models, kept as a test fixture), and which ids its speech, transcription and realtime endpoints
accept. Every other row is **docs-based, checked 2026-10-30** against the provider's own reference
pages; by owner decision those providers are not live-checked in this round.

| Provider | List and its kind field | Non-chat kinds in it | Roles the app can serve | Defaults (assistant / vision / voice / live / dictation) |
|---|---|---|---|---|
| OpenAI *(live-checked)* | `GET /v1/models`: `id`, `owned_by`, **`shutdown_date`** (null or `YYYY-MM-DD`); no kind field | speech, transcription, realtime, audio-chat, image, video (retired), embedding, moderation | Vision; Voice (`/v1/audio/speech`: `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts`, all removed 2027-01-06); Live (realtime socket: `gpt-realtime-2.1`, `-2.1-mini`, `-2`, `-1.5`; `gpt-realtime` and `-mini` until 2027-01-20); Dictation (upload: `gpt-transcribe`, `whisper-1`, `gpt-4o-*-transcribe`). Not reachable: `gpt-live-1` (sessions API, refused on the socket), `gpt-realtime-translate`, `gpt-live-transcribe` and `gpt-realtime-whisper` (streaming sessions only), `gpt-audio-1.5` as a voice | **`gpt-5.4-mini`** (was `gpt-4o`, shuts down 2027-01-14) / `gpt-5.4-mini` / `gpt-4o-mini-tts` (kept: no replacement on that endpoint, Plan KB) / `gpt-realtime-2.1` (`-mini` from a suggestion) / `gpt-transcribe` |
| Anthropic | `GET /v1/models`: chat only; `capabilities.image_input`, `lifecycle`, `retires_at` (not read yet) | none | Vision | **`claude-sonnet-5-5`** (was `claude-sonnet-5`, now legacy) / `claude-haiku-5-5` |
| Gemini | `supportedGenerationMethods` (the full value list is not enumerated in the reference) | speech, live, transcription (`gemini-3.5-transcribe`, `…-transcribe-live`), image (incl. Nano Banana), video (Omni), music, embedding, agents | Vision, Voice, Live | `gemini-3.5-flash-lite` / same / `gemini-3.8-flash-lite-tts` / **`gemini-3.8-live`** (was `gemini-2.5-flash-native-audio-latest`; the preview behind it shuts down 2026-11-17) |
| xAI | `/v1/models` has no modalities; `/v1/language-models` adds `input_modalities`/`output_modalities` | image, video, voice agent, transcription | Vision, Voice (no model id) | `grok-4.7` / same |
| Groq | `GET /openai/v1/models`; no kind field | transcription, speech (preview), guard | — (vision model is a preview only) | `openai/gpt-oss-120b` / none |
| DeepSeek | `input_modalities` / `output_modalities` | none | Vision | `deepseek-flash` / **`deepseek-flash`** (new) |
| Mistral | `capabilities` flags (now also `audio_transcription_realtime`, `classification`) | transcription, speech, OCR, embedding, moderation, Shieldstral | Vision | `mistral-medium-latest` / `mistral-small-latest` |
| Z.ai | **still undocumented**: no list endpoint in the API reference | transcription, OCR, image, video (CogVideoX) | Vision | **`glm-5.3`** (was `glm-4.5`, no longer in the chat model list) / **`glm-5.3-flash`** (new) |
| Qwen | **native list documented** (`/api/v1/models`, capability codes `TG`, `VU`, `IG`, `VG`, `ASR`, `TTS`, `TR`, `ME`, `Realtime-*`, …); the OpenAI-compatible and Coding Plan lists are not | speech (incl. CosyVoice), transcription, live/omni, image (incl. Wan image), video (Wan, HappyHorse), embedding, rerank | Vision; Live through a Model Studio workspace key | `qwen3.7-plus` / **`qwen3.7-plus`** (new) |
| MiniMax | **documented**: OpenAI-shaped `GET /v1/models` (`id`, `object`, `created`, `owned_by`) — the app already asks it first | speech, music, image, video (`T2V-01`, Hailuo) | Vision | **`MiniMax-M3`** (was `MiniMax-M2.7`, no longer on the models page) / **`MiniMax-M3.1-Flash`** (new) |
| OpenRouter | `architecture.output_modalities`; the list defaults to text output, `?output_modalities=` returns the rest | every kind, when asked | Vision | `anthropic/claude-sonnet-5` / **`anthropic/claude-haiku-5.5`** (new) |

Sources (all read 2026-10-30): OpenAI models list and deprecations reference, the `gpt-realtime-2.1`,
`-2.1-mini`, `gpt-live-1`, `gpt-realtime-translate`, `gpt-transcribe`, `gpt-live-transcribe`,
`gpt-realtime-whisper` and `gpt-5.4-mini` model pages; Anthropic's models list and models overview;
Gemini's models page, Live guide, deprecations page and `gemini-3.8-live` model page; xAI's models
reference; Groq's models, vision and deprecations pages; Mistral's models overview and audio pages;
DeepSeek's list-models and pricing pages; Z.ai's API index, pricing and GLM-5.3 Flash guide; Alibaba
Model Studio's list-models and models pages; MiniMax's list-models and models pages; OpenRouter's
models API reference.

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
- **P2 — provider lists, usable models and defaults (one PR, after P1).** 🚧 Built 2026-10-30.
  OpenAI's list was fetched with the owner's key and its endpoints tried by hand; every other
  provider was checked against its docs (owner decision: no live check for them this round). Covers:
  - the classifier fixes: kind words before `realtime`/`live`/`voice`; the families that fell
    through to chat; Qwen's Wan image models; Mistral's realtime-transcription and classification
    flags; a Gemini Live-only model whose id names transcription;
  - `ModelTransport`, a pure "can the app reach this model for this job" check, separate from kind,
    read by the role pickers, the key's card, the defaults and the chat picker's dimmed section;
  - shutdown days: OpenAI's `shutdown_date` parsed generically, the 2026-10-30 dates kept for saved
    models, retired models unchoosable, retiring ones (90 days) noted, a saved one warned in
    Settings; the date is injected for tests;
  - the defaults in the table above; no default (assistant or role) names a dated model except
    OpenAI's voice, which has no replacement on its endpoint (Plan KB);
  - MiniMax's probe list after its documented `GET /v1/models` moved to its current models.
  Saved models keep their ids (Plan KC P1 moves OpenAI live models off retiring ids). Full unit suite
  and Release build.

  **Device checklist (owner: ChatGPT, the Claude API and, this round, an OpenAI API key):**
  1. ChatGPT as the assistant with Claude Haiku as Vision: one photo turn on the glasses is answered
     by Haiku, and the next text turn goes back to ChatGPT.
  2. Add an OpenAI key in Settings: the "this key can also…" card offers Voice, Live and Dictation;
     tap each, and check the OpenAI voice speaks a reply, Live mode starts on `gpt-realtime-2.1-mini`
     and dictation transcribes a question.
  3. Open the OpenAI key's model list in the model editor: `gpt-live-1` and `gpt-live-transcribe`
     sit in the dimmed section with "Needs a connection the app doesn't have yet", retired models
     (`o4-mini`, `sora-2`) with "Retired", and `gpt-4o` is choosable with "Retires 14 January 2027".
  4. A saved `gpt-4o` (or `o3-mini`) model shows the retiring (or retired) warning in AI & Personality
     beside its other labels, and the Voice row for OpenAI says when its model retires.

  **Open questions (P2), each kept at today's behaviour until answered:**
  1. Gemini: do `gemini-nano-banana-2.1`, `gemini-omni-*`, `deep-research-*`, `antigravity-*` and
     `gemini-3.5-transcribe-live` list `generateContent` or `bidiGenerateContent`? The id now decides
     for the first two and the last; the agents are still read as chat.
  2. xAI: does `/v1/models` carry `grok-voice-*`, `grok-voice-transcribe-2.0` and the Imagine ids, and
     which chat models take images (`/v1/language-models`)? `grok-build-*` stays "other" until then.
     The voice agent is documented as OpenAI-Realtime-compatible; a Live role for xAI waits on a
     check.
  3. Z.ai: is there a model list at all, and does the Coding Plan pass images to `glm-5.3-flash`?
  4. MiniMax: does `/v1/models` include speech, music and video ids, and is `MiniMax-M2.7` still
     served (it stays last in the probe list)?
  5. Qwen: the authenticated shape of `/compatible-mode/v1/models` and the Coding Plan list (a keyless
     call returned six ids where the app's fallback has ten). The native list's capability codes are
     recorded above; reading them needs a Model Studio key, so it waits.
  6. Mistral: are the capability flags set as documented on the Voxtral 3 and OCR 4.1 models?
  7. ~~OpenRouter: should `?output_modalities=speech` / `transcription` be fetched?~~ Decided
     (owner, 2026-10-30): no, it waits until the app has an OpenRouter voice or dictation connection.
  8. OpenAI: `gpt-6-luna` is cheaper than `gpt-5.4-mini` for photos, but whether the photo turn needs
     tools (its function calling on Chat Completions needs reasoning `none`) is unconfirmed; the
     vision default stays `gpt-5.4-mini`. Plan KC's table dates `gpt-realtime-mini-2025-10-06` to
     2027-01-20; OpenAI's deprecations page says it went on 2026-07-23 (left to Plan KC).
  9. Anthropic's list carries `retires_at` and `capabilities.image_input`; neither is read yet.
  10. ~~Groq's only image model (`qwen/qwen3.8-27b`) is a preview.~~ Decided (owner, 2026-10-30):
      it is Groq's Vision default, and the app now sends it photos.
  11. ~~The custom provider's default `gpt-4o`.~~ Decided (owner, 2026-10-30): it follows OpenAI's
      default (`gpt-5.4-mini`), since its default address is OpenAI's. The same change moves the
      OpenRouter assistant default to `anthropic/claude-sonnet-5.5`, in step with Anthropic's.
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

Taken (owner, 2026-10-30, after P2): Groq's preview image model is its Vision default; the custom
provider follows OpenAI's default; OpenRouter's speech and transcription lists wait for a connection
that can use them; the OpenAI voice after 2027-01-06 is Plan KB's to settle (decision 2 below).

Open:

1. **Order against Plan JZ.** *Default: Plan JZ's code PR ships with its own Gemini speech filter*,
   and P1 switches it to the classifier once P0 is in. That way neither waits on the other.
   *Alternative:* JZ's code waits for P0.
2. **The OpenAI voice after 2027-01-06.** OpenAI removes every model its speech endpoint takes, and
   names a realtime model as the replacement. That is a different transport (a session, not a POST
   per sentence). *Options:* move the OpenAI voice to the realtime model; or retire it, saying so
   to anyone who chose it, and offer OpenRouter's or another provider's voice instead. Planned in
   Plan [KB](KB-openai-voice-after-speech-models.md) (PR 889). P2 keeps `gpt-4o-mini-tts` as the
   OpenAI voice's model (the owner's key confirmed `gpt-realtime-2.1-mini` and `gpt-audio-1.5` are
   refused on `/v1/audio/speech`), and the OpenAI row in the Voice picker says when it retires.
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
