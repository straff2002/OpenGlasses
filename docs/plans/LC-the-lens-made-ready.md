# Plan LC — The Lens Made Ready (offered on connect, hardened for the real Display, and the screens the ecosystem shows are worth having)

**Status:** 🚧 Drafted and building 2026-11-11, all phases headless; P0–P5 built. The device pass is owed and is folded
into KP P6 / KV P5 (nobody on the team has a Display yet; the partner's is still on order).
**Track:** Display (Meta Ray-Ban Display through stable `MWDATDisplay` 1.0.1). Nothing here links or
calls an experimental DAT API; gesture work stays in Plan [JV](JV-dat-experimental-testflight-lane.md).
**Source:** `reports/Meta Display and Neural Band features.md` (GitHub and ecosystem survey,
2026-11-11) and the owner's instruction the same day: "the display features should be enabled once
display glasses [are] connected and [the] user chooses", and "continue without [the glasses],
implementing all suggestions".
**Related:** Plan [KP](KP-answers-you-can-act-on.md) (answer card, Display-in-use rule, decision 8),
Plan [KV](KV-the-page-on-the-lens.md) (pictures on the lens), Plans [X](X-interactive-hud-now-next-tasks.md)
/ [Y](Y-interactive-hud-launcher.md) (task card, launcher), Plan [BY] (captions), Plan [CA] (walking
navigation), Plan [KS](KS-watch-today-screens.md) (Watch Today), Plan [GU] (idle mic on the phone).

---

## Why

Every open-source Display app that reached hardware learned the same platform rules the hard way, and
OpenGlasses' Display stack, built headless, does not yet follow all of them. Meta's issue tracker and
the community apps (BirdJournal, hermes-glasses, MultiSet, meta-glass-test) agree on:

- **The band's Back gesture ends the session on hardware**, and apps cannot intercept it in 1.0.x
  (iOS #349). Today a session the glasses ended is rebuilt by the next frame: the next caption or
  notification re-opens the display the wearer just dismissed.
- **The first `.actionRole(.primary)` button takes focus** when content first renders (1.0.0). No
  screen in the app marks one, so focus lands wherever the firmware puts it.
- **Opening the glasses' hands-free (HFP) mic ends the display session** on current firmware (iOS
  #342). A conversation on the **Glasses Mic** route tears the lens down at every turn.
- **A send is not free** (~47 ms text, ~155 ms a 552 px image) and **a successful `send()` does not
  prove the frame rendered**. Apps pace sends, time them out and fall back to text.

And the display is off by default (`glassesDisplayEnabled`), behind a switch a new wearer has to
find. The owner's rule: **offer it when Display glasses connect, and turn it on only when the wearer
says yes.** That is also KP decision 8's "wearer's explicit start" (the HUD switch), made findable.

## What LC builds

### 1 · The offer on connect (P0)

`DisplayOfferPolicy` (pure) reads: the glasses connected (`linkState == .connected`), the active
backend reports a display, the HUD is off, and the offer has not been answered. Then the phone shows
one card — **"Your glasses have a display. Show answers, captions and directions on it?"** with **Turn
on** and **Not now** — and nothing turns on by itself. **Turn on** sets `glassesDisplayEnabled`;
**Not now** records the answer, and the switch in Devices & Privacy › Glasses › Display stays where it
was. Asked once per install; turning the switch on or off by hand counts as an answer. Never offered in
the phone-only build, under HIPAA mode the wearer can still choose (the HUD shows nothing HIPAA mode
withholds elsewhere), and never spoken.

### 2 · Hardening (P1)

1. **Focus.** `HUDScreen.focusItemID`: an explicit choice, else the first `.primary` item, else the
   first `.secondary`, else the first item. The Meta backend marks exactly that button
   `.actionRole(.primary)`. Builders choose where it matters: an answer's first page focuses **Next ›**,
   its last page **Actions**, the Actions screen **More**.
2. **A session the glasses end is a dismissal.** When the watched session reaches `.stopped` without
   the app stopping it (Back, a two-finger tap, the HFP mic), the service ends interactive mode, clears
   its dedup state, and sets `lensDismissed`. While set, ambient producers (captions, notifications,
   navigation lines, a page's **Show here** cue) do not open a session. It clears on a wearer-led
   frame: a menu or task card presented, an answer card (the wearer asked), a page view the wearer
   opened, the HUD switch turned on, or the glasses' link coming up again. Running task cards stay
   resumable from the launcher's existing **Resume task**.
3. **Every non-root screen has a way out.** A test sweeps every builder and fails on an interactive
   screen with no exit item (Close, Back, ‹ Answer, Stop, Done, Dismiss); the launcher's L0 is the
   root, where Back ending the session is the intended exit.
4. **The send pump.** `HUDSendPacer` (pure): at least 0.4 s between text frames and 1 s after a frame
   with a picture; a send that takes longer than 4 s is treated as a render failure; a picture frame
   that fails is sent once more without its picture (the text lines). The last send's duration, kind
   and outcome go to the support report and the Developer panel.
5. **The mic stays on the iPhone while the lens is on.** `LensMicPolicy`: with the Meta Display on
   (HUD switch on, a display reported) and the conversation route **Glasses Mic**, capture uses the
   iPhone mic (**Headset** is unaffected: its hands-free link doesn't touch the lens). The stored
   preference is unchanged and shown as chosen; Settings says why it is overridden. **Keep the mic on
   the iPhone while the display is on** (on by default) is the rollback.

### 3 · Approve / Deny cards (P2)

An approval that today is a 10 s ambient "Approve?" line becomes a held card: a warning icon, the
action as the heading ("Send to Sam?"), one preview line, and **Approve** (primary) · **Deny** ·
**Details** (when there is more on the phone). It stays until answered or until its timeout, which
denies. Voice yes/no and the Watch still answer it. A temple tap never approves.

**Built 2026-11-11 (P2).** `HUDApprovalCardBuilder` (pure) splits the consent surface's summary at its
first ": " (or after a first sentence that is already a question) into the heading and one preview
line, behind a ⚠ meta line naming who asks ("The assistant asks", BN P1's attribution); a first part
too long for a heading gets the generic **Approve?** and the whole ask as the preview. Items are
**Approve** (primary, focused) · **Deny** (`lc.approval.deny`) · **Details** (only when the preview was
cut), and Details shows the ask over up to four lines with Approve · Deny · ‹ Back (focused) and "The
rest is on your phone" when even that is cut. `HUDApprovalCard` watches
`ToolConfirmationCoordinator.pending`, so a band press, a spoken yes/no (`resolveByVoice`, unchanged)
or the phone's card all answer it and close it; band presses are gated on `acceptsHeldScreenPress`, so
one made under a notification is dropped. `GlassesDisplayService.presentApprovalCard` /
`endApprovalCard` hold the card over whatever the lens had and restore it afterwards (a task card, a
menu, an answer card, the turn's card, a page view); while it is up a task card or menu that changes
goes underneath it, an answer flashes over it, a page view does not open, and a screen that ends under
it does not come back. Decided differently: **there was no approval timeout to reuse** (the 10 s was
only the ambient line's lifetime; the coordinator waits indefinitely), so the card brings its own,
`HUDApprovalCard.defaultTimeout` = **20 s** — twice the old line, long enough to read and answer by
voice after the prompt is spoken, inside the panel's 25 s wake — and it belongs to the card: an ask the
lens could not hold waits on the phone as before. The card is not wearer-led, so it does **not**
reopen a lens the wearer dismissed (the ask is still spoken and on the phone), and a text-reply ask
(Plan FE) keeps the old line. The spoken prompt is no longer mirrored while the card is up (it would
cover the card and make its buttons stale). **There is no Watch confirm today** (the Watch app has no
approval surface), so "the Watch still answers it" is true only once one exists — it will, because
the card follows `pending`. Temple taps have no approval effect in `TempleActionResolver`, and the
card takes no press from them.

### 4 · Listening → thinking → answer, and the Today glance (P3)

- **Listening** (the live partial transcript, at most one send per 0.4 s, the final always sent) →
  **Thinking** → the KP answer card, so the lens is never blank while the wearer waits. Only for a turn
  the wearer started and only while the lens is the wearer's (not over a task card or menu).
- **Today** becomes the launcher's root (L0): time and glasses battery, the next event, the weather,
  an active timer or route, the top digest item, then **What's new** (primary) · **Resume** ·
  **Navigate** · **Menu**. Summoned (voice "show my day", a temple-tap quick action, the Watch), never
  always on: the panel sleeps at 25 s and a session is the wearer's to start.

**Built 2026-11-11 (P3a, Listening → Thinking).** `HUDTurnStateBuilder` (pure) draws **Listening…**
(the partial transcript's newest words in the body style) and **Thinking…** (the heard question as the
answer card's "You: …" line), each with **Stop** (`lc.turn.stop`, focused). `HUDPartialThrottle` (pure)
allows one partial per `HUDSendPacer.textGap` (0.4 s) and the final always; a partial inside the gap
waits it out and the newest goes then. `HUDTurnState` runs it: `beginListening()` from
`handleWakeWordDetected` (the wake word, a tap, the Action Button, a temple tap) — a wearer-led frame,
so it reopens a dismissed lens through the new `presentTurnState(_:wearerStarted:onSelect:)`; partials
from `TranscriptionService.$currentTranscription`; `heard()` from `onTranscriptionComplete`;
`thinking()` where `handleTranscription` hands the turn to the assistant (after the voice commands, so
a command never flashes Thinking). The answer card replaces it (`acceptsAnswerCard` now accepts over
the turn's card); `end()` clears it when the turn is over without one (`resumeListeningOrReturnToWakeWord`,
the silence timeout, an empty final, `isProcessing` going false, Assistive Mode or a narration command
taking the transcript), with a 30 s / 90 s lifetime as a backstop. `acceptsTurnState` keeps it off a
task card, a menu, a page view and an approval card; guidance and anything else taking the lens end it;
a line spoken during the turn (an error) flashes over it and its own auto-clear clears the lens. Stop on
Listening is the phone's Tap to stop (`endListeningSession`), on Thinking the phone's cancel
(`cancelCurrentResponse`). Decided: the follow-up capture a conversation re-arms by itself does **not**
show Listening — it would cover the answer card being read — so the states are for the turn that opened
the conversation. Held screens, not ambient frames: Stop needs a button, and a held screen keeps
captions off the wearer's own words.

**Built 2026-11-11 (P3b, Today).** `HUDTodayBuilder` (pure) builds L0 from a plain `HUDTodayGlance`:
time · glasses battery (`clock`, meta; the battery only while connected), the next event (`calendar`:
"Now: …", "10:30 …", "Today: …"), the weather (`weather`, with WeatherKit's service name as its
credit), the walking route (`navigation`), the digest's top item (`info`), then **What's new**
(`branch:digest`, primary, focused) · **Resume** (`branch:resume`, only with a task card running) ·
**Navigate** (`branch:navigate`, only with a recent destination) · **Menu** (`today:menu`, pushes the
existing branch list, whose Close closes the launcher and "back" returns to Today) · **Close**. Rows and
items with nothing to show are left off. `HUDTodayGlance.make` reads the Watch's Today value
(`WatchTodayBuilder.payload` over `MyDayService.gathered`, Plan KS), so the lens and the wrist read the
same day under the same Medical Compliance rules (titles withheld under any mode, weather off under
Local Only); yesterday's gathering adds nothing, and opening Today fetches nothing.
`NotificationDigestService.topLine(now:)` gives the deterministic top line (never the model rewrite,
never marks anything seen). New `HUDIcon` cases `.weather` (DAT `.cloud`) and `.clock` (DAT `.clock`),
with glyphs on the Even G2, the web mirror and the phone preview. Summoned only: "menu" as before, and
"show my day" / "show today" while the lens can show it (otherwise the words still reach My Day). Not
built: an active timer row (no timer service the lens can read yet) and the temple-tap and Watch
summon paths the section names — the launcher opens the same way from any of them once they call
`HUDLauncher.open()`. A launcher with no `today` source (the tests' rigs) opens at the branch list as
before.

### 5 · Live-mode answers and the picture behind a vision answer (P4)

- The live and realtime modes (Gemini Live, OpenAI Realtime, Qwen, Doubao) put each model turn's
  transcript on the lens as a KP answer card at the turn's end — not word by word. KP and KV excluded
  them; with §2.5 they no longer fight the lens for the mic.
- A vision answer's first page carries a small thumbnail (≤ 552 px wide, ≤ 200 px tall) of the frame
  that was analysed, through KV's `HUDPicture` path, so the wearer sees what the answer is about and
  which camera took it.

**Built 2026-11-11 (P4a, live-mode answers).** One adapter, not a change per provider: every live
provider (Gemini Live, OpenAI Realtime, Qwen, Doubao) runs through the shared `RealtimeSessionManager`,
which now sends `LiveAnswerEvent`s (`onAnswerEvent`) from the places it already hears them — the
server's speech start, the wearer's transcript, the model's transcript deltas, an interruption, the
turn's end, the session's stop; never for the spoken interpreter. AppState hands both managers'
events to one `LiveAnswerCardFeed`, whose pure `LiveAnswerTurnTracker` joins the turn's transcript
(`ScriptAwareJoiner`, the session's own rule) and, at the turn's end, gives `HUDAnswerCard.presentLiveAnswer`
the whole text, what the wearer said (the card's "You: …" line) and whether they led. The card is
KP's — paged, Actions, the 60 s lifetime — with no follow-ups (a live model is never asked for the
tail, `FollowUpPrompt`). Decided: **turn end only, no partials** — a live transcript arrives in
sub-word deltas ahead of the audio, the turn ends while the audio is often still playing, and KP's
card shows page 1 only once it is settled, so throttled partials would spend sends on a card that
barely moves. The answer waits a 0.5 s settle for transcript that trails the turn-complete event,
and goes at once when the wearer starts talking. A still-open turn the wearer speaks over is
dropped (its response was cancelled; the next answer replaces it); a completed turn whose playback
they cut is whole and shows. A tool call's empty turn carries the question and the lead to the
answer after it; a JSON provider's late input transcript joins the turn waiting to publish. The idle
warning is not an answer. Rules unchanged and enforced by the card: the HUD switch, the Display-in-use
rule, `acceptsAnswerCard` (never over a task card, a menu, a page view or an approval card — and,
unlike Direct mode, nothing flashes there instead: a live answer is heard). New:
`GlassesDisplayService.presentAnswerCard(_:wearerLed:onSelect:)` — a live answer reopens a dismissed
lens only when the wearer spoke or pressed that turn (an announcement or a volunteered answer stays
off it). The card's presses in a live mode go to the live session (`LiveAnswerCardRouting`): More,
Send and follow-ups as a text turn where the provider takes them, Repeat through the exact-speech
lane (Doubao) or as a text turn; with neither, "Not available in this live mode" flashes — they
never fall through to the Direct model the wearer did not choose. The band pages a live card; the
spoken paging words go to the live model, as everything spoken in a live mode does.

**The live mic (§2.5 for live modes).** A live session has no mic picker: it captured on the
glasses' hands-free mic whenever the camera streamed from them, so the HFP mic ended the display
session every time a Display wearer went live. That capture is the **Glasses Mic** route, and
`LensMicPolicy.liveAudio` now puts it through `conversationRoute`: with the Meta Display on (and
**Keep the mic on the iPhone** on) the session uses the new `RealtimeAudioRoute.lensPhoneMic` — the
phone's built-in mic, output still on the glasses over A2DP, no `.allowBluetoothHFP`, mode
`.default` (`.voiceChat` / `.videoChat` imply HFP), no voice processing (it can pull a Bluetooth
route onto its hands-free link), and the phone route's echo posture (capture muted while the model
speaks on the half-duplex tier, since the phone's mic hears the open-ear speakers). The late camera
start no longer switches such a session to glasses audio. The interpreter keeps its own route, and
without the lens (or with the rollback off) live audio is exactly as before. Not changed: a live
session still ignores the stored **iPhone / Headset** preference, as it always has — honouring it
would move every existing glasses user's live sessions off the glasses mic, which is a decision of
its own, not this plan's. The route is chosen at session start; turning the HUD on mid-session
takes effect at the next session.

**Built 2026-11-11 (P4b, the picture behind a vision answer).** `HUDAnswerThumbnail` (pure apart
from the ImageIO decode) draws the analysed frame into a **552 px-wide strip, at most 200 px tall**:
the frame aspect-fit and centred, the rest black (clear on the additive lens), every channel lifted
through a gamma of 0.8 (shadows up, black and white unchanged). A fixed-width strip rather than a
bitmap the frame's own shape, because DAT's only non-icon image preset is `.fill`, which sizes the
image to the column: a portrait thumbnail could otherwise come back 576 px wide and 768 tall. The
strip draws at most 209 px in the 576 px column. Its `contentKey` is the capture time, byte count
and decoded size — never pixels. Decoded with ImageIO's thumbnail (orientation applied; a 12 MP
photo is never held at full size) off the main actor, while the model thinks. **On the first page,
budgeted, not a page of its own:** on `LensPageFrame`'s measured budget the fullest first page of the
4 × 32 card (four body lines; or the question and three; or the question, two and the footer) leaves
at least 286 px over the button row, so the strip fits beside the text without the pager moving a
word — the page count and the prefix-stable pages a streaming answer relies on are unchanged.
`HUDAnswerThumbnail.fits` is the guard (`HUDAnswerCardBuilder.page(picture:)`): a page it does not
fit is drawn without the picture rather than scrolled. The backend draws a picture after a screen's
lines, so the thumbnail sits under the text and over the buttons. AppState stages the frame at
every vision send (the photo button and quick action, the phone-camera fallback, "take a picture",
the smart camera's frame on a cloud turn, a typed turn with an image) through
`HUDAnswerCard.expectPicture` / `stagePicture(_:ticket:)` — only when `wantsAnswerPictures` (the HUD
on, a display, a backend that draws pictures); the next new card takes it, and the turn's end, a
whole answer outside a turn, the photo path's end or 90 s drops one nobody took, so a frame never
lands on a later, unrelated answer. A late decode for an older frame is ignored by its ticket. P1's
send pump already sends a failed picture frame again as text. Not built: the live modes' frames (a
live session streams video continuously; no single frame is "the" one an answer analysed), a label
saying which camera took it (the From-the-phone-camera line is already spoken and on the card's
text), and redrawing a card whose thumbnail decode finished after the card went up (it would need
the card to say which frame it is waiting for; decode takes milliseconds against seconds for the
model, so it is not expected).

### 6 · Refinements (P5)

- **Captions:** a three-row budget (~340 characters) instead of one condensed line, the speaker label
  in the meta style, a mic icon while capture is live, top-aligned.
- **Navigation:** a white-on-clear turn arrow drawn on the phone at the bearing, beside the text line;
  sent no more than once a second, text alone when the link is slow.
- **Timer and media cards:** an alarm or timer completion card (**Stop** · **+5 min**), and a Now
  Playing card (title, **‹‹ · ▶︎/❚❚ · ››**, **Vol − / Vol +**: the band's volume twist does not work
  during a DAT session, iOS #330).
- **Home Assistant favourites** as a tappable list.
- **Teleprompter voice-follow:** the page advances when the phone mic hears its last words.
- **Field Assist clips:** a procedure step with an HTTPS MP4 offers **Watch** and plays it in a
  `VideoPlayer` (≤ 400 px a side, ≤ 70,000 px).

**Built 2026-11-11 (P5a, captions).** Captions are a frame of their own, not `showText` (whose
contract — one line condensed to `HUDTextShaper.maxBodyLength` — is unchanged for its other
producers): `GlassesDisplayService.showCaption(_:)` takes an `HUDCaption` from `HUDCaptionBuilder`
(pure). The live text follows the last three finals of the same speaker from the last 12 s (so a final
no longer blanks the lens; a compacted caption that already carries the final is not repeated; the
visual notes a recording inserts are never carried), wrapped forward at word boundaries into rows of
at most 113 characters, the last three kept — 339 characters at most, under the backend's own
120-character condense — and the first row marked "… " when older words were dropped. Diarization's
speaker is a meta line over the rows; the new `HUDIcon.microphone` leads it (or the first row) while
capture is live. Top-aligned: the Meta backend draws it as an items-less screen from the top of the
column. Still ambient (dropped under any interactive screen, while another app has the Display, and
while the wearer has dismissed the lens) and paced by P1's pump; the backend seam's new
`showCaption` defaults to the old heading-plus-body frame, so the Even G2 wraps the rows to its own
panel (8 × 44 cells holds the 340). Decided: DAT 1.0 has **no microphone glyph**, so
`.microphone` maps to `.threeDotSpeechBubble` ("someone is speaking") on the lens.

**Built 2026-11-11 (P5b, the turn arrow).** `HUDTurnArrow` (pure apart from the CoreGraphics draw)
maps the walking route's `Maneuver` to a bearing — ahead and the start 0°, bear left/right ∓45°,
turn ∓90°, U-turn 180°; a roundabout (which exit is in the words) and the arrival have none and keep
the line alone — and draws a white arrow on black in a 120 px square at the start of a **552 × 120
strip** (the thumbnail's reason: `.fill` would draw a bare 120 px square 552 px tall). Keyed by angle
(`lc.nav.arrow:-90`), drawn once per angle and kept. `HUDPicture` gained a `placement`; the arrow is
`.aboveLines`, so it leads its guidance line on the lens. `showNavigation(_:icon:arrow:)` sends the
line and arrow as an ambient screen only where `wantsGuidancePictures` (the HUD on, a display, a
backend that draws pictures, and the link not slow); otherwise exactly the old text frame, and it still
ends an answer card or the turn's card first. "No more than once a second" is the pump's own 1 s gap
after a picture; "text alone when the link is slow" is `HUDGuidancePicturePolicy`: a picture send that
failed, timed out, was retried as text or took over 1 s keeps the arrow off for 30 s.

**Built 2026-11-11 (P5c, timer and Now Playing cards).** Neither timer backend called the app back,
so `TimerCompletionWatch` hears them: a `set_timer` timer is watched in-process until it is due (its
due time is exact), and AlarmKit alarms through `AlarmManager.alarmUpdates` — only once alarms are
already authorised; nothing prompts — one card per ring. `HUDTimerCard` holds `HUDTimerCardBuilder`'s
card: **Timer done** / **Alarm**, the wearer's label, **Stop** (primary, focused) · **+5 min** · **Close**.
Stop removes the timer's delivered notification or stops the AlarmKit alarm; +5 min sets the same
label again five minutes on through the same backend (`TimerTool.scheduleNotification`, now shared,
or `AlarmKitScheduler`). It is a raised card (`presentRaisedCard`, `acceptsRaisedCard`): over nothing,
an answer card or the turn's card only; over a task card, menu, page view, approval card or clip it is
a five-second line; never on a dismissed lens; presses issued against the card as drawn; it closes
itself after 60 s. Not watched: the notification fallback for an alarm (a calendar trigger the app
cannot stop once delivered). **Now Playing** is under Today › Menu while the Music app has something
loaded: `HUDNowPlayingBuilder` draws the title (`HUDIcon.music`) and artist with **‹‹** · **Pause/Play**
(primary, focused) · **››** · **Close**, through `MediaPlayerLibrary` (the system player
`music_control` already drives), and redraws in place after a press (`HUDRouter.replaceTop`).
**Decided: no Vol − / Vol +.** iOS gives an app no supported way to set the system volume —
`MPMusicPlayerController.volume` has been deprecated since iOS 7, and moving `MPVolumeView`'s slider
from code is the private-API pattern App Review rejects — so the buttons would do nothing; volume
stays on the glasses' touchpad and the phone's buttons, and four buttons stay inside focus reach.
Another app's playback (Spotify, Podcasts) cannot be read or driven by a third-party app.

**Built 2026-11-11 (P5d, Home Assistant favourites).** Today › Menu › **Home** lists the wearer's
Home Assistant quick actions (`HUDHomeFavouritesBuilder`, the ones naming a service, while Home
Assistant is configured): five to a page with **More…** · **Back** · **Close**, the first focused. A
press runs it directly (`HomeFavouriteRunner` → `HomeAssistantTool.runFavourite`: the tool's Medical
egress, URL/token and Plan GS data-allowlist guards, no Conversation fallback, so the answer is yes or
no) and flashes **✓ name** / **Couldn't run name** / **Not run: name** over the list, which stays up.
The phone's quick action still goes through the model as before. An action the confirmation floor
holds (`HighImpactToolPolicy`: unlock, open a cover or garage, arm/disarm) is never run on one press:
it asks through `ToolConfirmationCoordinator`, which P2 draws as the approval card over the list.

**Built 2026-11-11 (P5e, teleprompter voice-follow).** **Turn whole pages** (Teleprompter › Pacing,
`Config.teleprompterPageFollow`, off by default) makes an audio-paced session hold a page still and
turn it when its last words are heard, instead of moving a line at a time (one send a page on the
Display). `TeleprompterPageFollow` (pure): a page starts at the cursor's word (so a page that ended
mid-line does not show the read half again) and holds what fits the window; its end is its last five
normalised words; `heardEnd(of:in:)` looks at the newest heard words only, needs the newest to be one
of the page's last two, and the tail in order among them with one miss allowed from four words up;
words match when they normalise alike, differ by a plural "s", or (four letters up) are one edit
apart. `TeleprompterPageFollower` sets aside the words that turned a page, so a growing partial
result turns one page, not several. **next** / **back** turn whole pages too; Lead does not apply. The
mic is the audio-paced mode's existing recognition shell on the shared engine, whose input follows
`Config.conversationMicRoute` (so Glasses Mic is the iPhone's while the Display is on). No gap: live
ASR was already wired for audio-paced sessions; voice-follow only changes what is done with it.

**Built 2026-11-11 (P5f, Field Assist clips).** `Procedure.Step` gained an optional `video_url`
(absent is no clip, left out when encoding), carried as `HUDStep.video` when `HUDVideo.playable`
accepts it — an absolute `https` URL whose path ends `.mp4`. The task card offers **Watch** (before
Back) only for such a step on a backend that `playsVideo`; the seam gained `playsVideo`,
`playVideo(_:onEnded:)` and `stopVideo()` (defaults: no, throw, nothing), so the Even G2, the web
mirror and the phone-only build never offer it. The Meta backend sends a root
`VideoPlayer(provider: .uri(_:), codec: .mp4, onError:)`, follows `Display.onPlaybackEvent` (ended,
stopped, error → once), and stops with `sendVideoStop()`. The service plays it over the held task card
(`playVideo`, `showsVideo`), draws the card again when it ends, stops or fails (a failure also flashes
"Couldn't play that clip"), and lets any other frame replace it. The clip has no buttons and the
band's Back ends the session, so "stop" (or "back", "close", "done") by voice stops it. Not done:
Meta's ≤ 400 px / ≤ 70,000 px limits are the clip author's — the phone never downloads the clip to
check — and no shipped vault procedure has a clip yet. The playbook task source has no video field.

## What LC leaves out

Gestures, voice launch and the HFP-free camera-audio mic (Plan JV, TestFlight-only); reading other
apps' notifications (iOS forbids it); band BLE reverse-engineering and raw EMG; always-on HUDs and
continuous countdowns; streamed viewfinder and video calls; face-recognition name tags.

## Decisions (taken by the owner 2026-11-11: "implementing all suggestions")

1. **Offer on connect, wearer chooses** (owner's words). Never auto-on.
2. **KP decision 8 stands:** the HUD switch is the wearer's explicit start; LC adds only that a session
   the glasses ended is not reopened by an ambient frame.
3. **Phone mic while the lens is on**, with a rollback setting.
4. **Approvals time out to Deny.**
5. **Today is summoned, never ambient.**

## Phases (one branch, one commit per phase)

- **P0** — the offer on connect.
- **P1** — hardening (focus, dismissal, exits, pacer, mic).
- **P2** — Approve / Deny cards. ✅ Built 2026-11-11 (§3).
- **P3** — listening/thinking states and the Today glance. ✅ Built 2026-11-11 (§4).
- **P4** — live-mode answer cards and vision thumbnails. ✅ Built 2026-11-11 (§5).
- **P5** — captions, navigation arrow, timer and media cards, Home Assistant list, teleprompter
  voice-follow, Field Assist clips. ✅ Built 2026-11-11 (§6; Vol −/+ dropped — no supported volume API).
- **P6** — device pass (owed, with KP P6 / KV P5): wake-on-send, native scroll, characters per line,
  focus reach in a six-button group, what the session reports for Back / two-finger tap / a call / the
  HFP mic, and measured send times.

## Acceptance

Headless tests for every pure piece and every builder; the simulated-Display lane draws each new
screen; no new `import MWDATDisplay` outside the files that already have one; no experimental symbol
anywhere (`DATExperimentalGuardTests` once JV P0 lands).
