# Plan KP — Answers You Can Act On, on the Display (the whole answer in pages, actions under it, a band check, a preview to scale, captions kept)

**Status:** 🚧 P0–P4 built (headless; P3 lessons 1–3, lesson 4 waits for JV),
P0–P2 2026-11-06, P3 and P4 2026-11-07: the pure core (`HUDAnswerPager` and
`HUDAnswerPage`, `PageTurnGate`, `HUDAnswerCardBuilder`, `FollowUpTail`), then the card wired onto the
glasses (`HUDAnswerTurn`, `HUDAnswerCard`, `frameRevision`, the voice words, the page taps, the mirror's
keys), then what the wearer gets while another app has the Display (`DisplayAvailability`, the held
card, the busy hint), then suggested follow-ups (`FollowUpPrompt`, the tail taken off everywhere, the
streamer's hold), then the band check (`BandPractice`, `BandPracticeSession`, the phone page, the
report's **Band check** section), then the preview to scale (`HUDCanvasScale`, both lenses at their
shape, token sizes marked as estimates); P5 next, P6 device pass owed. The
owner took all nine recommended decisions on 2026-11-06 ("build out the plan"). Drafted 2026-11-06 from
the owner's question. Supersedes Plan [IB](IB-paged-hud-answers.md) (paged HUD answers), whose design is
folded in here as §1–§2 and P0–P1. Revised the same day: §8 and P1b cover what the wearer gets while
another app has the Display.
**Track:** Display (Meta Ray-Ban Display through `MWDATDisplay`; Even G2 through Plan AH's backend; the
web mirror of Plan BP). Every phase except P6 is headless. Phone first still holds: everything a card
offers is also on the phone.
**Related:** Plan [IB](IB-paged-hud-answers.md) (superseded), Plans [X](X-interactive-hud-now-next-tasks.md)
and [Y](Y-interactive-hud-launcher.md) (the interactive HUD, `HUDRouter`, the launcher's Quick
Actions), Plan [AG](teleprompter.md) (`TeleprompterPaginator`), Plan [AH](even-display-backend.md) (the
Even backend), Plan [BP](BP-web-hud-mirror.md) (the web mirror and its P3 reachability), Plan
[BY](BY-live-translation-captions.md) (translated captions), Plan [IA](IA-agent-choice-questions.md)
(choice questions, which page here once this lands), Plan [JV](JV-dat-experimental-testflight-lane.md)
P2 (glasses gestures through Inputs, TestFlight only), Plan [GJ](GJ-remappable-temple-gestures.md)
(temple taps), Plan [KK](KK-conversation-timeline.md) (turns), Plan
[HZ](HZ-direct-mode-sentence-streamed-speech.md) (sentence-streamed speech).

---

## Why

The owner asked whether the Display shows the current answer with replies and quick actions under it. It
does not:

- **The answer is cut, and shown a sentence at a time.** `TextToSpeechService` mirrors what it speaks to
  the HUD: `speak` calls `glassesDisplay?.showText(text, flashWhileInteractive: true)`, and so does
  `playStreamedSentence`, once per streamed sentence. `GlassesDisplayService.present` condenses every
  body to `HUDTextShaper.maxBodyLength` (120) and records nothing about what it dropped. So the wearer
  sees each sentence replace the last, each cut at 120 characters, with no sign that there was more.
- **Nothing can be done with an answer from the glasses.** Quick Actions exist only inside the Plan Y
  launcher, a separate menu. No button sits under an answer: no repeat, no "tell me more", no save, no
  send, no suggested next question.
- **The band is assumed, not checked.** Every interactive HUD screen relies on the Neural Band moving
  focus freely across a list of buttons and firing `onClick`. Plans X and Y record that as an assumption.
  Nobody on the team has Display hardware, and no screen exists that a tester could run to settle it.
- **The phone's preview is not to scale.** `HUDPreviewView` draws a `FlexBox` on a dark "glass" panel at
  the phone's width. It cannot tell anyone whether a page of text fits the 600 × 600 Display or the
  576 × 288 Even panel.
- **Captions are gone when they stop.** `AmbientCaptionService.captionHistory` is in memory, capped at 50
  entries and emptied when captions stop. A conversation captioned or translated on the Display can't be
  read back or shared afterwards.

## What exists, and what doesn't

- **The interactive HUD.** `GlassesDisplayService.present(screen:onSelect:)` renders a `HUDScreen`
  (title, `HUDLine`s, `HUDItem` buttons with `id`, `label`, `icon`, `style` and an action) and routes a
  band selection back by item id. `HUDRouter` keeps a screen stack (`push`, `pop`, `dismiss`,
  `openLauncher`) and parses voice commands through `HUDVoiceCommand` (`complete`, `skip`, `back`,
  `briefing`). While a screen is interactive, ambient producers are suppressed and AI replies flash over
  it for five seconds (`flashWhileInteractive`).
- **The pager.** `TeleprompterPaginator` windows text into HUD-sized pages with per-backend `Geometry`
  (`raybanDisplay` 4 lines × 32 characters, `evenG2` 3 × 40). Only the teleprompter uses it.
- **Stable DAT gives buttons, not gestures.** On a store build the band reaches the app only as an
  `onClick` on a rendered button; the Display itself moves focus between buttons. Plan IB's input table
  assumed band swipes reach `HUDRouter`. They don't, outside JV's TestFlight lane, which subscribes to
  `MWDATInputs` (`nav(direction:)`, `select`, `back`). KP pages with buttons, so it works on a store
  build, and lets JV add swipes later.
- **The actions already have tools.** `save_note` saves a note. `send_via` sends by WhatsApp, Telegram or
  email. Speaking again is `TextToSpeechService` with the answer's text. "Tell me more" is an ordinary
  next turn.
