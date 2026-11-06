# Plan KP — Answers You Can Act On, on the Display (the whole answer in pages, actions under it, a band check, a preview to scale, captions kept)

**Status:** 📝 Drafted 2026-11-06 from the owner's question; nothing built. Supersedes Plan
[IB](IB-paged-hud-answers.md) (paged HUD answers), whose design is folded in here as §1–§2 and P0–P1.
The decisions below are recommendations until the owner takes them. Revised the same day: §8 and P1b
cover what the wearer gets while another app has the Display.
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

## Decisions (recommendations, not yet taken)

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

### P1b — when the Display is in use

`DisplayAvailability`; `MetaDisplayBackend` reports `.inUse` instead of restarting or tearing down a
paused session, and follows `stateStream()` back to `started`; the held card and its return; the
spoken hint and its setting; the support report records each change of reading with its time and the
session state behind it. **Tests:** `DisplayAvailabilityTests` (every combination of session state,
link, worn and folded); a paused session never gets `start()` (through the backend's test seam);
nothing queues while `.inUse`; the held card shows again inside its lifetime and not after; the hint
plays once per stretch, never for an alert, never when `.off`, never while speech is suppressed, and
not at all with the setting off.

### P2 — suggested follow-ups

The `SystemPromptBuilder` clause, behind the setting and only while answers are shown on a display or
the mirror; the tail stripped before speech, the HUD body, the transcript and memory; the streamer holds
back a `<next>` sentence; follow-up buttons send their text as the next turn. **Tests:** a tail is never
spoken on any streaming provider path; never in the transcript; the clause is absent when no display is
showing answers; a malformed tail leaves the answer untouched.

### P3 — the band check

The **Practise the band** card and its phone page, the tick, and the support report's **Band check**
section; lesson 4 only under `DAT_EXPERIMENTAL` inside `Sources/Glasses/Experimental/`, per JV's rules.
**Tests:** lessons advance on simulated presses (`testInteractiveButtonActions`); a press against a
stale revision is ignored; the report section's content; lesson 4 absent from an unflagged build (JV's
guard tests).

### P4 — the preview to scale

`HUDCanvasScale` and both previews at the backend's shape, with token sizes marked as estimates.
**Tests:** `HUDCanvasScaleTests` (600 × 600 and 576 × 288 into narrow and wide spaces; whole-pixel
mapping), snapshot tests for both backends.

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
- Whether the live modes' replies reach the HUD today (P1 finds out).
- What DAT reports when another app takes the Display: `paused`, `stopped`, or an error (P6, from the
  support report).
- Whether the glasses play our speech over another Display app's own sound, or hold it back (P6).
