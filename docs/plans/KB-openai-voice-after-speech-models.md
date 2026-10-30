# Plan KB — The OpenAI Voice After 6 January 2027 (OpenAI removes every speech-endpoint model)

**Status:** 🚧 P0 built 2026-10-30 (headless) — a voice model a vendor has withdrawn now gets its own
reason (`CloudVoiceRejection.modelUnavailable`), latches that voice off for the session and is said
once, and a 403 naming a gone model no longer says "check the key"; `OpenAIVoiceRetirement` holds the
date and the Settings footer names it. Owner took the defaults for decisions 1–5 on 2026-10-30.
Decision 6 is settled: Plan KC has fixed the Realtime mode (the beta header and the `gpt-realtime` date)
and the OpenAI transcription move. Next: the decision 5 re-check on 2026-12-01, P1 (build it before that
check, merge by early December), P2 device pass.
Drafted 2026-10-29.
**Origin:** the provider-docs survey for Plan KA (model kinds across providers, PR 888) found OpenAI's 2026-10-01 deprecation of its text-to-speech models. KA records it
as owner decision 3, which says it needs a plan of its own before the end of 2026. This is that plan.
**Deadline:** the models stop answering on **2027-01-06**. Whatever this plan ships has to be in a
TestFlight and App Store build that wearers have installed before then, so the code PRs should merge
by early December 2026.
**Related:** Plan [ID](ID-ecosystem-review-hardening-bundle.md) item 5 (the OpenAI and xAI voices,
PR 814), Plan [HZ](HZ-direct-mode-sentence-streamed-speech.md) (streamed replies, synthesised
sentence by sentence), Plan JZ (Gemini as a cloud voice, PR 886, drafted), Plan KA (PR 888, drafted),
the 2026-10-05 support report that `CloudVoiceRejection` was built for.

---

## What OpenAI has said (checked against OpenAI's docs, 2026-10-29)

**The deprecations page, entry 2026-10-01 "Text-to-speech models":** the models are "deprecated and
will be removed from the API on January 6, 2027". OpenAI says it gave at least three months' notice
and names one replacement for all of them:

| Removed 2027-01-06 | Replacement OpenAI names |
|---|---|
| `tts-1` | `gpt-realtime-2.1-mini` |
| `tts-1-hd` | `gpt-realtime-2.1-mini` |
| `gpt-4o-mini-tts`, snapshot `gpt-4o-mini-tts-2025-03-20` | `gpt-realtime-2.1-mini` |
| `gpt-4o-mini-tts`, snapshot `gpt-4o-mini-tts-2025-12-15` | `gpt-realtime-2.1-mini` |

**Is `/v1/audio/speech` itself going away?** The deprecations page does not say so. It lists models,
not the endpoint. As documented today, though, **no model will be left on it**:

- The speech endpoint's API reference allows four `model` values: `tts-1`, `tts-1-hd`,
  `gpt-4o-mini-tts` and `gpt-4o-mini-tts-2025-12-15`. All four are on the removal list, and the
  reference carries the same deprecation notice.
- The text-to-speech guide says the replacement "isn't a supported model for /v1/audio/speech". It
  calls the move a change of workflow, not a drop-in model swap.
- The `gpt-realtime-2.1-mini` model page lists one endpoint, `v1/realtime`. It marks Speech
  generation (`v1/audio/speech`) "Not supported".
- The one other OpenAI model with audio output that isn't on a removal list, `gpt-audio-1.5`, lists
  only `v1/chat/completions`. It also marks the speech endpoint "Not supported".

So, unless OpenAI publishes a new speech model before then, `/v1/audio/speech` will have nothing to
serve after 2027-01-06. That later case is option (d) below.

**The replacement, as documented:**

- **`gpt-realtime-2.1-mini`** is "a distilled reasoning model for faster, lower-cost realtime voice
  interactions". It takes text, audio and images, and gives text and audio. It works on `v1/realtime`
  only, with a 128k context and 32k maximum output. It costs, per million tokens: text in $0.60
  (cached $0.06), text out $2.40, audio in $10, audio out $20. The model page lists no voices.
- **`gpt-audio-1.5`** is "the best voice model for audio in, audio out with Chat Completions". It
  costs, per million tokens: text in $2.50, text out $10, audio in $32, audio out $64.