- **Temple taps.** `TempleAction` (`startTalking`, `hangUp`, `mute`, `readDigest`, `quickAction`, …)
  through `TempleActionResolver` and `TempleTapSettingsView`. It has no page action.
- **The web mirror.** `WebHUDRenderer` renders the live HUD as a 600 × 600 page with D-pad navigation;
  `WebHUDMirrorServer` serves it on the LAN. Registering it on the glasses needs a public HTTPS address,
  which is BP P3's open question.
- **Store rules.** A new on-disk store registers with the data-store registry so subject erasure reaches
  it (the `DataStoreRegistry` guard tests enforce this). `Config.hipaaMode` already hard-disables
  speaker diarisation; KP holds caption sessions to the same line (§7).

## Design

### 1 · The answer card (pages)

A **turn's answer** is collected into one card instead of being shown a sentence at a time. The card
opens when the turn's first sentence is shown and closes when the turn ends. Sentences append to it as
they are spoken. P1 settles which identifier ties sentences to a turn: KK's turn id if it reaches the
speech path, otherwise a `HUDAnswerTurn` the Direct-mode loop opens and closes around each reply.

`HUDAnswerPager` (pure, from IB):

```swift
struct HUDAnswerPage: Equatable { let body: String; let index: Int; let count: Int }
enum HUDAnswerPager {
    static func pages(for text: String, geometry: TeleprompterPaginator.Geometry,
                      maxPages: Int = 8) -> [HUDAnswerPage]
}
```

It walks `TeleprompterPaginator.window` across the answer, one window per page, so wrapping and blank
lines are the teleprompter's. A page break never splits a word and prefers a sentence end in a page's
last line. One footer line on each page of a multi-page answer holds "1/3". A single-page answer has no
footer. Past `maxPages`, the last page ends "… more on phone". Geometry comes from the active backend.

While the answer is still being spoken, page 1 shows as soon as it fills (or the turn ends). Later pages
fill in behind it and the footer's count grows. The page the wearer is reading never moves under them.
Speech-synced page turns wait for HZ's sentence boundaries and are not in this plan.

### 2 · Stale frames (from IB)

`GlassesDisplayService` gains `frameRevision: UInt64`, bumped by every render it enqueues: an ambient
op, a screen, a clear, a page. A page turn or an action carries the revision it was issued against. On
the render queue a turn whose revision isn't current is dropped and logged (`hudPageTurnStale`). So a
notification that arrives between "next" and the page render wins, and the answer's pages are abandoned
rather than drawn over it. A pure `PageTurnGate.accept(turnRevision:currentRevision:)` holds the rule.

### 3 · Actions under the answer

The card is an interactive `HUDScreen`, built by a pure `HUDAnswerCardBuilder` from the pages, the page
index and the follow-ups. Recommended layout:

| Page | Body | Buttons |
|---|---|---|
| Not the last | the page, footer "1/3" | **Next ›** · **Actions** |
| The last (or only) | the page, footer "3/3" when paged | up to two **follow-ups** · **Actions** (plus **‹ Back** when paged) |
| Actions (pushed) | the answer's first line, as a reminder | **More** · **Repeat** · **Save** · **Send** · **Close** |

What each one does:

- **Next ›** and **‹ Back** turn pages, through the §2 gate.
- **More** sends "Tell me more about that" as the next turn, exactly as if spoken.
- **Repeat** speaks the whole answer again, in the voice and route it used. It is not paged in time with
  speech.
- **Save** calls `save_note` with the answer, titled by its first line, then flashes "Saved".
- **Send** starts the ordinary `send_via` flow for the answer. The assistant asks by voice who to send it
  to, and the send stays staged until the wearer confirms, under the existing
  `ToolAuthorizationPolicy`. Nothing is sent from a single press.
- A **follow-up** sends its text as the next turn (§4).
- **Close** clears the card, and ambient producers resume.

**Lifetime.** A card stays until the wearer closes it, a new answer replaces it, or 60 s pass with no
press. Then it clears like any persistent frame. Notifications flash over it and the card comes back
after them, as they do over a task card. Captions are suppressed while a card is up (as over any
interactive screen) and resume when it clears. Over a Plan X task card, nothing changes: an answer still
flashes over the card for five seconds and is not made a card. Paging state is in memory only.

**Other input.** The same moves are reachable without the band:

| Input | Next | Back | Actions / Close |
|---|---|---|---|
| Voice (`HUDVoiceCommand`, only while a card is showing) | "next", "next page" | "back", "previous" | "close", "clear" |
| Temple tap (a new `TempleAction.pageAnswer`, bound in `TempleTapSettingsView`) | single tap | double tap | none |
| Web mirror (Plan BP) | right arrow | left arrow | Escape |
| JV Inputs, TestFlight only | `nav(.right)` | `nav(.left)` | `back` |

The paging words are a separate parse that `HUDRouter` consults only while the current frame is an
answer card. "Next" keeps meaning "step done" on a task card. The words are taken only as whole short
utterances, so "next" inside a sentence is never swallowed. "Repeat", "save that" and "send that"
already work as ordinary requests and stay that way.

### 4 · Suggested follow-ups

Up to three short next questions under an answer. Recommended source: the model writes them in the same
reply, in a tagged tail, only when a display (or the web mirror) is showing answers and the setting is
on. `SystemPromptBuilder` adds one clause: after the answer, on its own line, `<next>` with up to three
questions of six words or fewer, separated by `|`, then `</next>`.

- A pure `FollowUpTail` parser takes the tail off the reply before anything else sees it. It never
  reaches speech, the HUD body, the transcript or memory.
- A missing, empty or malformed tail shows no follow-ups. The answer itself is never affected.
- Sentence-streamed speech must not speak the tail as it arrives. The streamer holds back any sentence
  that begins with `<next>` (P2 tests this on every provider path that streams).
