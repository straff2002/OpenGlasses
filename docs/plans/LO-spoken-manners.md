# Plan LO — Spoken Manners (end on the answer, say it again differently, answer in their language)

**Status:** 🚧 Built 2026-11-12 (P0–P1); P2 device pass owed. The three [decisions](#decisions-for-greig-taken-2026-11-12-as-recommended)
were taken 2026-11-12, as recommended. See [As built](#as-built-2026-11-12).
**Track:** Everyday assistant — how a spoken reply is shaped. Direct mode, Gemini Live and OpenAI Realtime.
**Builds on:** `SystemPromptBuilder` (`appGuide`, `routingRules`, the shared head both `LLMService.buildSystemPrompt`
and `RealtimeSessionManager` append), Plan [KP](KP-answers-you-can-act-on.md) (`FollowUpTail`, `FollowUpPrompt`: the
follow-up questions that go to the lens and the phone, not the voice), Plan [KZ](KZ-provider-web-search.md)
(`ProviderSearchPolicy`'s spoken-source rule), `WebSearchTool`, `CalculatorTool` (`calculate`), `UnitConversionTool`
(`convert_units`), `DomainCalcTool` (`domain_calc`).
**Sits beside:** Plan [LN](LN-memory-manners.md) (memory manners), Plan [LP](LP-agent-manners.md) (how Agent Mode talks
while it works), Plan [LA](LA-quiet-after-actions.md) (a tone instead of words after an action).

---

## Trigger

A review of how other voice and chat assistants instruct their models turned up a handful of habits that matter
more when every word is spoken through the glasses than when it is read on a screen. Ours does the opposite on
several of them, because the default prompt was written for a chat window:

- It asks the model to end with offers: "offer to break the topic into parts", "Want me to explain more about
  Y?", and "after reading text from an image, offer to copy it to clipboard or translate it". On the glasses a
  trailing question costs the wearer a turn to decline, and Plan KP already puts follow-ups on the lens and the
  phone, where they cost nothing.
- Nothing says what to do with a question asked twice. On voice that almost always means the answer didn't
  land (noise, a long answer, a misheard word), so the same answer again is the wrong reply.
- Nothing says to answer in the language the wearer spoke. Only the compact on-device vision prompt has an
  "Answer in …" line.
- Decimal and unit arithmetic is answered from the model's head, though `calculate` and `convert_units` exist.
  For a technician reading out a superheat or a duct size, a wrong decimal is a wrong job.
- Our own `web_search` returns "[1] url" lists and says nothing about naming the source aloud. The provider's
  search has the right rule (`ProviderSearchPolicy`: "name the source in words"); ours doesn't.
- "The image" leaks into replies ("In the image I can see…") because every prompt calls it that.

## Outcome

- "How does a heat pump defrost?" → a 3–4 sentence answer that ends on its last fact. No "Want me to explain
  more?". On the Display and the phone the follow-up buttons appear as today.
- "Read this." (a menu) → the text, translated if foreign. No "Shall I copy it to the clipboard?".
- "What time does the pharmacy close?" … "What time does the pharmacy close?" → "Six tonight." The second
  answer is shorter, not "As I said, …".
- A question asked in Spanish → answered in Spanish, by a Spanish voice where one is set up
  ([decision 2](#decisions-for-greig-taken-2026-11-12-as-recommended)).
- "What's 18.5 percent of 2,340?" → `calculate`, then the number.
- "Who won the match last night?" → a search with a recency hint, then "Canterbury, 24 to 19, according to
  Stuff." One source, said in words.
- "What's that?" with the camera on a cluttered bench → "I'm not sure which thing you mean — the grey box on
  the left looks like a contactor." Not a list of everything in view, and "what you're looking at", never "the
  image".
- "That's wrong, it's 240 volts." when the model is confident it isn't → it says why, once, and allows it
  may be wrong. It doesn't simply agree.

## What exists, and what doesn't

**Exists (verified against `main` at 8705e969c):**
- `Config.defaultSystemPrompt(device:)` (`Utils/Config.swift:963`): RESPONSE STYLE, CONTEXT (with "For very
  complex questions, offer to break the topic into parts"), VISION & CAMERA (with "After reading text from an
  image, offer to copy it to clipboard or translate it"), KNOWLEDGE ("Answer confidently from your training
  knowledge"), BREVITY ("Complex topics: 4-6 sentences, offer to continue (e.g., 'Want me to explain more about
  Y?')"), SELF-AWARENESS, ACTION SAFETY, ERROR RECOVERY. **A preset the wearer wrote or edited replaces all of
  it** (`Config.systemPrompt(device:)` returns it verbatim).
- `LLMService.buildSystemPrompt` re-adds a VISION & CAMERA block, same offer line included
  (`LLMService.swift:681–692`), when a custom prompt mentions neither vision nor camera, then appends
  `SystemPromptBuilder.appGuide` **unconditionally, in the stable head** (`:699`). `RealtimeSessionManager` appends
  the same `appGuide` (`:1075`) and `routingRules` (`:1100`). So a builder section added beside `appGuide` reaches
  every mode and every preset, including a wearer's own.
- `SystemPromptBuilder.routingRules(toolNames:hiddenTrades:)` has one tool-routing rule (`health_check`), added only
  when that tool is offered.
- `FollowUpPrompt.clauseForPrompt()` / `FollowUpTail` (Plan KP): cloud prompts ask for up to a few short follow-up
  questions in a stripped tail; they become lens and phone buttons and are not spoken.
- `WebSearchTool` (`web_search`): one `query` parameter, no recency; results end in a numbered URL list
  (`WebSearchTool.swift:123, 191, 255, 321`). Its description covers verifying current events and re-checking after
  a correction.
- `ProviderSearchPolicy` (`:313`) tells the model to name a source in words when the provider searched.
- `Config.compactVisionTurnPrompt` adds "Answer in <language>." from `preferredLanguageCode`; no other prompt does.

**Doesn't exist:** any rule on closers, repeated questions, length mirroring, reply language, arithmetic routing,
spoken sources for our own search, ambiguous camera views, or holding a position under correction.

## Design

### 1 · One section of spoken manners (`SystemPromptBuilder.spokenManners`, pure)

A fixed block appended next to `appGuide` in `buildSystemPrompt` and `RealtimeSessionManager`, with a short form
beside `onDeviceAppGuide` for the on-device prompts. Fixed text, so the cacheable head doesn't move. In our own
words:

- End on the answer. Don't close with an offer or a question unless you can't go on without the answer.
  Follow-ups go in the follow-up tail when one is asked for, never in the spoken reply.
- A question asked again means the first answer didn't land: answer it shorter or another way. Never "as I said".
- Match the wearer's length: a short question gets a short answer. When they're venting rather than asking,
  acknowledge it; don't fix it.
- Answer in the language the wearer spoke, unless they ask for another.
- When you're confident a correction is wrong, say why once, and allow you could be mistaken. Don't agree just
  to agree; don't argue twice.
- Speech recognition is imperfect. For a question, answer the likeliest meaning. Before a message, a call or
  home control from words that don't quite make sense, ask.

### 2 · The default prompt loses its offers

`Config.defaultSystemPrompt` and the re-added VISION & CAMERA block lose the three offer lines. BREVITY's
"complex topics" line becomes "4–6 sentences; stop at a natural break". Shipped presets only: a wearer's own
prompt is never edited, and §1 reaches it anyway.

### 3 · Arithmetic goes to a tool (`routingRules`)

A rule, added only when `calculate` (and/or `convert_units`) is offered: any arithmetic with decimals, percentages
or more than two operands, and every unit conversion, goes through the tool; say the result, not the working.
`domain_calc` keeps its own description.

### 4 · Our own search speaks like the provider's (`WebSearchTool`)

- A `recency` parameter (`day`, `week`, `month`, `year`), mapped to each backend's own filter where it has one and
  ignored where it doesn't. The description says: put the time in `recency`, never a date in the query, and read
  "this week" against today's date.
- Description gains when to search (news, sport, weather, prices, opening hours, anything local, anything that
  changes) and when not (common knowledge, small talk, maths, translation).
- The result ends with **one** source as a name the model can say ("Source: Stuff (stuff.co.nz)"), and the URL list
  moves under a "for the phone" line the model is told not to read out. The phone still shows every link.

### 5 · The camera in the wearer's words

The VISION blocks say "what you're looking at" rather than "the image", and add: when it isn't clear what they
mean, say so and give one specific guess, rather than describing everything in view. The `hasImage` block
(`LLMService.swift`, "This turn includes an image…") and the realtime vision instruction get the same line.

## Decisions for Greig (taken 2026-11-12, as recommended)

1. **Where §1 lives.** *Taken 2026-11-12:* beside `appGuide`. *Recommended:* beside `appGuide`, so it applies to custom presets too, as the app guide
   does. Alternative: shipped presets only, leaving a wearer's own prompt untouched.
2. **Reply language versus the voice.** *Taken 2026-11-12:* the rule follows the voice. Answering in Spanish through an English ElevenLabs voice sounds wrong.
   *Recommended:* the rule applies when the active voice engine can speak the language (the iOS voice always can;
   a cloud voice per its own list), and otherwise answers in the app's language with the original words quoted.
   Alternative: always follow the wearer's language and let the voice be what it is.
3. **Search recency on backends without a filter** (DuckDuckGo HTML). *Taken 2026-11-12:* ignored silently.
   *Recommended:* ignore it silently.
   Alternative: append the year to the query for those only.

## Phases (one PR)

### P0 — the pure core (headless)
`SystemPromptBuilder.spokenManners` and its short form; the calculator routing rule; `WebSearchTool` result
formatting (one sayable source) and the `recency` → backend mapping as pure functions. Tests: the block is in the
Direct, realtime and on-device prompts, including with a custom preset; the head is byte-identical turn to turn;
the short form fits the on-device budget; the routing rule appears only with `calculate` offered; the
source line for each backend's result shape; recency maps per backend and is dropped where unsupported.

### P1 — the prompts edited (headless)
The three offer lines removed from the shipped prompt and the re-added vision block; BREVITY reworded; "what you're
looking at" and the ambiguity line in every vision block. Tests: no shipped prompt contains "Want me to" or "offer
to"; `FollowUpTail` still parses a reply produced under the new prompt.

### P2 — device pass (owed)
Spoken checks on the glasses: a long explanation ends without an offer; a repeated question gets a shorter
answer; a Spanish question in each voice engine (decision 2); "18.5 percent of 2,340"; a sports score with one
named source; a cluttered bench.

## As built (2026-11-12)

P0 and P1 in one change; nothing user-facing on screen, no new UI strings.

- **§1** `SystemPromptBuilder.spokenManners(replyLanguage:)`: a `SPOKEN REPLIES:` block of six rules (end on the
  answer, follow-ups only in the `FOLLOW-UPS` tail; a repeated question answered shorter or another way, never "as I
  said"; match the user's length and acknowledge venting; the reply-language line; hold a confident position once
  under correction and allow being wrong; answer the likeliest meaning of a question, but ask before a message, a call
  or home control from words that don't quite make sense). Appended right after `appGuide` in
  `LLMService.buildSystemPrompt` (stable head, its own "spoken manners" block in the support trace) and in
  `RealtimeSessionManager.buildSystemInstruction`, so a preset the user wrote carries it too.
  `SystemPromptBuilder.onDeviceSpokenManners(replyLanguage:)` is the two-line form: a new `spokenManners` input and
  "spoken manners (on-device)" block in `AppleOnDeviceInstructions` (Apple on-device and the per-minute condensed
  cloud prompt), and in `leanOnDevicePrompt` (the local-model prompt) through `compactSpokenManners`.
- **Decision 2** `ReplyLanguagePolicy` (pure, plus one settings reader): `languages(of:)` per voice — the iOS
  voice, OpenAI (`gpt-4o-mini-tts`), xAI (`"language": "auto"`), Gemini speech and ElevenLabs
  (`TextToSpeechService.elevenLabsModelID`, now a named constant: `eleven_flash_v2_5`, multilingual; an
  English-only model id would limit it) speak any language, as do the live models; Kokoro speaks the languages of
  its bundle's lexicons (`KokoroModelBundle.spokenLanguages`: English and Chinese). `clause(for:appLanguageCode:)`
  gives `.followUser` or `.limited(speaks:fallback:)`, the fallback being the app's language when the voice speaks
  it, else the voice's first. `expectedEngine(preference:configuredCloudVoices:kokoroReady:)` reads the voice from
  the settings alone — a chosen voice is that voice; Auto is the first cloud voice with a credential, else Kokoro
  when its model is installed, else the iOS voice — so the clause in the cached head moves only when a voice
  setting does, never with the network or a quota latch.
- **§2** The shipped prompt's VISION & CAMERA rules are one copy, `Config.visionAndCameraRules`, used by
  `defaultSystemPrompt` and by the block `buildSystemPrompt` re-adds to a prompt that never mentions the camera.
  The three offer lines are gone; BREVITY's complex-topics line reads "4–6 sentences; stop at a natural break".
- **§3** `routingRules` adds one rule when `calculate` and/or `convert_units` is offered: arithmetic with decimals,
  percentages or more than two numbers through `calculate`, every unit conversion through `convert_units`, say the
  result, not the working.
- **§4** `WebSearchTool`: an optional `recency` (`day`/`week`/`month`/`year`, an enum in the schema) and a
  description saying when to search and when not, to put the time in `recency` and never a date in the query, to
  read "this week" against today's date, and to name the one source in words. `WebSearchRecency.filter(for:)` maps
  it to each backend's own filter: Perplexity `search_recency_filter`, Tavily (keyed and keyless) `time_range`, Brave
  `freshness` (`pd`/`pw`/`pm`/`py`), SearXNG `time_range`; DuckDuckGo none, so it is dropped (decision 3).
  `WebSearchResultFormat.compose` ends every result with the links under "For the phone — don't read these out:"
  on the `Sources: [1] …` line `ProviderSearchEvidence.ourToolSources` already reads (the phone's link list is
  unchanged), then one `Source: Stuff (stuff.co.nz)` line. The name comes from the service when it gives one
  (Brave `profile.name`, DuckDuckGo `AbstractSource`), else from the top result's title suffix only when it matches
  the address ("… | Stuff" at stuff.co.nz), else the line is the address alone ("Source: stuff.co.nz").
- **§5** "What you're looking at" and the ambiguity line (`SystemPromptBuilder.visionWordingLine`,
  `.visionAmbiguityLine`) in the shipped VISION & CAMERA rules, the `hasImage` VISION INPUT block (which now says
  "a photo … of what they are looking at" and reads text "visible in what they are looking at") and the live
  VISION block (which no longer says "describe what you observe").
- **Tests:** `SpokenMannersTests` (the block in Direct, lean on-device, Apple on-device, condensed and live prompts,
  with a custom preset; the head byte-identical across two turns; the short form two lines and within the
  on-device budget; the arithmetic rule only with its tools; the policy per voice, app language and setting; no
  shipped prompt with "Want me to" or "offer to"; BREVITY; every vision block; `FollowUpTail` parsing a reply under
  the new prompt) and `WebSearchSpokenSourceTests` (recency per backend and dropped for DuckDuckGo, the Brave and
  SearXNG addresses, the schema and description, the source line for each backend's result shape). One existing
  assertion moved deliberately: `SystemPromptBuilderTests.testNoRoutingRulesWithoutGatedTools` used `calculate` as
  its example of an ungated tool.

**Verified 2026-11-12:** the new and related classes (667 tests) and the full unit suite (16,689 tests, 16 skipped,
0 failures) on the simulator; a Release build; the privacy-logging scan and the contract tests. Owed: P2 on the
glasses.

**Deviations from the plan**

- More shipped text lost its offers than the three lines named, because the P1 test covers every shipped prompt:
  the Concise preset ("offer to elaborate" → "say the key point and stop there"), Reading Assistant ("Offer to
  elaborate: 'Want me to summarize?'…" removed), Museum Guide (follow-up questions → one sentence about a related
  piece), Nature Guide ("Want to know about its migration pattern?" → one deeper detail), the Chinese default
  ("要我详细说说吗？" → end at a natural point), the Reading Assistant live mode ("Offer to summarize" → "Summarize
  long text when asked"), and the default agent soul's two lines. Saved copies of a shipped preset refresh from
  the template as before; a preset the user edited is untouched.
- The local-model prompt (`leanOnDevicePrompt`) carries the full app guide but the **short** manners: it is the
  2B-model path, and the short form is what the plan wrote for on-device.
- The lean one-line cloud prompt and the compact on-device photo prompt are unchanged: they carry no app guide,
  already forbid follow-up questions, and never said "the image".
- The prompt says "the user", not "the wearer", as the rest of the prompt does (and the phone-only build has no
  wearer).
- The backend without a filter is DuckDuckGo's instant-answer API (what the code calls), not its HTML page.
- §3 adds a clause, only when `domain_calc` is also offered, that a trade calculation it covers still goes to it, so
  the new rule does not pull superheat or a duct size away from `domain_calc`.
- The reply-language clause reads the voice setting, not the engine that ends up speaking a given sentence: a
  chosen cloud voice that falls back to Kokoro offline keeps the "follow the user" line (by design, so the head
  does not move). The iOS voice is counted as speaking every language (decision 2); the app picks one system voice
  per the saved choice or the device languages, so a Spanish reply through an English system voice is still
  possible — worth a look in P2.

## Risks

- **A wearer liked the offers.** They're still on the lens and the phone; the spoken reply just stops sooner.
- **Language detection is the recogniser's.** A wearer whose recogniser is set to English and who says one
  Spanish sentence gets an English transcript; the rule can only follow what was transcribed.
- **Prompt length.** §1 is six lines in the stable head, cached after the first turn. The on-device short form is
  two.

## Out of scope

- Meeting action items with owners and items resolved later in the meeting (`MeetingSummaryTool` is a heuristic
  over captions; owners need the diarization `SpeakerRegistry`): worth its own plan.
- Drafting messages in the wearer's own style: Plan [LP](LP-agent-manners.md) §6.
- How Agent Mode narrates multi-step work: Plan [LP](LP-agent-manners.md).