- **Not documented anywhere checked:** a "read this text aloud" mode on the realtime models (the
  realtime guide describes conversations, tools and interruptions, not reading); how many audio
  tokens a minute of speech costs on `gpt-realtime-2.1-mini`; the maximum session length for the
  mini model; and its voice list. The plan quotes none of these as fact, and P3 measures them if
  option (a) is chosen.

## What the app does today

- **The request.** `CloudVoiceRequests.openAISpeech(text:apiKey:voice:)` sends a POST to the fixed
  address `https://api.openai.com/v1/audio/speech`. The body holds the fixed model
  `openAISpeechModel = "gpt-4o-mini-tts"`, one of 13 fixed voices (default `coral`) and
  `response_format: "mp3"`. The key travels only in `Authorization`. `AVAudioPlayer` plays the MP3
  as it plays ElevenLabs's.
- **The key.** `CloudVoiceCredentials.openAIKey` uses the first saved OpenAI model on
  `api.openai.com` that has a key, or else the legacy single key. A ChatGPT sign-in never counts.
- **The chain.** `TTSEngineSelector.chain` gives two orders. On Auto: ElevenLabs → OpenAI → xAI →
  Kokoro → iOS voice, each cloud voice only if it is ready (key, online, not latched, and allowed
  by the medical rule). "Cloud (OpenAI)" chosen: OpenAI → Kokoro → iOS voice. A chosen cloud voice
  never falls back to another paid cloud.
- **Whole replies.** `speakThroughEngineChain` calls `speakWithOpenAI` → `fetchOpenAIAudio`. A
  non-200 throws `CloudVoiceRequestRejected`, and the chain moves on to the next engine.
- **Streamed replies.** `StreamedReplyQueue` asks `synthesizeStreamedSentence` for each sentence,
  with up to `defaultPrefetchDepth = 2` sentences synthesising while one plays. Each one is its own
  POST through `fetchCloudAudio` → `fetchOpenAIAudio`. If one cloud voice fails twice in a row
  within a reply, `StreamedReplySchedule` demotes it for the rest of that reply.
- **Medical local-only.** `MedicalEgressGuard` takes every cloud voice out of the chain, and
  `fetchOpenAIAudio` checks `.openAISpeechSynthesis` again before it builds the request. Every call
  is a single POST, so there is no socket for `MedicalEgressCoordinator` to close.
- **Refusals.** `CloudVoiceRejection.classify(statusCode:body:)` reads an out-of-credit marker from
  the body first (`insufficient_quota` for OpenAI). After that it reads only the status: 401, 402
  or 403 count as `.refused`, and everything else is `nil`. Out of credit latches the voice off for
  the session. Both kinds give a banner once and one spoken line per episode
  (`CloudVoiceFallbackAnnouncer`). A `nil` rejection falls through without a word.

## What happens on 2027-01-06 if nothing ships

Nothing crashes and no reply is lost: the chain always ends in the iOS voice. What goes wrong is that
the wearer gets **a worse voice with no explanation**, and **every reply waits on a round trip that
can't succeed**.