- Questions longer than the button allows are dropped, not cut.
- Under `hipaaMode` the clause is still allowed (the follow-ups never leave the reply), but no follow-up
  is ever written to the transcript.

Rejected: a second model call after each answer (it adds latency and a second paid request), and fixed
follow-ups that don't depend on the answer (they would be noise).

### 5 · The band check

A **Practise the band** card, started from Devices & Privacy › Glasses › Display and from the launcher.
It does two things: it teaches the wearer, and it gives a tester a check that settles the HUD's band
assumption.

On a store build the app sees only button presses, so each lesson is made of buttons:

1. **Select.** One button, "Press me". Three presses, a dot filling on each, then a check.
2. **Move.** Two buttons side by side. Press the one marked ●, which moves each time.
3. **A list.** Six buttons in two rows, the launcher's shape. Press them in the order shown. This is the
   free-navigation assumption, tested.
4. **Back** (TestFlight lane only). The card asks for the band's back gesture and listens for JV's
   Inputs `back`. On a store build this lesson isn't shown, because a store build can't observe back.

Each press plays one of `TextToSpeechService`'s existing tones and redraws the card through §2's gate. The phone shows the same
dots. Every run writes a **Band check** section to the support report: lessons passed, presses that
didn't arrive, time between presses, and the backend. A tester's report then answers whether the band
reaches every button.

For JV P2's mapping, the plan records starting values to confirm with JV's probe: a single tap counts
only once about 420 ms have passed without a second, since a double tap's second tap comes roughly
200 ms after the first; a hold or a swipe can arrive as several events, so the first counts and the next
600 ms are ignored.

### 6 · A preview to scale

`HUDPreviewView` and the on-phone mirror draw at the backend's real shape. The Meta Display is a black
600 × 600 square, measured in its own pixels at density 160, and the Even G2 panel is 576 × 288. A pure
`HUDCanvasScale` converts the backend's pixels to phone points for the space available. DAT styles text
by semantic token, not by size, so `HUDCanvasScale` maps each token to an **estimated** size (body text
on the Display runs about 24–32 of its pixels), marked as an estimate in the view's accessibility label
and in the code. P6 calibrates it from a photo of a real lens.

The answer card's pages show here exactly as §1 cuts them, so text length can be judged without
hardware. The teleprompter's preview uses the same canvas.

### 7 · Caption sessions kept and shared

An opt-in **Keep caption sessions** setting, off by default. When it is on:

- each captions or translation session is written to disk when it stops, named by when it began, in a
  new `CaptionSessionStore` registered with the data-store registry;
- the phone lists the last sessions, newest first, and opens one as a transcript: one turn per line as
  `HH:mm  said`, the translation on the line under it, the speaker's name where diarisation labelled it;
- **Share** exports that plain text through the share sheet. Nothing is sent anywhere by itself;
- sessions older than seven days are deleted, and **Delete all** clears them at once;
- under `hipaaMode` the setting is off and cannot be turned on;
- a saved session never goes to a model, to memory or to BrainStore unless the wearer asks for it (for
  example, a meeting summary of that session).

In the live captions view, the newest turn stays bright, and the view follows it unless the wearer has
scrolled back to read.

Captions record other people's speech, so the setting's footer says so plainly: what is kept, for how
long, that it stays on this phone, and that the people speaking may need to agree.

### 8 · When the Display is in use

The owner asked what the wearer gets while another app has the Display. Today, nothing on the lens, and
no sign of why.

**What is known.** DAT gives an app no notification surface on the Display: an app draws only inside its
own display session. Meta's display docs say an app has "exclusive display control during active
sessions", that "Users must explicitly initiate a display session", and that the system may interrupt
sessions for calls, notifications or other priority events. They don't say what an app's session does
while another app has the Display. `DeviceSessionState` has a `paused` case, which is the likely
reading. `MetaDisplayBackend.ensureDisplay()` handles only `started`, `stopped` and `idle`. On a paused
session it calls `start()`, waits up to 10 s, throws `sessionUnavailable`, and the frame is dropped.

**Speech is not affected.** It goes from the phone to the glasses' speakers over Bluetooth, outside the
display session, and the app has the `audio` background mode. Answers, reminders, geofence alerts,
approval prompts, "held while away" lines and remote-agent messages are already spoken as well as shown.
While the Display is taken, only two things are visual-only: the agent's "Step 2 of 5" progress lines
(kept off speech on purpose; the final summary is spoken) and §3's answer card.

**The rule.**

1. **A reading, not an error.** A pure `DisplayAvailability` reads the session state, the glasses' link
   and `GlassesConnectionService.isWorn` into `.ours`, `.inUse` or `.off`. The display is `.inUse` when
   the glasses are connected and worn and the session is `paused`, or a start is refused. It is `.off`
   when there is no display, the glasses are disconnected, taken off or folded. A display that went to
   sleep from inactivity is still `.ours`.
2. **Never take the Display back.** While `.inUse`, `MetaDisplayBackend` doesn't call `start()` and
   doesn't tear the session down. It waits for the session to report `started` again (through
   `stateStream()`), and then the reading returns to `.ours`.
3. **No backlog.** While `.inUse` nothing queues for the lens. Notifications and captions are dropped,
   because they were spoken or they're live. The service keeps one thing: the latest answer card.
4. **The card comes back if it's still fresh.** When the reading returns to `.ours`, the held card is
   shown again if it is still inside its 60 s lifetime, counted from when the answer was made. An older
   card is dropped.
5. **One spoken hint per stretch.** The first time an answer is spoken while the display is `.inUse`,
   one line follows it: "Your display's busy. Say 'repeat', 'save that' or 'tell me more'." It plays once
   until the reading leaves `.inUse`. It never plays for an alert, when the display is `.off`, or when
   speech is being suppressed. **Say when the display is busy** turns it off in Devices & Privacy ›
   Glasses › Display (on by default).
