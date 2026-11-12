# Plan LO — Spoken Manners (end on the answer, say it again differently, answer in their language)

**Status:** 📝 Drafted 2026-11-12. Nothing built. The [decisions](#decisions-for-greig-open) below are
recommendations and are still open.
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
  ([decision 2](#decisions-for-greig-open)).
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

## Decisions for Greig (open)

1. **Where §1 lives.** *Recommended:* beside `appGuide`, so it applies to custom presets too, as the app guide
   does. Alternative: shipped presets only, leaving a wearer's own prompt untouched.
2. **Reply language versus the voice.** Answering in Spanish through an English ElevenLabs voice sounds wrong.
   *Recommended:* the rule applies when the active voice engine can speak the language (the iOS voice always can;
   a cloud voice per its own list), and otherwise answers in the app's language with the original words quoted.
   Alternative: always follow the wearer's language and let the voice be what it is.
3. **Search recency on backends without a filter** (DuckDuckGo HTML). *Recommended:* ignore it silently.
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