1. **What OpenAI will answer is not known yet.** OpenAI usually answers a request for an unknown or
   removed model with **404 and the code `model_not_found`** ("The model … does not exist or you
   do not have access to it"). Some removed models have instead given a 400 `invalid_request_error`.
   This can't be checked before the date.
2. **On a 404 or 400, `classify` returns `nil`.** None of the out-of-credit markers matches, and
   neither status is 401, 402 or 403. So there is no banner, no spoken line and no latch:
   - **"Cloud (OpenAI)" chosen.** Every utterance tries OpenAI, waits for the refusal, then speaks
     with Kokoro (if the model is downloaded and compiled in) or the iOS voice. In a streamed reply
     the first two sentences, and their prefetch, each try OpenAI first. The schedule then demotes
     OpenAI for the rest of that reply, and the next reply starts over. Either way the wearer hears
     the fallback voice with nothing to say why. That is the situation the 2026-10-05 support report
     described, where the wearer went looking for a setting they never changed.
   - **Auto, with ElevenLabs set up.** Nothing changes, because ElevenLabs comes first and OpenAI is
     reached only when ElevenLabs fails.
   - **Auto, with OpenAI the first voice that is set up.** Every utterance pays one wasted round trip,
     and then xAI (if set up), Kokoro or the iOS voice speaks. Again, nothing is said.
3. **If OpenAI answers 403 instead** (it does this for a project without access to a model),
   `classify` returns `.refused`. The wearer is then told "OpenAI refused the voice request … Check
   the key and voice", which is untrue: the key is fine and the model is gone. `.refused` doesn't
   latch, so the wasted round trip is still paid on every reply.

P0 fixes this whatever the owner decides about the voice itself.

## Found in passing (not this plan's work)

These came up while reading the code for option (a). They have their own deadlines and need their
own fix or plan (decision 6):

- **OpenAI Realtime live mode is on the beta protocol.** `RealtimeConnectionConfiguration.request`
  sends `OpenAI-Beta: realtime=v1`, and `OpenAIRealtimeAdapter` (profile `openai.beta.v1`) uses the
  beta session and event shapes: `modalities`, `response.audio.delta`,
  `response.audio_transcript.delta`. The deprecations page lists the Realtime API beta header as
  **removed on 2026-05-12**. It was not checked live here. If that header is now refused, the OpenAI
  Realtime mode already fails today. Its template's default model `gpt-realtime` is also removed on
  **2027-01-20** (replacement `gpt-realtime-2.1`).
- **Transcription models.** `OpenAIDictationService` uses `gpt-4o-transcribe`, and the realtime
  adapter asks for `gpt-4o-mini-transcribe`. Both are removed on **2027-02-26** (OpenAI names
  `gpt-transcribe` or `gpt-live-transcribe` as replacements).

For this plan, the point is that **option (a) cannot reuse the app's realtime adapter as it is**. The
voice would need the current realtime protocol, which the live mode needs too.

---

## The options

### (a) Move the voice to `gpt-realtime-2.1-mini`

The voice stops making one POST per sentence and holds a **session**: a WebSocket to
`wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini`, with the same API key as a bearer
(the app is a native client, so the key is already on the phone and sent to OpenAI). The session is
configured for audio output only, with no tools, no microphone input, no turn detection, and
instructions to read the supplied text exactly. Each sentence goes in as one text item followed by
one response. That response is kept out of the session's conversation if the current protocol's
out-of-band responses work as documented; P3 checks this. The audio comes back as 24 kHz PCM16
deltas, and the app wraps them in a WAV header (the same wrapper Plan JZ needs for Gemini's L16
audio) so `AVAudioPlayer` can play them.

What changes:

- **What is said: the main risk.** A realtime model is a conversation model, not a reader. It may
  answer a sentence instead of reading it ("Want me to call him?" → "Sure!"), paraphrase, soften,
  translate, or refuse. Then the wearer would hear something the assistant never said, in a voice
  that sounds like the assistant. For a procedure step, a hazard warning or a dose, that is worse
  than a robotic voice. The only defence is to **check before playing**: buffer the whole sentence,
  compare the model's own output transcript with the text sent, and if they differ, throw the audio
  away (it is still paid for) and fall through to the next engine. Buffering a whole sentence is what
  happens today with the MP3, so this adds no delay. A pure `VerbatimSpeechCheck` (normalised word
  sequences, after `SpokenSymbolExpander`) is deterministic and testable. How often it trips is
  measurable only live.
- **Latency.** The first sentence of a reply pays for TLS, the WebSocket upgrade and a
  `session.update` round trip, unless the socket is opened when the reply starts streaming. Later
  sentences pay one response round trip on an open socket, with no new TLS, so they may be faster
  than a POST. It is a reasoning model, though: if the session doesn't let the app turn reasoning to
  its lowest setting, each sentence may also wait for it to think. P3 measures time to first audio.
- **The streamed-reply queue.** Today two sentences synthesise at once as two independent POSTs. A
  realtime session runs one response at a time, so a second `response.create` while one is active
  is an error. Synthesis therefore becomes serial on one socket, unless the app opens one socket per
  prefetch slot (two sessions, two setups). The queue's contract stays the same:
  `synthesizeStreamedSentence` still returns `.audio(Data)`. Behind it, a `RealtimeSpeechSession`
  queues sentences first in, first out, one in flight. The pure part is the queueing and the
  ordering, and it is testable with a fake socket.
- **Barge-in.** Today `stopSpeaking` cancels the task and the player, and an in-flight POST simply
  dies. With a session, the app must send `response.cancel` for the response in flight, drop its
  buffered audio, and leave the socket ready for the next reply (or close it). Responses are out of
  conversation, so there is no `conversation.item.truncate` to manage.
- **Locked phone.** A POST works while the app is in the background with audio active, and the
  locked-phone listener (tester round 4) relies on replies being spoken then. A WebSocket can stay
  open in the background only while the app keeps running. An idle socket held across a long lock
  will be dropped. The session must therefore open on demand, close after a short idle period
  (a P3 setting, default 20 s), reconnect without being noticed, and fall through to Kokoro
  or the iOS voice when a reconnect fails. A device check is owed.
- **Cost wording.** The picker footer's "paid from your OpenAI API credit" stays true. The price
  changes shape: audio out at $20 per million tokens, plus the text and instructions sent with every
  response (cached input is cheaper if the session is reused), plus any audio discarded by the
  verbatim check. No price appears in the app. P3 measures the cost of a minute of speech and the
  plan's status records it.
- **Medical local-only.** A new route, `openAIRealtimeSpeech`, gets its own registry row and owner
  (`TextToSpeechService`). It is blocked in the chain through `speechRoute`, and again when the
  socket opens. A held socket is new for a voice, so the voice session implements
  `MedicalEgressTeardown` and closes the moment local-only switches on, as the realtime live sessions
  do.
- **Disclosure.** It is the same vendor and the same data (the reply text), sent over a different
  route. The privacy copy says "realtime voice" instead of "speech endpoint", in the same PR.
- **Size.** The largest of the options: a new protocol client (the current realtime protocol, which
  the app doesn't speak yet), the verbatim check, the session lifecycle and a device pass.

**Variant (a′): `gpt-audio-1.5` through Chat Completions.** This keeps one POST per sentence, so the
streamed-reply queue, barge-in and locked-phone behaviour stay as they are. It has the same
verbatim risk, though, because it is also a conversation model. Its audio-out rate is 3.2 times the
realtime mini model's, and it is not the replacement OpenAI names. Not recommended. It is listed so
the decision is complete.

### (b) Retire the OpenAI voice

Remove the OpenAI engine from the voices on 2027-01-06. The OpenAI key stays for chat, dictation and
realtime, which are untouched.

- **"Cloud (OpenAI)" chosen.** A chosen cloud voice never falls back to another paid cloud, so the
  saved choice becomes the phone's voices: Kokoro if it is ready, otherwise the iOS voice
  (decision 2). The stored raw value `openAI` is still decoded, so an old backup or an iCloud
  restore can't fail to read. It is read as the on-device preference.
- **Auto.** OpenAI drops out of the cloud list, leaving ElevenLabs → xAI → (Gemini, if JZ has
  shipped) → Kokoro → iOS voice. A wearer on Auto whose OpenAI key was the only cloud voice set up
  now hears Kokoro or the iOS voice.
- **Told once, in plain words.** Both groups are told once: the wearers who chose OpenAI, and the
  wearers on Auto whose voice was OpenAI. The line is said after the next ordinary reply, using
  the existing once-per-episode announcer with its own token. A banner gives the same news. For
  example (wording to be localised; no plan letters):
  - Spoken: "By the way, OpenAI has stopped offering the voice I was using, so I'm now using the
    on-device voice. You can choose another voice in the app's Settings, under Connections, then
    Services and Integrations." On Auto with another cloud voice set up, "the on-device voice"
    becomes "another voice", as `CloudVoiceNotice.nextIsCloud` already does.
  - Banner: "OpenAI no longer offers its voice, so replies use the on-device voice. Choose another
    voice in Settings › Connections › Services & Integrations."
- **Before the date.** From the build that carries P0, the picker footer for "Cloud (OpenAI)" says
  that OpenAI is retiring the voice on 6 January 2027, with the date formatted for the phone's
  locale. Nothing is spoken before the date (decision 4).
- **After the date.** "Cloud (OpenAI)" and its voice picker leave Settings, and the
  `openAISpeechSynthesis` route, its request builder and the stored voice are removed. The
  registry, the privacy copy and the processing summary are updated in the same PR. The system
  prompt's list of voices is updated too, so the assistant doesn't offer a voice that no longer
  exists.
- **Size.** The smallest option, and entirely headless.

### (c) Route the OpenAI voice through another provider's speech endpoint

An OpenAI key works only with OpenAI, so any other route needs **another account**.

- **Azure OpenAI** hosts the same voices (`alloy`, `coral` and the rest) behind its own deployments
  and retirement schedule. It is the only way to keep the *sound*. It needs an Azure resource, an
  endpoint, a deployment name and an Azure key: a different setup that few wearers have. Azure's
  retirement dates for these models were not checked here. Adopting it would be a plan of its own.
- **The voices the app already has** (ElevenLabs, xAI, and Gemini once JZ ships) are already
  "another provider's speech endpoint". Routing the OpenAI choice to one of them would move the
  wearer to a different paid account they never chose, which breaks the never-another-paid-cloud
  rule. Pointing them to these voices is what option (b)'s spoken line and banner already do.

Not recommended, beyond (b)'s pointer.

### (d) OpenAI publishes a new speech-endpoint model before the date

If one appears on `/v1/audio/speech`, the fix is a change to the `openAISpeechModel` constant plus a
request-shape test, and (b)'s retirement doesn't happen. P0 doesn't stand in the way of this.
Someone has to look: decision 5 sets when.

---

## Recommendation

**P0 now, then (b), retiring on the date. Leave (a) to a plan of its own, written only if a live
check shows the realtime model reads text verbatim.** The reasoning:

- The named replacement is a conversation model. A voice that might answer, soften or rephrase the
  reply it is reading isn't a voice the app can put in front of a procedure step or a hazard
  warning, even with a check before playback. Every tripped check is audio that was paid for and
  thrown away.
- The wearer loses little. The app has xAI, ElevenLabs and Kokoro today, and the Gemini voice is
  drafted. A wearer who chose OpenAI is told once what happened and where to choose again.
- P0 and (b) are deterministic and headless, so they can merge well before the date. (a) needs a
  protocol client the app doesn't have (see "Found in passing") and a device pass, which is too
  tight for 2027-01-06.

## Owner decisions (defaults in bold)

1. **Which option.** **(b) retire, on the date. (a) only as a later, separate plan, written if a live
   check of verbatim reading passes. (d) is taken if OpenAI publishes a new speech model first.**
   Alternatives: (a) now, (a′), (c) through Azure.
2. **What a saved "Cloud (OpenAI)" choice becomes.** **The phone's voices (Kokoro, then the iOS
   voice), never another paid cloud, and the wearer is told once.** Alternative: Auto, which would
   move them to whichever other cloud voice is set up.
3. **When the switch happens.** **At 2027-01-06 00:00 UTC by the phone's clock, or at the first
   model-gone answer from OpenAI, whichever comes first.** Before that, the voice is used as today.
   Alternative: on the answer only. That never retires early if OpenAI extends the date, but it pays
   one wasted round trip on the day and relies on P0's classification. The default retires early
   only if OpenAI extends after the build ships, and (d) or a later build would reverse it.
4. **Advance notice.** **Written only: the picker footer from P0's release, and nothing spoken before
   the date.** Alternative: one spoken line in the last two weeks to wearers whose voice is OpenAI.
5. **Watching for (d).** **The deprecations page and the speech reference are checked again on
   2026-12-01, before the build that carries P1 is cut, and the result goes in this plan's status.**
6. **The two items found in passing.** **Each gets its own fix or plan, starting with the live check
   of whether the OpenAI Realtime beta header still works, because that mode may already be failing
   today.** They are not folded into this plan.

---

## Phases

### P0 — Say why a cloud voice stopped, and know the date (headless; applies to every cloud voice)

1. **`CloudVoiceRejection.modelUnavailable`.** It is classified **before** the status, from a short
   list of body markers: `model_not_found`, plus OpenAI's "does not exist" and "has been
   deprecated" phrasings. It covers any vendor whose body names them, so the planned Gemini voice
   and xAI benefit too. A 404 or 400 without a marker stays `nil`, as today.
   - As built, the two phrasings count only after the words "the model": a bad voice id can say
     "does not exist" too, and that is the wearer's to fix, so it must not latch the voice off.
   - As built, the latch is its own set (`modelUnavailable`), not `quotaExhausted`, so the log stays
     true and P1 can read that OpenAI said the model is gone. Both clear when the key or voice
     changes.
   - Like `.outOfCredit`, it latches that voice off for the session, so later replies don't pay the
     round trip.
   - It is announced once per episode with the existing announcer, using its own token
     (`openAI.modelUnavailable`), and gives a banner once.
   - New wording, generic with the vendor name: "By the way, {vendor} no longer offers the voice
     model I was using, so I'm using {the built-in voice | another voice}. You can choose another
     voice in the app's Settings, under Connections, then Services and Integrations."
   - A 403 whose body carries a model-gone marker is read as `.modelUnavailable`, never `.refused`.
     That fixes the untrue "check the key" line.
2. **`OpenAIVoiceRetirement`**, a pure value. `retirementInstant` is 2027-01-06 00:00 UTC.
   `phase(now:)` returns `.announced(daysLeft:)` or `.retired`, and the clock is injected. Nothing
   reads it for behaviour yet. P1 does.
3. **Picker footer.** While the phase is `.announced`, "Cloud (OpenAI)"'s detail adds that OpenAI is
   retiring the voice on a locale-formatted date. A new localised string; no plan letters.
4. **Tests.**
   - `CloudVoiceFallbackTests`: each marker with 400, 403 and 404; a marker-free 404 stays `nil`; an
     out-of-credit marker still wins; the new rejection latches and is announced once per episode
     and per engine; and an older stored token still decodes.
   - `OpenAIVoiceRetirementTests`: a minute before the instant, at it, after it, and a time zone
     ahead of UTC.
   - A footer string test that injects the date.

### P1 — Retire the OpenAI voice (decision 1 = b; headless; merge by early December)

1. `TTSEngineSelector.chain` drops `.openAI` once `OpenAIVoiceRetirement` says `.retired`, or once
   P0's latch has seen `.modelUnavailable` from OpenAI (decision 3). Auto's order without it is
   ElevenLabs → xAI → (Gemini) → Kokoro → iOS. A saved `.openAI` preference is read as `.kokoro`
   (decision 2), and the raw value still decodes.
2. **Told once.** A `VoiceRetirementNotice` (pure: the saved preference, whether OpenAI headed the
   last chain, and whether it was already said) decides who hears the line. It is spoken after the
   next plain reply and shown as a banner, with a token separate from P0's so a wearer isn't told
   twice.
3. After the date, Settings hides "Cloud (OpenAI)" and its voice picker. The stored voice
   (`openAITTSVoice`) is cleared on first launch after the date.
4. **A separate clean-up PR, after the date:** the `openAISpeechSynthesis` route,
   `CloudVoiceRequests.openAISpeech`, `fetchOpenAIAudio`, `speakWithOpenAI` and the medical canary's
   OpenAI speech case are removed. Until then, the date gate keeps them unreachable, so a phone whose clock is wrong
   still has the fallback. The registry, the guard tests, `PrivacyInfo.xcprivacy`'s comment, the
   privacy page, the processing summary and the system prompt's voice list change in that same PR.
5. **Tests.**
   - The chain before and after the date, for every preference, with and without Kokoro.
   - The latch path, where the answer arrives before the date.
   - Preference decoding.
   - `VoiceRetirementNotice` across its inputs: chosen versus Auto, already said, and another cloud
     voice next.
   - The settings view model hiding the option.

### P2 — Device pass (after P1 merges)

- On a phone with its clock set past the date: a wearer who had chosen OpenAI hears the line once,
  after an ordinary reply and not after an alert, and sees the banner once. A locked-phone reply
  still speaks.
- On the day itself, a live check of what OpenAI actually answers, recorded here. If it isn't one of
  P0's markers, add it.

### P3 — Only if decision 1 = (a): the realtime voice, as its own plan

This phase doesn't start in this plan. It is listed so the work is visible:

1. A pure `VerbatimSpeechCheck`.
2. A `RealtimeSpeechSession` (queueing, cancel and idle close) against a fake socket, on the current
   realtime protocol, shared with the live-mode fix from decision 6.
3. The `openAIRealtimeSpeech` route with `MedicalEgressTeardown`.
4. The PCM16-to-WAV wrapper shared with JZ.
5. A live measurement: time to first audio, how often the verbatim check trips over a fixed set of
   replies (questions, steps, numbers, warnings), the cost of a minute of speech, and the idle drop
   while locked.

## Out of scope

- The OpenAI Realtime live mode and the OpenAI transcription models (decision 6).
- Chat models from OpenAI, which aren't affected by this deprecation.
- Any change to ElevenLabs, xAI, Kokoro or the iOS voice, beyond P0's shared rejection.