6. **Voice covers the card.** "Repeat", "tell me more", "save that" and "send that" already work as
   ordinary requests, so everything the card offers is still reachable while it can't be seen.

**Starting a session in the first place.** Today the first frame to show starts a display session on its
own. That sits awkwardly with "Users must explicitly initiate a display session". Decision 8 settles it.
Rule 2 holds either way: a session another app has interrupted is never started again by Avenkin.

## What KP leaves out

- **Neural Band settings and battery, buzzing the band, and its firmware.** DAT exposes none of them.
- **Meta's own captions and translation app on the Display, its language packs, the Briefing panel, the
  Display's Messages app and its web-app list.** None of them is reachable through DAT; KP keeps the
  app's own captions and cards.
- **Registering the web mirror on the glasses** (an "Add to glasses" link through Meta's `fb-viewapp`
  deep link). It needs the public HTTPS address BP P3 hasn't settled. It belongs to BP P3, and is noted
  there when P3 is drafted.
- **Speech-synced page turns** (HZ), **a scroll gesture** (the HUD stays paged), and **paging navigation
  and hazard lines**. Those are short by construction; a hazard that needs a second page is rewritten,
  not paged.

## Decisions (taken 2026-11-06: every recommendation below, "build out the plan")

1. **Footer:** "1/3", which needs no translation, rather than "Page 1 of 3". *Recommended: "1/3".*
2. **Page cap:** eight pages, then "… more on phone". *Recommended: eight now, and P6 decides whether
   fewer reads better.*
3. **Layout:** follow-ups on the last page and the five actions one press away under **Actions**, as in
   §3. The alternative is all actions on every page. *Recommended: §3. Two follow-ups fit beside
   Actions; a third shows on the Actions screen.*
4. **Follow-ups source:** the tagged tail in the same reply (§4), or none. *Recommended: the tail.*
5. **Follow-ups default:** on when a display or the mirror is showing answers, or off until P6.
   *Recommended: on for the Display, off for the mirror.*
6. **Send:** the voice-asked, staged `send_via` flow (§3), never a one-press send. *Recommended.*
7. **Caption sessions:** off by default, seven days, unavailable under `hipaaMode` (§7).
   *Recommended.*
8. **Who starts a display session (§8):** the app, the first time it has something to show, as today, or
   only after the wearer starts one (a band press, "show it on the display", or the HUD switch itself).
   *Recommended: treat turning the HUD on in Settings as the wearer's explicit start, so today's behaviour
   stays, and revisit if Meta's review reads the rule more strictly.*
9. **The busy hint (§8):** on by default, once per stretch. *Recommended.*

## Phases (one PR each)

### P0 — the pure core (headless)

`HUDAnswerPager`, `HUDAnswerPage`, `PageTurnGate`, `HUDAnswerCardBuilder`, `FollowUpTail`. **Tests:**
`HUDAnswerPagerTests` (a one-page answer has no footer and equals today's text; a 400-character answer
pages for both geometries; no split words; the sentence-end preference; the eight-page cap and its
"more on phone" line; blank lines; pages that grow while the answer streams keep their earlier pages
unchanged), `PageTurnGateTests`, `HUDAnswerCardBuilderTests` (buttons per page per §3; Back only when
paged; follow-ups only on the last page; the Actions screen), `FollowUpTailTests` (well-formed, missing,
empty, malformed, too long, more than three, a tail mid-reply rather than at its end).

*Built 2026-11-06.* What P1 and P2 build on:

- **Streaming.** `HUDAnswerPager.pages(for:)` is stable on prefixes: when the answer grows by whole
  sentences or words, the first `settledPageCount(_:)` pages keep their text (only `count` grows).
  Every page but the last of a paged answer is settled, every page of a capped one, and never a single
  page, since more text can turn it into a paged answer with a footer. So the card shows page 1 once it
  is settled or the turn has ended.
- **One page is today's text.** An answer that fits the geometry and the 120-character body limit is
  one page whose `body` is `HUDTextShaper.condense(answer)`, shown as one line with no footer. A paged
  page carries its wrapped `lines` (one `HUDLine` each) and a footer line.
- **Long words.** A word longer than a line is hard-split as the teleprompter does, and moves whole to
  the next page; it is split across pages only when it alone fills one.
- **Card layout.** As §3's table, so a middle page has **Next ›** and **Actions** but no **‹ Back**;
  Back is on the paged last page only. P6 may want Back on middle pages too. Presses arrive as a
  `HUDAnswerAction`; ids are `kp.next`, `kp.back`, `kp.actions`, `kp.more`, `kp.repeat`, `kp.save`,
  `kp.send`, `kp.close` and `kp.followup.0…2`.
- **Follow-ups.** A question over six words or 40 characters (the HUD title limit, one Even line) is
  dropped; then the first three are kept. A malformed tail gives no follow-ups and only tag text is
  removed: a closed tail with a nested or doubled tag, or an unclosed `<next>` that begins a sentence
  and runs to the end of the reply on one line (a tail cut short). A stray `</next>`, or an unclosed
  `<next>` inside a sentence or followed by more lines, is left as written. For P2's streamer,
  `FollowUpTail.beginsTail(_:)` says a streamed sentence starts the tail (hold it and everything after
  it back), and `textBeforeTail(in:)` returns the speakable part of a chunk that carries both.

### P1 — the card on the glasses (headless, wired)

