# Plan KC — OpenAI Realtime on the Current Protocol (the beta was removed on 2026-05-12)

**Status:** 🚧 P0 built 2026-10-29 (PR 892) — the current protocol, checked live with the owner's
key the same day (see "What the probe found"). Decisions 1, 3, 4 and 5 taken at their defaults
("let's fix that then"). P1 built 2026-10-29 (PR 894; live check and catalog sync PR 895) — model
IDs before 2027-01-20; decision 2 taken at its default after the price check (rewrite once, with
one notice). P2 built 2026-10-30 (PR 896) — dictation on `gpt-transcribe`, checked live; the new
model drops hyphens from codes, so the vocabulary's spelling is restored. The P3 device pass not
started. Drafted
2026-10-29 (PR 890).
**Origin:** found while drafting Plan KB (the OpenAI voice after 2027-01-06, PR 889), which puts it
out of scope as its decision 6. This is that plan.
**Deadlines:** the protocol is **already past its date**, so P0 is a fix, not a migration. After
that: the template's model `gpt-realtime` goes on **2027-01-20** (P1), and the transcription models
go on **2027-02-26** (P1 for the live mode, P2 for dictation).
**Related:** [Live provider adapters](live-provider-adapters.md) (the profile design this plan
extends), [Issue 715](issue-715-openai-compatible-realtime.md) (the compatible endpoint), the user
guide [Realtime setup](../compatible-realtime.md), Plan KB (PR 889, drafted; its option (a) would
reuse P0's adapter), Plan [JM](JM-dictation-in-a-noisy-room.md) (cloud dictation).

---

## What OpenAI has said (checked against OpenAI's docs, 2026-10-29)

**The deprecations page:**

| Item | Removed | Replacement OpenAI names |
|---|---|---|
| Realtime API beta, and the `OpenAI-Beta: realtime=v1` header | **2026-05-12** (already gone) | the Realtime API (the GA interface) |
| `gpt-4o-realtime-preview` and its snapshots | 2026-05-07 (already gone) | `gpt-realtime-1.5` |
| `gpt-4o-mini-realtime-preview` | 2026-05-07 (already gone) | `gpt-realtime-mini` |
| `gpt-realtime`, `gpt-realtime-2025-08-28`, `gpt-4o-realtime` | 2027-01-20 | `gpt-realtime-2.1` |
| `gpt-realtime-mini`, `gpt-realtime-mini-2025-12-15`, `gpt-4o-mini-realtime` | 2027-01-20 | `gpt-realtime-2.1-mini` |
| `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` (and `-2025-12-15`), `whisper-1` | 2027-02-26 | `gpt-live-transcribe` or `gpt-transcribe` |

**The realtime guide's beta-to-GA list:** remove the `OpenAI-Beta: realtime=v1` header; set
`session.type`; move output audio settings under `session.audio.output`; the response events are
now `response.output_text.delta`, `response.output_audio.delta` and
`response.output_audio_transcript.delta`.

**The WebSocket guide:** `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`, with
`Authorization: Bearer <key>`. None of the examples sends `OpenAI-Beta`. Its `session.update`
example is `{"type": "session.update", "session": {"type": "realtime", "instructions": "…"}}`. The
guide recommends WebRTC with an ephemeral token for browsers and phones, and WebSocket for servers.

**The client-events reference, GA `session` object** (field names as published):

- Top level: `type` ("Always `realtime` for the Realtime API"), `instructions`, `output_modalities`,
  `audio`, `tools`, `tool_choice`, `max_output_tokens`, `truncation`, `model` (cannot be changed by
  `session.update`), and others.
- `output_modalities`: the default is audio plus its transcript. `["text"]` gives text only. "It is
  not possible to request both `text` and `audio` at the same time."
- `audio.input`: `format` `{type, rate}`, `transcription` `{model, language, prompt, …}`,
  `turn_detection` (`server_vad`: `threshold`, `prefix_padding_ms`, `silence_duration_ms`,
  `create_response`, `interrupt_response`, `idle_timeout_ms`), `noise_reduction`.
- `audio.output`: `format`, `voice`, `speed`. PCM is `{"type": "audio/pcm", "rate": 24000}`, and
  24000 is the only rate. Voices: `alloy` (default), `ash`, `ballad`, `coral`, `echo`, `sage`,
  `shimmer`, `verse`, and `marin` / `cedar` (recommended for quality). The voice can change only
  before the first audio output.
- Transcription model values listed: `whisper-1`, `gpt-transcribe`, `gpt-live-transcribe`,
  `gpt-4o-mini-transcribe` (and `-2025-12-15`), `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`,
  `gpt-realtime-whisper`, or any string.
- `conversation.item.create` with an `input_image` part: the field is **`image_url`**, a **data
  URI** of the base64 bytes, with an optional `detail`. (The app sends `image` with bare base64.)
- `response.create` takes `response.output_modalities` and `response.tool_choice`.
  `conversation.item.truncate` and `input_audio_buffer.append` are unchanged.

**The server-events reference:** `session.created` still comes first, and `session.updated` answers
a `session.update`. The beta names `response.audio.delta` and `response.audio_transcript.delta`
**do not appear**. `response.output_audio.delta` and `response.output_audio_transcript.delta` carry
`delta`, `item_id` and `content_index` as before. Unchanged: `input_audio_buffer.speech_started` /
`speech_stopped`, `conversation.item.input_audio_transcription.completed` (`transcript`),
`response.output_item.added` / `.done` (function-call items with `call_id`, `name`, `arguments`),
`response.function_call_arguments.done` (now also carries `name`), `response.done` (`usage` with
`input_tokens` / `output_tokens`), and `error` (`type`, `code`, `message`). Added:
`conversation.item.added` / `.done`, `output_audio_buffer.*`, `rate_limits.updated`.

**The transcription guide:** `/v1/audio/transcriptions` recommends `gpt-transcribe` ("for
transcribing recorded speech in its original language"). Its default JSON has `text` and
`languages`. `gpt-live-transcribe` is described only for live audio.

## What the app does today

- **Connection.** `RealtimeConnectionConfiguration.request` builds
  `wss://api.openai.com/v1/realtime?model=…` with a Bearer key and, for the built-in OpenAI provider
  (`isCustom == false`), adds `OpenAI-Beta: realtime=v1`. Compatible endpoints never get the header.
  `RealtimeModelConfig.request` goes through the same builder, and treats `providerID != "openai"`
  as custom.
- **Protocol.** Every OpenAI-shaped live model has the profile `openai.beta.v1`
  (`RealtimeProtocolProfile.openAIBetaV1`): the OpenAI template, the compatible template, the three
  legacy migrations in `Config.realtimeModel(for:)` / `migrateRealtimeModelsIfNeeded()`, and
  `OpenAIRealtimeService.configure(connection:…)`. The profile picks `OpenAIRealtimeAdapter`.
- **The adapter's beta shapes.** `sessionUpdate` sends `modalities: ["text", "audio"]`,
  `input_audio_format` / `output_audio_format: "pcm16"`, `input_audio_transcription` with
  `gpt-4o-mini-transcribe`, and a top-level `turn_detection`. `decode` reads
  `response.audio.delta` and `response.audio_transcript.delta`. Images go out through
  `LiveInjectionEnvelope.realtimeImage` as `{"type": "input_image", "image": <base64>}`.
- **Errors.** Any `invalid_request_error` from OpenAI becomes one terminal message, "Realtime
  authentication or configuration was rejected. Check the saved model settings." A wrong key, an
  unknown field and a removed model all read the same.
- **Shared code.** `QwenRealtimeAdapter` and `QwenAudioRealtimeAdapter` subclass
  `OpenAIRealtimeAdapter`. Qwen speaks the beta shape with its own session schema, so **the beta
  adapter cannot simply be rewritten in place**. `RealtimeSessionManager.sessionToolDeclarations`
  checks `profile == .openAIBetaV1` to send the job tools only.
- **Model.** New OpenAI live models default to `gpt-realtime`. Saved models keep whatever ID was
  typed or migrated. The legacy `Config.openAIRealtimeModelConfig` takes the first saved OpenAI
  model whose ID contains "realtime", which can be a `gpt-4o-realtime-preview` removed in May.

## What the probe found (2026-10-29, the owner's key, `Scripts/openai-realtime-probe.mjs`)

**Outcome 1, below.** The request the app sent got an `error` at once —
`invalid_request_error` / `beta_api_shape_disabled`, "The Realtime Beta API is no longer supported.
Please use /v1/realtime for the GA API." — and the socket closed with code 4000. The header alone is
enough: the GA session shape with the beta header was refused the same way. The beta session shape
without the header got `session.created`, then `missing_required_parameter` for `session.type`.
Wearers saw "Realtime authentication or configuration was rejected. Check the saved model settings."
The OpenAI live mode has not worked since 2026-05-12.

The current protocol worked on `gpt-realtime`, and on `gpt-realtime-2.1` with both
`gpt-live-transcribe` and `gpt-transcribe` in the session (decision 4: `gpt-live-transcribe`).
A whole turn as P0's adapter sends it — tools in the session, a photo as an `image_url` data URI,
synthesised speech appended to the buffer — produced `input_audio_buffer.speech_started` /
`speech_stopped`, a live transcription of the speech, a `get_torque({"bolt":"A"})` call, and after
the `function_call_output` a spoken answer. Only the event types listed in "What OpenAI has said" were
needed; `response.content_part.*`, `response.output_audio.done`, `output_audio_buffer.*`,
`conversation.item.added` / `.done` and `rate_limits.updated` also arrive and are ignored.

## What happens today (reasoned before the probe; outcome 1 is what happened)

The beta was removed on 2026-05-12, and every connection to `api.openai.com` from the OpenAI
template still asks for it. What wearers see depends on how OpenAI treats the leftover header and
the beta fields. A probe without a key can't tell: OpenAI checks the key first and closes with code
3000 `invalid_api_key` either way (checked 2026-10-29, with and without the header). There are three
possible outcomes:

1. **The header is refused.** An `error` event at the start → `invalid_request_error` → "Realtime
   authentication or configuration was rejected." The live mode never starts, and the message
   points the wearer at their key, which is fine.
2. **The header is ignored, and the beta `session.update` is refused** (`modalities`,
   `input_audio_format` and a top-level `turn_detection` are not GA fields). Same message, same
   result.
3. **The header and the unknown fields are both ignored.** The session reaches `session.updated`, so
   the app shows the live mode as ready, and the wearer's speech is transcribed and answered. But
   every reply arrives as `response.output_audio.delta`, which the adapter drops. **The wearer
   hears nothing**, sees their own words and no answer, and the turn still completes. Photos sent
   as `image` instead of `image_url` are refused or ignored.

Each of the three means the OpenAI live mode does not work today. **The probe tells us which one it
is** (P0, step 1). That matters for the support wording and for whether anyone could have used the
mode since May. It does not change the fix.

**The compatible profile is not affected by OpenAI's removal.** A server that speaks the beta shape
(Qwen-style gateways, older self-hosted servers) still gets exactly what it gets today. A server
that has moved to the GA shape fails the same way OpenAI does, and has no profile to choose. P0
adds one.

## Design

**A second OpenAI profile, not an edit to the first.** Saved live models carry a protocol version
(`profileID`) so that a provider's changes never silently change a saved model's wire contract. This
is the case that design was for:

- `RealtimeProtocolProfile.openAIRealtimeV1 = "openai.realtime.v1"`, titled "OpenAI Realtime". The
  beta profile keeps its raw value `openai.beta.v1`, and is retitled "OpenAI Realtime beta (older
  compatible servers)". Same capabilities, media policy, 24 kHz input and audio configuration as
  the beta profile.
- `OpenAIRealtimeGAAdapter`, a sibling of `OpenAIRealtimeAdapter`, not a subclass, so the Qwen
  adapters keep inheriting the beta shape untouched. Function-call bookkeeping
  (`names` / `deliveredCalls` / `completedCall`) and the shared events go into a small helper that
  both use, so the duplicate-call guard isn't copied.
- **Which provider gets which.** `profiles(for: "openai")` returns `[.openAIRealtimeV1]` only (the
  prefix filter would otherwise offer the beta too). The compatible template offers every profile,
  as it does today. The compatible template's default is decision 3.
- **The header goes.** `RealtimeConnectionConfiguration.request` stops setting `OpenAI-Beta` for any
  profile. No profile needs it any more: OpenAI removed it, and compatible servers never got it.
  `RealtimeModelConfig.request` already strips it for Gemini and Doubao, and that line goes too.
- **No new route, egress or disclosure.** Same host, same key, same data, same
  `.openAIRealtimeSession` route, the same medical local-only block and teardown. The privacy copy
  doesn't change. The app doesn't send `OpenAI-Safety-Identifier`. It is optional, and the app has
  no user identifier to send.

## Phases

### P0 — The current protocol (headless core + one live probe; ship as soon as it's green) — 🚧 built 2026-10-29

**As built:** `RealtimeProtocolProfile.openAIRealtimeV1` and `OpenAIRealtimeGAAdapter` beside the
beta adapter, which now shares `OpenAIRealtimeCallTracker` (duplicate-call guard) and
`OpenAIRealtimeEvents` (shared events and error wording) with it; Qwen's subclasses untouched.
`LiveInjectionEnvelope.realtimeImageDataURI` for the image. Errors split into four terminal kinds
(key, model, protocol, other configuration) plus the retryable rest, classified on the codes the
probe saw (`beta_api_shape_disabled`, `missing_required_parameter` naming `session.type`). The
protocol wording names "the other OpenAI Realtime protocol" only on a compatible model
(`offersProtocolChoice`, set by `RealtimeAdapterRegistry`). Migration `realtimeModelsMigrated_v2`
(`RealtimeModelConfig.movingOpenAIOffBeta`, pure). Tests: `OpenAIRealtimeCurrentProtocolTests`
(fixture `openai-realtime-v1.json`) and `OpenAIRealtimeProtocolMigrationTests`; the beta golden in
`OpenAIRealtimeJobToolsTests` and the Qwen tests unchanged. Owed: P3. (The five new
strings were synced into the catalog with P1's, below.)


1. ✅ **Probe first, ten minutes, the owner's key.** `node Scripts/openai-realtime-probe.mjs` (lands with
   this plan, so it can be run before P0 is scheduled; Node 22+). It reads the key from `OPENAI_API_KEY` only, and prints event *types* and
   error codes, never content or the key. It runs six cases: the app's request today, the GA shape
   with the beta header, the beta shape without it, GA on `gpt-realtime`, and GA on
   `gpt-realtime-2.1` with each of `gpt-live-transcribe` and `gpt-transcribe`. Its output goes in
   the PR description and settles "What happens today" (1, 2 or 3). It also confirms that the
   replacement model and both transcription models are accepted in a session.
2. **The profile and the adapter**, as in Design. `encode`:
   - `configure` → `session.update` with `type: "realtime"`, `output_modalities: ["audio"]`,
     `instructions`, `audio.input.format {audio/pcm, 24000}`, `audio.input.transcription.model`
     (decision 4), `audio.input.turn_detection` (today's `server_vad` values, unchanged),
     `audio.output.format {audio/pcm, 24000}`, and `tools` / `tool_choice: "auto"` when there are
     tools. No `voice` (decision 5).
   - `updateContext` → `session.update` with `type: "realtime"` and `instructions` only.
   - `image` → an `input_image` part with `image_url: "data:image/jpeg;base64,…"`, behind a new
     `LiveInjectionEnvelope.realtimeImageGA`. The beta builder stays as it is, for Qwen and the beta
     profile.
   - `text`, `audio`, `toolResult`, `interrupt`, and `response.create` with `tool_choice: "none"`
     for announcements: shapes unchanged, reused.
   - `decode`: `response.output_audio.delta`, `response.output_audio_transcript.delta`, and every
     other event the beta adapter reads, under its GA name where it was renamed. The beta names are
     *not* accepted on this profile, so a test fails if a fixture drifts back.
3. **Errors that say what went wrong** (both OpenAI profiles). `invalid_api_key` → "OpenAI did not
   accept this API key." `model_not_found`, or a message naming the model → "OpenAI does not offer
   the realtime model "<id>" to this key. Choose another model in the model editor." An unknown
   parameter → "This server does not accept the selected realtime protocol. Choose the other OpenAI
   Realtime protocol in the model editor." That last one only appears on a compatible model, where
   there is another profile to choose. All three are terminal. The recoverable codes in
   `RealtimeReconnect.isFatalOpenAIError` are unchanged. All new strings are localised, with no
   plan letters.
4. **Migration** `realtimeModelsMigrated_v2`. Each saved live model with `providerID == "openai"`
   and profile `openai.beta.v1` becomes `openai.realtime.v1`. Compatible models are untouched. It
   runs once, is idempotent, and leaves the flag unset if the Keychain write fails, as v1 does.
   The legacy paths in `Config.realtimeModel(for:)`, `migrateRealtimeModelsIfNeeded()` (OpenAI
   branch) and `OpenAIRealtimeService.configure` (`isCustom == false`) produce the new profile.
5. **Call sites.** `sessionToolDeclarations` uses a `profile.isOpenAIShape` (both OpenAI profiles)
   in place of `== .openAIBetaV1`. Every exhaustive `switch` over the profile gains the case.
6. **Tests.**
   - Golden GA `session.update`, image item, `updateContext` and announcement `response.create`.
   - Decode fixtures for every GA server event the adapter reads, built from the reference's field
     lists. Beta event names are ignored on the GA profile.
   - Duplicate function-call delivery across `function_call_arguments.done` and
     `output_item.done`, on both profiles.
   - Request headers: no `OpenAI-Beta` for any profile. `CompatibleRealtimeTests` line 15 flips
     from expecting the header to expecting none.
   - **Qwen Omni / Qwen Audio golden output byte-identical to `origin/main`**, and the beta
     profile's `session.update` byte-identical.
   - The migration: openai beta → GA; compatible beta kept; a second run is a no-op; Keychain
     failure leaves the flag unset.
   - `profiles(for:)` for "openai" and "compatible".
   - Error wording for the three codes.
7. **Docs in the same PR:** the profile table and the header paragraph in
   [Realtime setup](../compatible-realtime.md), and this plan's status and index row.

Done when: the full suite and a Release build are green, and the probe's output is in the PR.

### P1 — Model IDs before 2027-01-20 (headless) — 🚧 built 2026-10-29

**As built:** `OpenAIRealtimeModelRetirement` (pure) holds the seven entries below with their
removal dates and 2.1-family replacements; the preview and `gpt-realtime-mini` entries cover their
dated snapshots, `gpt-realtime` itself matches exactly so `gpt-realtime-2.1` is never caught. The
OpenAI template defaults to `gpt-realtime-2.1`. Migration `realtimeModelsMigrated_v3`
(`Config.migrateOpenAIRealtimeModelIDsIfNeeded`, after v1 and v2) rewrites OpenAI-provider saved
live models once, leaves compatible models alone, keeps the flag unset when the Keychain write is
rejected, and leaves one notice naming each old and new ID ("is retiring … on <date>" before the
removal date, "no longer offers" after it). The notice is held in preferences until it is posted,
once, to the notice centre as a warning that stays until dismissed: at launch, and from the two
screens that also run the migration. `Config.openAIRealtimeModelConfig(on:)` skips IDs the table
marks removed on that day, in every fallback, so after 2027-01-20 a saved `gpt-realtime` chat entry
is no longer offered to the live mode. The transcription model was already `gpt-live-transcribe`
(P0); unchanged. Tests: `OpenAIRealtimeModelRetirementTests` (table, dates, rewrite, idempotence,
notice wording, template default) and `OpenAIRealtimeModelIDMigrationTests` (the stored migration,
the rejected write, the one-time notice, the legacy shortcut). Owed: P3.

**Catalog sync** (2026-10-29, with the live check below): the eight strings P0 and P1 added (P0's
three error messages, its session-settings message and the beta profile's title; P1's three
notices) are in `Localizable.xcstrings`, translated into the 13 complete languages (ar, es-MX,
fr-CA, hu, it, ja, ko, nl, pt-BR, ru, ur, zh-Hans, zh-Hant) with the catalog's existing wording for
the realtime service, the model editor and the live mode. Add-only, in Xcode's order;
`LocalizationCatalogGuardTests` and `BrandNameGuardTests` pass.

**Live check of the rewrite targets** (2026-10-29, after the merge, the owner's single-use key,
`Scripts/openai-realtime-probe.mjs`, which gained a `gpt-realtime-2.1-mini` session case and runs
the whole turn on both models): both `gpt-realtime-2.1` and `gpt-realtime-2.1-mini` accepted the
current-protocol session with `gpt-live-transcribe`, and on each a whole turn — tools in the
session, a photo as an `image_url` data URI, synthesised speech — produced a live transcription, a
`get_torque({"bolt":"A"})` call and, after its result, a spoken answer. P0's six cases repeated
unchanged (the beta still refused with `beta_api_shape_disabled`, `gpt-realtime` still answering
until its date).

**Price check for decision 2** (OpenAI's pricing page, 2026-10-29, per 1M tokens):
`gpt-realtime-2.1` matches `gpt-realtime` on audio (32 in, 64 out, 0.40 cached), text input (4)
and image input (5); only text output rises, 16 → 24. The live mode answers in audio, so text
output is mostly the spoken reply's transcript. `gpt-realtime-2.1-mini` matches
`gpt-realtime-mini` on every line. The owner chose the default: rewrite once.

- The OpenAI template's default becomes `gpt-realtime-2.1`.
- Removed and retiring IDs on saved **OpenAI** live models (`gpt-4o-realtime-preview*`,
  `gpt-4o-mini-realtime-preview`, `gpt-realtime`, `gpt-realtime-2025-08-28`, `gpt-realtime-mini*`,
  `gpt-4o-realtime`, `gpt-4o-mini-realtime`) are handled per decision 2. The table lives in one
  pure value, `OpenAIRealtimeModelRetirement`, with its dates, and is tested.
- The realtime session's transcription model becomes the one decision 4 picks, if P0 didn't already
  change it.
- `Config.openAIRealtimeModelConfig` (the legacy shortcut) skips IDs the table marks as removed.
- Tests for the table, the rewrite and the legacy shortcut.

### P2 — Dictation's transcription model before 2027-02-26 (headless) — 🚧 built 2026-10-30

**As built:** `OpenAIDictationRequest.model` is `gpt-transcribe`; nothing else in the upload
changed (`response_format: json`, the vocabulary `prompt`, a 16 kHz WAV). `transcript(from:)`
already read only `text`; new tests pin the model and feed it replies with `languages` (as strings
and as objects) and `usage` beside `text`. The probe gains the upload as the app sends it (spoken
audio from macOS `say`, the model, `json`, a vocabulary prompt) for both the new and the outgoing
model, printing the HTTP status, the reply's field names and the transcript;
`PROBE_DICTATION_ONLY=1` runs it alone. The realtime beta adapter's own `gpt-4o-mini-transcribe` is
left alone: that profile now serves only compatible servers and Qwen, whose model names are their
own, and its golden output stays byte-identical.

**What the live check found** (2026-10-30, the owner's key; synthetic `say` speech, clean audio,
eight trade codes spoken as a technician says them — "R four fifty four B", "X R seventy seven
twenty"): both models **heard** every code, 8/8, with the app's prompt, a "Vocabulary:"-labelled
prompt or none. But `gpt-transcribe` **never wrote the hyphen** — 0/8 whatever the prompt ("R454B",
"XR7720", "SLP99") — where `gpt-4o-transcribe` with the app's prompt kept it 4/8. The prompt still
reaches the model; it no longer sets the spelling. That matters downstream: refrigerant lookup
ignores hyphens, but `VaultModelIndex.resolve` matches the printed spelling, so by its code
"XR7720" does not reach a manual printing "XR-7720" (its parts are too short to be model-like; read,
not run). So P2 also adds
`OpenAIDictationRequest.restoringVocabularySpellings`: a transcript word that equals a vocabulary
code once only letters and digits are compared takes the vocabulary's spelling (codes only — a
letter and a digit, at least three, no spaces; whole words only; a key two vocabulary spellings
share is left alone). A first run that `say`-read "R-454B" as "R negative 454 B" made the new model
look worse at hearing codes; that was the synthetic audio, and the probe now spells its codes the
way they are said. **Owed:** a noisy-room comparison (the clean synthetic audio cannot show one,
Plan JM's reason for the prompt) and P3. Code terms *outside* the vocabulary come back without
their hyphens too; making the manual index hyphen-insensitive would cover those, and is not done.

### P3 — Device pass (after P0, and again after P1)

On a phone with the owner's key: start the OpenAI live mode and check a spoken turn with voice
reply and both transcripts, barge-in (truncate), a photo question, a tool call (a job tool), a
context update (location), an announcement, and medical local-only ending the session. Repeat one
turn on a compatible model set to the beta profile, if a beta-speaking server is to hand (decision
3), to confirm nothing changed there.

## Owner decisions (defaults in bold)

1. **Schedule P0 now, as a fix ahead of other work**, since the mode has probably been dead since
   May. Or: wait until after the current queue.
2. **Taken 2026-10-29: the default, after the price check in P1.** **Saved model IDs (P1): rewrite OpenAI-provider IDs to OpenAI's named replacement in the 2.1
   family (`gpt-realtime-2.1`, or `gpt-realtime-2.1-mini` for the minis), once, with one notice
   naming the old and new ID.** This includes `gpt-4o-realtime-preview*`, even though OpenAI named
   `gpt-realtime-1.5` for those in 2025: one target family avoids a second move. Or: leave saved
   IDs alone and rely on P0's "does not offer the realtime model" message. Prices of the 2.1 family
   against `gpt-realtime` are not compared here. Check them on OpenAI's pricing page before saying
   yes.
3. **The compatible template's default stays `openai.beta.v1`**, so existing and new compatible
   setups behave as today, and `openai.realtime.v1` is offered beside it. Or: default new
   compatible models to the current protocol, since OpenAI's own SDKs now speak it.
4. **The realtime session's transcription model: `gpt-live-transcribe`**, which OpenAI describes for
   live audio, if the probe shows it accepted. Otherwise `gpt-transcribe`.
5. **No voice setting for the OpenAI live mode in this plan** (the server default, `alloy`, as
   today). Or: offer the GA voice list (with `marin` / `cedar` first) in the model editor. That is
   small, but it is a feature, not a fix.

## Out of scope

- WebRTC and ephemeral tokens. The wearer's own key stays in their Keychain and is sent only to
  OpenAI, as today. OpenAI recommends WebRTC for phones, but WebSocket remains documented and
  supported.
- The OpenAI cloud voice on `/v1/audio/speech` (Plan KB). KB's option (a) would build on this
  plan's adapter.
- `OpenAI-Safety-Identifier`, `noise_reduction`, `idle_timeout_ms`, `output_modalities: ["text"]`,
  MCP tools and the GPT-Live endpoint (`/v1/live/sessions`).
- The Qwen and Doubao adapters, which have their own protocol versions.

## Found in passing

- `Config.openAIRealtimeModelConfig` falls back to the active **chat** model when no saved OpenAI
  model has "realtime" in its ID. That sends a chat model ID to the realtime endpoint, which can
  only fail. P1 touches the same function. It is listed here so it isn't lost, and not fixed by
  default.
- A close with code 3000 (what OpenAI sends after `invalid_api_key`) counts as retryable in
  `RealtimeJSONSessionService`. It is harmless today, because the `error` event before it is already
  terminal. P0's error tests should pin that order.
- P2's hyphenless transcripts: vault matching now treats a code without its hyphens as the
  printed code ("XR7720" reaches a manual printing "XR-7720"), for codes outside the dictation
  vocabulary too. Recorded under [Plan EL](EL-equipment-identity.md#hyphenless-codes-2026-10-30).
