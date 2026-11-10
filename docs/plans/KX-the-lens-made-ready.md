# Plan KX — The Lens Made Ready (offered on connect, hardened for the real Display, and the screens the ecosystem shows are worth having)

**Status:** 🚧 Drafted and building 2026-11-11, all phases headless. The device pass is owed and is folded
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

## What KX builds

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

### 4 · Listening → thinking → answer, and the Today glance (P3)

- **Listening** (the live partial transcript, at most one send per 0.4 s, the final always sent) →
  **Thinking** → the KP answer card, so the lens is never blank while the wearer waits. Only for a turn
  the wearer started and only while the lens is the wearer's (not over a task card or menu).
- **Today** becomes the launcher's root (L0): time and glasses battery, the next event, the weather,
  an active timer or route, the top digest item, then **What's new** (primary) · **Resume** ·
  **Navigate** · **Menu**. Summoned (voice "show my day", a temple-tap quick action, the Watch), never
  always on: the panel sleeps at 25 s and a session is the wearer's to start.

### 5 · Live-mode answers and the picture behind a vision answer (P4)

- The live and realtime modes (Gemini Live, OpenAI Realtime, Qwen, Doubao) put each model turn's
  transcript on the lens as a KP answer card at the turn's end — not word by word. KP and KV excluded
  them; with §2.5 they no longer fight the lens for the mic.
- A vision answer's first page carries a small thumbnail (≤ 552 px wide, ≤ 200 px tall) of the frame
  that was analysed, through KV's `HUDPicture` path, so the wearer sees what the answer is about and
  which camera took it.

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

## What KX leaves out

Gestures, voice launch and the HFP-free camera-audio mic (Plan JV, TestFlight-only); reading other
apps' notifications (iOS forbids it); band BLE reverse-engineering and raw EMG; always-on HUDs and
continuous countdowns; streamed viewfinder and video calls; face-recognition name tags.

## Decisions (taken by the owner 2026-11-11: "implementing all suggestions")

1. **Offer on connect, wearer chooses** (owner's words). Never auto-on.
2. **KP decision 8 stands:** the HUD switch is the wearer's explicit start; KX adds only that a session
   the glasses ended is not reopened by an ambient frame.
3. **Phone mic while the lens is on**, with a rollback setting.
4. **Approvals time out to Deny.**
5. **Today is summoned, never ambient.**

## Phases (one branch, one commit per phase)

- **P0** — the offer on connect.
- **P1** — hardening (focus, dismissal, exits, pacer, mic).
- **P2** — Approve / Deny cards.
- **P3** — listening/thinking states and the Today glance.
- **P4** — live-mode answer cards and vision thumbnails.
- **P5** — captions, navigation arrow, timer and media cards, Home Assistant list, teleprompter
  voice-follow, Field Assist clips.
- **P6** — device pass (owed, with KP P6 / KV P5): wake-on-send, native scroll, characters per line,
  focus reach in a six-button group, what the session reports for Back / two-finger tap / a call / the
  HFP mic, and measured send times.

## Acceptance

Headless tests for every pure piece and every builder; the simulated-Display lane draws each new
screen; no new `import MWDATDisplay` outside the files that already have one; no experimental symbol
anywhere (`DATExperimentalGuardTests` once JV P0 lands).