The answer turn collects sentences; `frameRevision` in `GlassesDisplayService`; answers go through the
card instead of `showText`'s 120-character cut; Next, Back, Actions, More, Repeat, Save, Send and Close;
the voice words; `TempleAction.pageAnswer`; the mirror's keys; the 60 s clear; notifications over a card
come back to it; a task card unchanged. P1 also checks whether Gemini Live and OpenAI Realtime replies
reach the HUD today and, if they do, gives them the same card without follow-ups. **Tests:**
`HUDInteractionTests` additions (next and back move pages; a notification between issue and render
makes a turn stale; navigation lines never page; a task card still gets a five-second flash; Send never
sends without the confirmation), `WebHUDMirrorTests` (the footer shows and the arrow keys turn pages),
`HUDPreviewSnapshotTests` (one paged card per backend), `TempleActionResolverTests` (the new action).

*Built 2026-11-06.* What P1b and P2 build on:

- **The answer turn.** KK's turn id doesn't reach the speech path (`TurnRecorder` is instrumentation
  only), so `HUDAnswerCard` holds a pure `HUDAnswerTurn`. The Direct voice and typed turns call
  `beginTurn()` beside `makeReplySpeechStream`, `finishTurn(reply:)` in the streamed branch of `speak:`
  (the reply is final before it has all been said, so the whole card shows then), and `endTurn()` in
  `finish:`. `TextToSpeechService` hands answer lines (`SpeechSource.reply` and `.phoneAnswer` only) to
  `HUDAnswerCard.absorb(_:streamed:)` at the two mirror points (`speakReporting`, `playStreamedSentence`)
  instead of `showText`; every other source keeps `showText`. A whole answer outside a turn (a photo
  answer, tier 0, an agent's result) is a card of its own. A *streamed* answer line outside a turn (the
  gateway's partial results) keeps today's sentence-at-a-time line. The text is append-only: the final
  reply is reconciled with what was streamed through `StreamSpeechGate.reconcile`, a preamble said before a
  tool stays in front, and lines played after the reply is final are already on the card.
- **Showing.** Page 1 shows once settled or final; only settled pages can be turned to while the answer
  streams, so Next on the last settled page waits. `GlassesDisplayService.showsAnswerCard` marks the held
  screen as a card; an answer becomes a card only when nothing else interactive is up
  (`acceptsAnswerCard`), so over a task card, a menu or a choice list it still flashes for 5 s. While a
  notification is over the card, a changed card only updates the held screen and the flash's restore
  draws it. `clear()` from a producer leaves a card alone; `showNavigation` ends a card (guidance never
  waits behind one, and is never paged), which is what a guidance line did to a plain answer line.
- **frameRevision.** Bumped by every `enqueue` (op, screen, clear, page); `heldScreenRevision` is the
  revision at which the held screen was last enqueued, the frame whose buttons are on the glasses.
  Every card press goes through `acceptsCardPress(issuedAgainst:)`; a stale one is dropped and logged
  as `hud event=hudPageTurnStale count=<frames between>`. Band presses, and voice words and temple taps
  through `HUDAnswerCard.press(_:)`, are issued against `heldScreenRevision`, so while a notification
  is over the card every press is stale and the notification stays; once the flash restores the card,
  presses work again. JV's Inputs can pass a revision of their own.
- **Layout change.** ‹ Back is on middle pages too (P0 had it on the paged last page only), and the
  Actions screen has **‹ Answer** (`kp.answer`, `HUDAnswerAction.answer`) back to the page the wearer
  was on, before Close. Voice "back" does the same.
- **Actions.** More, Send and a follow-up go through `sendTextMessage` (the typed entry point, as Plan
  CG's choice buttons do): More sends "Tell me more about that", Send sends "Send your last answer to
  someone". The assistant asks who, and `send_via` is a messaging tool, so its bound approval holds the
  send; the press runs no tool. Repeat is `speak(answer, source: .readAloud, mirrorToHUD: false)`. Save
  runs `save_note` through `NativeToolRouter.execute` with origin `.user` (titled by the answer's first
  line, cut to 40 characters), then flashes "Saved" for 2 s (a press during that flash is stale, as over
  a notification). Close ends interactive mode. A More, Send or follow-up press while a turn is being
  processed is dropped by `acceptsTypedTurn`, as a typed message would be.
- **Lifetime.** 60 s (`idleLifetime`) from the last press, the last change to the answer, or the
  turn's end, whichever is latest, so a long answer still being spoken never clears under the wearer;
  a new answer replaces the card. Each arming bumps a generation, so an older timer never clears a
  newer card, and none clears a task card or menu that took the HUD. `scheduleIdleTimer` is the test
  seam (tests fire the timers by hand).
- **Other input.** `HUDAnswerVoiceCommand` ("next", "next page", "back", "go back", "previous",
  "previous page", "close", "clear", …), consulted by `HUDRouter.handleVoiceCommand` only while a card is
  up and no task or menu is, and taken only when it moves the card (`canTurn`): "next" on the last
  readable page, or "back" on the first, goes on to the model as before (it may mean the next track).
  Temple taps: two assignable actions, `answerNextPage` and `answerPreviousPage` (the map gives each tap count one action, so one `pageAnswer` with single/double
  didn't fit), refused with the soft tone (`noAnswerCard`) when no card is up, working in any activity but
  `busy`. The web mirror stays read-only: a card's payload carries all its readable pages
  (`HUDScreen.pageSet` → `WebHUDPayload.pages`/`pageIndex`/`card`), and the page turns them itself on
  ◀/▶ and hides the card on Escape, locally; no key reaches the phone. The payload's `renderKey` adds
  the card, page count and index, and the queue republishes a card whose readable pages grew behind an
  unchanged page, so the mirror gets newly settled pages. While the same card grows and the phone stays
  on its page, the browser keeps the page it turned to (and stays hidden after Escape); a new answer, or
  the phone turning a page, resets both.
- **Live modes.** Gemini Live and OpenAI Realtime replies don't reach the HUD today (their audio comes
  from the model; nothing mirrors it), so they get no card. Left as is.
- **For P1b.** The held card to bring back is `HUDAnswerCard`'s state; `presentAnswerCard` is where a
  `.inUse` reading should hold rather than enqueue. **For P2.** Follow-ups go in where the card builds
  its screens (`HUDAnswerCard.currentScreen`, `followUps: []` today), and `.followUp` presses already
  submit their text as the next turn.

### P1b — when the Display is in use

`DisplayAvailability`; `MetaDisplayBackend` reports `.inUse` instead of restarting or tearing down a
paused session, and follows `stateStream()` back to `started`; the held card and its return; the
spoken hint and its setting; the support report records each change of reading with its time and the
session state behind it. **Tests:** `DisplayAvailabilityTests` (every combination of session state,
link, worn and folded); a paused session never gets `start()` (through the backend's test seam);
nothing queues while `.inUse`; the held card shows again inside its lifetime and not after; the hint
plays once per stretch, never for an alert, never when `.off`, never while speech is suppressed, and
not at all with the setting off.

*Built 2026-11-06.* What P2 and P6 need to know:

- **The reading.** `DisplayAvailability.read` (pure, `Services/Display/DisplayAvailability.swift`)
  folds the display capability, the link (`GlassesConnectionService.isConnected`, fed by AppState with
  `isWorn` into `GlassesDisplayService.updateGlassesLink`) and the session reading
  (`DisplaySessionReading`: the app's own `DisplaySessionState` plus `startRefused`). `.inUse` is
  connected, not definitely taken off (`isWorn == nil` counts as worn), and the session `paused` or a
  start refused. **Folded is not an input:** the app deliberately doesn't read `hingeState`, and there
  is no other hinge signal, so a folded pair reads as its link and worn state say. Published as
  `GlassesDisplayService.displayAvailability`. Only the Meta backend reads it; Even G2 and the
  phone-only build always read `.ours`, and the mirror never makes it `.inUse`.
- **Never take it back.** `MetaDisplayBackend` drives the session through `DisplaySessionControl`
  (`DATDisplaySession` wraps `DeviceSession`; tests pass a fake through `testMakeSession`). Its watcher
  follows `stateStream()` for as long as it holds the session, so a pause is heard while nothing is
  rendering. `prepareSession()` never calls `start()` on a `paused` session and throws
  `GlassesDisplayError.displayInUse`; `resetAfterError()` leaves a paused session alone, and the
  service treats `displayInUse` as a reading, not a render failure. Back at `started` the reading is
  `.ours` by itself, and a display capability found `.stopped` is started again (device-only: whether
  it stops with the session is unknown). A start that throws or settles anywhere but `started`/`paused`
  is a *refused* start: the session is dropped and the reading is `.inUse` for 30 s
  (`startRefusalExpiry`), then the next frame tries once more. A compatibility refusal
  (`insufficientSDKVersion`) is thrown as itself. Turning the HUD off still tears a paused session down
  (and skips the blanking, since the lens is the other app's).
- **No backlog.** While `.inUse` nothing reaches the render queue (`enqueue` returns before bumping
  `frameRevision`), so the session is never asked to start; ambient lines and notifications are dropped
  at `present`. The web mirror holds its last frame meanwhile. The service keeps state only: the answer
  card, or a task card or menu still running (the plan named only the card; a task card is current
  state, not backlog, so it is drawn again too). Back to `.ours`, the lens gets one frame: the task card
  as it now is, the answer card through `HUDAnswerCard.displayReturned()`, or a clear.
- **The held card.** `HUDAnswerCard.answerMadeAt` is the answer's last change (made or grown); on return
  the card shows on the page the wearer left if `now - answerMadeAt < 60 s`, else it closes. Its idle
  timer keeps running while held, unchanged. While `.inUse` the paging words go to the model
  (`canTurn` is false) and page taps are refused with the soft tone.
- **The hint.** `TextToSpeechService` asks `GlassesDisplayService.claimBusyHint` after an answer
  (`.reply`/`.phoneAnswer`) is heard to its end: in `speakReporting` on `.completed`, and in
  `streamedReplyDidEnd` when the reply wasn't interrupted. `DisplayBusyHint` holds the
  once-per-stretch rule; the line is spoken as `.statusNotice`, not mirrored. The setting is
  `Config.displayBusyHintEnabled` (default on), **Say when the display is busy** in the In-Lens Display
  section under Devices & Privacy (`DisplayHUDSections`, glasses builds only).
- **Support report.** The phone section carries "Display reading now" and up to 20 changes
  (`DisplayAvailabilityLog`), each with its local time and the session state behind it; the event log
  carries `hud event=availabilityRead state=<reading> detail=<session>` and
  `hud event=displaySessionRead state=<session state>` on every session change. P6 reads these to
  learn what DAT reports when another app takes the Display.
- **Owed to P6.** Whether DAT reports `paused` (or `stopped`, or an error) when another app takes the
  Display; whether a paused session returns to `started` by itself; whether the display capability
  survives the pause; whether the glasses play our speech, and the hint, over the other app.

### P2 — suggested follow-ups

The `SystemPromptBuilder` clause, behind the setting and only while answers are shown on a display or
the mirror; the tail stripped before speech, the HUD body, the transcript and memory; the streamer holds
back a `<next>` sentence; follow-up buttons send their text as the next turn. **Tests:** a tail is never
spoken on any streaming provider path; never in the transcript; the clause is absent when no display is
showing answers; a malformed tail leaves the answer untouched.

*Built 2026-11-06.* What P3 and P6 need to know:

- **The clause.** `FollowUpPrompt.clause`, added by `LLMService.buildSystemPrompt` in the volatile tail
  (block "follow-ups"), so the cacheable head is the same with or without a display. Only the full cloud
  prompt asks (`offersFollowUps`): not the on-device prompts (a 2B model's window and memory are already
  tight), the one-line lean cloud prompt, the per-minute condensed prompt, or Gemini Live and OpenAI
  Realtime (a source scrape holds that). Allowed under `hipaaMode`.
- **When.** `FollowUpPrompt.currentSurface` reads `GlassesDisplayService.answerSurface`: `.display`
  (the HUD on and the backend has a display, mirror or not), `.mirrorOnly` (the HUD on, no display,
  the mirror on) or `.none`. Decision 5 is two settings: **Suggested follow-ups on the display**
  (`followUpsOnDisplayEnabled`, default on) beside **Say when the display is busy** in the In-Lens
  Display section, and **Suggested follow-ups on the mirror** (`followUpsOnMirrorEnabled`, default off)
  in the Web HUD Mirror screen. While another app has the Display the clause stays: the card is held.
- **Taken off everywhere.** `LLMService.takingFollowUpTail` is the chokepoint beside
  `collapsingRepeatedReply`: every `sendMessage` reply (voice, typed, photo, scheduled agents,
  notifications) loses its tail before the job's log, the transcript, memory, speech or the HUD see it,
  and the last assistant history entry loses it too (plain text, or the last text part), so the model
  never sees its own tags again and nothing restored or exported carries them. The questions are kept in
  `replyFollowUps` (reset as each `sendMessage` starts) and handed to `HUDAnswerCard.offerFollowUps` by
  the voice and typed turns, the only place they go. `ConversationTurnRunner` takes a tail off again,
  before and after `postProcess`, for any other brain (the Hermes bridges, the local agent) and for a
  tail a memory tag after it kept from the end; what it finds goes to `onFollowUps`. The Chat tab's live
  bubble keeps the raw stream in `StreamingTurn.received` and shows `FollowUpTail.streamingVisible`.
- **The streamer.** `StreamSpeechGate` hands the splitter only the text before the first `<next>`
  (`FollowUpTail.streamingVisible`, anywhere and any case), holding a trailing "<", "<ne"… until the
  next chunk; once the tag has arrived the iteration is held (`HoldReason.followUpTail`), and if the tag
  begins a sentence the answer's last sentence is released at once (the splitter never cuts before
  "<", so it would otherwise ride with the tail). The final reply has no tail, so the reconciliation
  never says it either. Tested on Anthropic's turn, the OpenAI-compatible chat stream and the Responses
  stream through the real parsers, the on-device token shape with a think block, and a reply said whole.
- **The card.** Two follow-ups beside Actions on the last page, a third on the Actions screen. Only a
  reply that came back whole carries them (`finishTurn`, or the whole answer reaching `absorb`); a turn
  cut short, a new answer's card, a card outside a turn and a closed card have none.
- **Owed to P6 (and a live model).** How reliably each model writes the tail, and whether it keeps it
  last; whether six-word questions read well as buttons on the lens.

### P3 — the band check

The **Practise the band** card and its phone page, the tick, and the support report's **Band check**
section; lesson 4 only under `DAT_EXPERIMENTAL` inside `Sources/Glasses/Experimental/`, per JV's rules.
**Tests:** lessons advance on simulated presses (`testInteractiveButtonActions`); a press against a
stale revision is ignored; the report section's content; lesson 4 absent from an unflagged build (JV's
guard tests).

*Built 2026-11-07, lessons 1–3.* What P6 and JV need to know:

- **Lesson 4 waits for JV.** Plan JV's experimental lane (`project.experimental.yml`,
  `Sources/Glasses/Experimental/`, `DAT_EXPERIMENTAL`) isn't built yet, so nothing links `MWDATInputs`.
  `BandLesson.back` is declared (the result, the report and the lesson list have a place for it) and
  never offered: `BandLesson.offered` is `select`, `move`, `list`, and `BandPractice` drops `back`
  whatever it is given. JV P0/P2 add the lesson behind its flag, listening for Inputs `back`, with
  JV's guard tests.
- **The core.** `BandPractice` (pure, `Services/Display/BandPractice.swift`): Select is three presses
  of "Press me"; Move is two buttons, the marked ● starting on the right (the band's focus most
  likely starts on the first button) and swapping sides each press; A list is six numbered buttons
  (`HUDMenuBuilder.pageSize`, one `ButtonGroup` like the launcher's) to press 1 to 6, laid out
  `[3, 1, 5, 6, 2, 4]` so the path goes down, back up and across both rows; pressed ones show ✓.
  Lesson 3 asks six presses, not three. Every button id names its frame
  (`band.<lesson>.<step>.<slot>`), so a press from an older frame is *stale* (dropped, counted
  apart), never *wrong*; a wrong press is recorded and doesn't advance. `BandPracticeCardBuilder`
  draws each step (the passed lessons, "2 of 3 · Move", the instruction, ●●○) and a last screen
  with Done.
- **The session.** `BandPracticeSession` (`AppState.bandPractice`) starts from **Practise the band**
  in Devices & Privacy › In-Lens Display (`BandPracticeView`, glasses builds only) and from the
  launcher's last branch (offered while a display can show it and no task card is up). It is refused,
  with the reason on the phone, while the HUD is off, the Display reads `.off` or `.inUse`
  (`GlassesDisplayService.practiceAvailability`, read now), or a task card is up; an open launcher
  menu is closed first. Each press goes through §2's gate first
  (`acceptsHeldScreenPress(issuedAgainst:)`, the answer card's rule for any held screen), then plays
  the temple taps' accepted or refused tone, and a right one redraws the card. It ends on Done, Stop
  on the phone, 60 s without a press, or the lens taken by something else (a task card, a menu,
  interactive mode ended elsewhere: `heldScreenRenderKey` no longer its card). It ends interactive
  mode only while its card is the held screen, so it never clears what replaced it. While another
  app has the Display the card is kept, as the answer card is.
- **The report.** The last run only, in `UserDefaults` (`bandCheckLastRun`, on `DataStoreRegistryTests`'
  exempt list: counts, milliseconds and case names), written when the last lesson passes or the run
  ends early. The phone section carries:

  ```
  Band check (last run 2027-01-15 08:00:00, backend metaRayBan, timedOut):
    Lessons passed: 1 of 3 (select)
    Presses asked for that didn't arrive: 8 (move 2, list 6)
    Wrong presses: 1 (move 1)
    Stale presses dropped: 0
    Time between presses: 4 gaps, median 1000 ms, fastest 1000 ms, slowest 2000 ms
  ```

  The event log has `hud event=bandCheckStarted|bandCheckRefused|bandCheckEnded`.
- **Owed to P6.** Whether the `ButtonGroup` lays six numbered buttons in two rows as it does the
  launcher's labels (short labels may sit in one row; the lesson still tests moving across six);
  whether the band reaches the second row at all; how the tones sound over speech; whether the band's
  focus does start on the first button.

### P4 — the preview to scale

`HUDCanvasScale` and both previews at the backend's shape, with token sizes marked as estimates.
**Tests:** `HUDCanvasScaleTests` (600 × 600 and 576 × 288 into narrow and wide spaces; whole-pixel
mapping), snapshot tests for both backends.

*Built 2026-11-07.* What P6 needs to know:

- **The canvas.** `HUDCanvasScale` (pure, SDK-free, `Services/Display/HUDCanvasScale.swift`) holds the
  two lenses as `HUDCanvas` (`.metaDisplay` 600 × 600 at density 160, `.evenG2` 576 × 288) and fits one
  into the space a preview has: centred (letterboxed), its size and origin on whole device pixels with
  the same factor on both axes (a 2:1 panel drops an odd pixel rather than blur an edge), and never past
  one point per lens pixel (`maxPointsPerPixel`), about true size for a density-160 unit.
- **The estimates.** `HUDCanvas.textSize(_:)` gives each token's size in lens pixels, every one
  `isEstimate`. Meta Display: heading 34, body 28, meta 22, lines at 1.35 × (the web mirror's 600 × 600
  page uses the same, so the two previews agree). Even G2: one size, 20 px on a 36 px line pitch with a
  12 px advance, which is what `EvenScreenRenderer`'s 44-cell, eight-line budget assumes. The DSL
  renderer's own lengths (button padding 16 × 10, icons 28, images 120) are lens pixels too, and as
  much guesses.
- **The previews.** `HUDPreviewView` draws the chosen backend's lens (`Config.displayBackend`, or a
  `canvas:` passed in): the Meta tree on a black square, scaled by the fit; the Even frame as the
  renderer sends it, one green monospaced line per row, overflow cut rather than ellipsised. The HUD
  Mirror and the teleprompter's Now playing preview go through it, so both are to scale; the mirror says
  "Text sizes are estimates" under the lens, and VoiceOver hears it in the preview's label. The
  phone-only build keeps its plain list (no lens there).
- **Owed to P6.** Photograph a Meta Display page and an Even G2 page beside the phone's preview and
  set the token sizes (and the DSL paddings, the button height and how a `ButtonGroup` wraps) from what
  the lens shows; whether DAT wraps or cuts a long `Text`; whether the content sits top-left on the
  Display or centred; the Even font, advance and line pitch; then clear `isEstimate` for what was
  measured.

### P5 — caption sessions kept and shared

`CaptionSessionStore` (registered for erasure), the setting and its footer, the session list, the
transcript view, Share, seven-day expiry, Delete all, the `hipaaMode` lock, and the live view following
the newest turn. **Tests:** store round trip; expiry; erasure through the registry; the plain-text
export (times, translation lines, speaker names); the setting can't be turned on under `hipaaMode`; a
session never enters memory unasked.

### P6 — device pass (owed; needs someone with a Display)

Read three long answers on a Meta Display and on Even G2; turn pages by band, voice and temple tap; press
every action and two follow-ups; confirm that a stale turn never overwrites a newer notification; run
the band check and send its report; photograph the lens to calibrate §6's estimates. Then open another
Display app (another toolkit app, and one of Meta's own) and ask a question: listen for the answer and
the hint, come back, and check the card. Send the support report, so it shows which session states DAT
reported. Settle decisions 2, 3 and 5.

**Gates for every PR:** the full suite and a Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`, catalog
changes in their own commit, and this Status line and the index row updated.

## Acceptance

- A long answer on the Display is readable in full, a page at a time, on both backends, and nothing is
  cut without a sign.
- From the glasses alone the wearer can turn pages, hear the answer again, ask for more, save it, start
  sending it, and ask a suggested next question.
- No follow-up tag is ever spoken, shown as text, or kept.
- A tester's support report says whether the band reached every button.
- The phone's preview shows a page at the Display's shape, with its sizes marked as estimates.
- With the setting on, a captioned conversation can be opened and shared afterwards, and is gone after
  seven days.
- While another app has the Display, the wearer still hears every answer and alert, hears once that the
  display is busy and what to say instead, and Avenkin never takes the Display back.

## Open

- Whether stable DAT reports the band's back gesture to the app at all, or the Display keeps it. P3's
  lesson 4 and JV's probe answer it.
- The real pixel sizes behind DAT's text tokens (P6).
- ~~Whether the live modes' replies reach the HUD today.~~ Answered by P1: they don't (their audio comes
  from the model and nothing mirrors it), so they get no card.
- What DAT reports when another app takes the Display: `paused`, `stopped`, or an error (P6, from the
  support report).
- Whether the glasses play our speech over another Display app's own sound, or hold it back (P6).
