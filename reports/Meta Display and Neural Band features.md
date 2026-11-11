# Harden the lens first, then fill the gaps

OpenGlasses already ships, at least headless, nearly every Display feature the wider ecosystem has converged on: AI answer cards, captions and translation, walking navigation, a teleprompter, step-by-step task cards, choice buttons, a launcher and manual pages. So the best value now comes from **three moves, not a catalogue of new apps**. First, make the existing HUD survive real hardware. Second, close a short list of genuine gaps that are cheap on the current `HUDScreen` seam. Third, keep anything that needs Neural Band gestures inside the TestFlight-only lane. The top store-safe additions, ranked by value-to-effort:

1. A hardening pass for platform rules the current stack does not yet follow. Display sessions must be started by the wearer; Back and a two-finger tap end the session; opening the glasses mic over HFP kills the display.
2. Interactive Approve/Deny cards for agent and send actions.
3. A summoned "Today" glance as the launcher's root screen.
4. Listening and thinking states, so the wearer is never left staring at a blank lens.
5. Answers from the live/realtime modes on the lens.
6. A "what I looked at" thumbnail on vision answers.

Captions and translation refinements, navigation arrows and maps, timer and media cards, Home Assistant controls and teleprompter voice-follow come next. On the experimental side, voice launch ("Hey Meta, open Avenkin"), swipe paging and the `MWDATSpeech`/camera-audio mic path have real value. They are buggy, unpublishable, and belong only in Plan JV's lane. Three facts gate everything. **Nobody on the team has Display hardware**. The App Store build is phone-only today (Plan IK). Meta has not opened submissions. Until then, any Display feature reaches only TestFlight glasses testers, so the first concrete step is a hardware validation pass, not new screens.

## OpenGlasses already covers the ecosystem's core list

Across Even Realities, Mentra, Rokid, RayNeo, Brilliant Labs and the roughly 40 open-source DAT Display apps on GitHub, the same dozen features recur. In rough order of evidence they are:

1. live captions
2. translation
3. a glanceable dashboard
4. notification triage
5. walking navigation and transit
6. teleprompter
7. AI answer cards
8. now-playing and lyrics
9. timers
10. agent approvals
11. memory cues
12. a long tail of readers, recipes, fitness and smart home

**Mentra's first-party set is the clearest statement of a default HUD**: captions, translation, notes, proactive AI, a dashboard, notifications, a teleprompter, maps, a recorder and a timer, all running at once over one connection ([MentraOS](https://github.com/Mentra-Community/MentraOS); [Mentra example apps](https://docs.mentraglass.com/app-devs/getting-started/example-apps)). On GitHub, the third-party DAT Display apps fall into a few groups ([awesome index](https://github.com/Javamomma/awesome-meta-ray-ban-display-apps)):

- assistants with reply cards, such as [hermes-glasses](https://github.com/prasanthsasikumar/hermes-glasses) (28★)
- captions and translation ([borderless](https://github.com/atlas-open-sources/borderless))
- navigation ([MultiSet](https://github.com/MultiSet-AI/wearable-vps-samples), 54★)
- step guides
- people-recall cards
- shopping lists
- sports gauges

Almost all are hackathon prototypes from August to November 2026.

Measured against that list, OpenGlasses is unusually complete. The repo has about 9,300 lines under `Services/Display` plus `GlassesDisplayService`:

- **Answer cards:** Direct-mode replies go to the lens as paged answer cards with actions and follow-ups (Plan KP, P0–P5 built headless).
- **Captions and translation:** ambient captions and translated captions (Plan BY).
- **Navigation:** turn-by-turn walking (Plan CA).
- **Task cards:** Now/Next cards for Playbooks and SOPs (Plan X).
- **Launcher:** a menu that also hosts a "What's new" digest glance (Plans Y and BZ).
- **Teleprompter:** a card with pace controls.
- **Choice buttons:** multiple-choice replies become buttons (Plan CG).
- **Manual pages:** a manual page or diagram drawn as a picture with zoom and pan (Plan KV, P0–P4).
- **Band check:** a Neural Band practice mode.

The architecture already does several things community apps learned the hard way. It has a backend-neutral `GlassesDisplayBackend` seam, a latest-wins render queue with `renderKey` dedup, a `frameRevision` stale-press gate, `DisplayAvailability` handling for another app taking the display, and a simulated-Display lane (`project.mock-display.yml`) that found four layout defects before merge. Of the MWDATDisplay primitives, `FlexBox`, `Text`, `Icon`, `Button`, `ButtonGroup` and `Image` are in use. Only `VideoPlayer` is unused (`openglasses_current_state.md`, §1).

| Ecosystem category | OpenGlasses today | Gap |
|---|---|---|
| Captions / translation | BY: phone and HUD captions, wearer-leg filtering | Layout budget, speaker labels, reply suggestions |
| AI answer cards | KP: paged card, actions, follow-ups (Direct mode only) | Live/realtime modes excluded; no listening/thinking states; no image |
| Navigation | CA: text maneuvers + arrival | No arrow or map image |
| Teleprompter | Card with % · wpm, pause, speed | No voice-follow (HZ out of scope) |
| Dashboard / glance | Launcher + BZ digest glance; "Today" only on Watch (KS) | No lens home card |
| Agent approvals | 10 s ambient "Approve?" line, voice-answered | No interactive Approve/Deny card |
| Timers / media / smart home | Services exist (AlarmKit plan JH, Music, HomeAssistant) | No lens surface |
| Step guides | X task cards, KV manual pages | `VideoPlayer` unused |
| Notification triage | Own sources only (reminders, geofences, digest) | iOS forbids reading other apps' notifications |

**The real gap is validation, not features.** No phase has run on a real Ray-Ban Display. The owed device passes are KP P6, KV P5, CG P3, GJ P2, BP P4 and JV P3. The shared `DeviceSessionCoordinator` is built but not wired. New features stacked on unverified assumptions about focus, scroll, sleep and session lifetime carry compounding risk.

## Six store-safe moves deliver most of the remaining value

Everything in this section uses only the stable DAT 1.0 surface: `MWDATDisplay` views, `Button` `onClick`, `FlexBox.onTap` and `.actionRole(.primary)`. In a store build, the Neural Band reaches the app only as a press on a rendered button. The Display firmware moves focus with a thumb swipe, and an index pinch fires the focused button's `onClick` on the phone ([iOS CHANGELOG](https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md); [hero-goggles README](https://github.com/save-the-world-org/hero-goggles-ios)). Every recommendation below therefore pairs band presses with voice, temple taps (`TempleActionResolver`) and the Watch, so no action depends on one input. That matters because reviewers report missed gestures when the hand is holding a bag or a steering wheel ([AOL review](https://www.aol.com/articles/meta-ray-ban-display-glasses-120000814.html)). The effort ratings are my estimates against the existing seams:

- **S:** days of `HUDScreen` composition
- **M:** one to two weeks of new wiring
- **L:** multi-week, or blocked on hardware

| Rank | Recommendation | Value | Effort | Risk | Hardware-gated |
|---|---|---|---|---|---|
| 1 | HUD hardening for real-device rules | High (enables all else) | S–M | Low | Partly; build now, validate on device |
| 2 | Interactive Approve/Deny cards | High | S | Low | No |
| 3 | "Today" glance as launcher root | High | S–M | Low | No |
| 4 | Listening → thinking → answer states | Med–High | S | Med (#342) | Mic policy yes |
| 5 | Live-mode answers on the lens | High | M | Med–High (#342) | Yes |
| 6 | Vision answer thumbnail + photo confirm | Med–High | S | Med (send cost, session sharing) | Yes |
| 7 | Captions/translation refinements | Med–High | M | Med | Yes (budgets) |
| 8 | Navigation arrow / minimap image | Medium | M | Med | Yes (image cost) |
| 9 | Timer and media cards | Medium | S–M | Low | Sleep behaviour |
| 10 | Home Assistant control list | Medium (HA users) | S–M | Low | No |
| 11 | Teleprompter voice-follow | Medium | M | Med (#342) | Yes |
| 12 | Field Assist clips via `VideoPlayer` | Low–Med (niche) | M | Med | Yes |

### 1. A hardening pass turns headless screens into hardware-ready ones

**Exists today:**
- the render queue and dedup in `GlassesDisplayService.swift`
- `MetaDisplayBackend.makeScreenView` emitting `ButtonGroup(alignment: .center)` of `Button(label:style:iconName:onClick:)`
- KP's Close inside the Actions screen
- a 60 s auto-clear
- the decision (KP decision 8) that wearers must start display sessions explicitly, though today "the first frame starts a session on its own"

**What changes.** There are six fixes:

1. **Explicit initiation.** Gate session start on a wearer action: launcher open, "show it on my glasses", Connect, or a temple-tap quick action. Use the pattern `CameraPermissionRequestPolicy.startedByApp {}` already uses for camera starts, so ambient producers can never open a session. Meta's overview states the user must explicitly start a display session ([Display access overview](https://wearables.developer.meta.com/docs/develop/dat/display-overview/)).
2. **Close on every non-root page, and a designated L0.** Every non-root screen gets an on-screen Close or Back. The launcher becomes the declared L0 root, because "Going back from L0 ends the session." On hardware, the band's Back gesture is never delivered: "the glasses handle Back themselves: they close your app on the glasses and end the session" ([iOS #349](https://github.com/meta/meta-wearables-dat-ios/issues/349)).
3. **A primary action on every interactive screen.** Mark one `.actionRole(.primary)`, because "the first primary action receives focus when content first renders" ([CHANGELOG](https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md)). The current-state survey records no primary roles, so verify this and adopt it. Because re-sending resets focus to the primary ([meta-glass-test STATUS](https://github.com/anoted/meta-glass-test/blob/main/STATUS.md)), make the likeliest next action primary. On page 1 of an answer that is Next; on a restored card after an AI-reply flash it is the action the wearer was on.
4. **A serialized send pump with metrics.** Allow one send in flight, latest wins. Space streaming text at least ~0.4 s apart and images at least ~1 s, with a send timeout and a text fallback. Record the last send's duration in the Developer panel and the support report, as Rathi Fitness does ([LensRenderer.swift](https://github.com/RATHI-CAPITAL-VENTURES/rathi-fitness/blob/main/app/RathiFitness/Model/LensRenderer.swift); [MultiSet GlassesDisplayPump.swift](https://github.com/MultiSet-AI/wearable-vps-samples/blob/main/iOS/MultisetWearable/MultisetWearable/HandsFree/Glasses/GlassesDisplayPump.swift)).
5. **Session end as dismissal.** Treat a session ended by the device as the wearer dismissing it, not as an error. Never auto-restart. Keep the state needed for "Resume" in the launcher.
6. **A mic policy.** While a display session is held, voice capture stays on the iPhone mic. The default idle listening already does this (Plan GU), but active turns must too. Bringing up the glasses' HFP microphone ends the display session on current firmware ([iOS #342](https://github.com/meta/meta-wearables-dat-ios/issues/342)).

**Value and evidence.** Every community app that reached hardware converged on these rules, independently: [BirdJournal DECISIONS.md](https://github.com/lightsailvr/BirdJournal/blob/main/DECISIONS.md), Hermes' serialized "newest queued view wins" pump ([HermesDisplayLogic.swift](https://github.com/prasanthsasikumar/hermes-glasses/blob/main/HermesGlasses/Services/HermesDisplayLogic.swift)), and MultiSet's rate-adaptive pump.

**Primitives and input.** `Button` + `.actionRole(.primary)` inside `ButtonGroup`, plus a Close `Button` on every non-L0 view. Voice "close" and temple taps already exist as equivalents.

**Effort and risk.** S–M, low risk. Most of it can be built and tested now in the simulated-Display lane, then confirmed in the first hardware pass.

**Learn from.** Meta's [display-access skill](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md), [BirdJournal](https://github.com/lightsailvr/BirdJournal), [hermes-glasses](https://github.com/prasanthsasikumar/hermes-glasses), [MultiSet](https://github.com/MultiSet-AI/wearable-vps-samples).

### 2. Approve/Deny cards are the cleanest fit for a pinch

**Exists today.** Approvals show as a 10-second ambient "Approve?" line answered by voice (`OpenGlassesApp.swift`). KP's Actions screen offers Send (`send_via`) and Save (`save_note`). Plan IA (agent choice questions, Agent Mode) is only drafted.

**What changes.** Every agent approval, outbound send, and remote-gateway or MCP action that needs consent becomes an interactive card:

- an `Icon` (warning or message)
- a heading naming the action ("Send to Sam?")
- a one-line preview
- `ButtonGroup { Approve (primary) · Deny · Details }`

The card stays up until answered, or until a timeout that defaults to Deny. Voice "yes/no" and a Watch confirm are equivalents. I recommend not mapping a temple tap to Approve, because an accidental tap would fire an irreversible action.

**Value and evidence.**
- Agent approval is among the most-replicated HUD patterns: [cc-g2](https://github.com/wmoto-ai/cc-g2) (33★, "approve or deny Claude Code prompts") and [claude-code-g2](https://github.com/sam-siavoshian/claude-code-g2) (38★) lead about 31 agent entries on the G2 list ([awesome-even-realities-g2](https://github.com/pangoleen/awesome-even-realities-g2)).
- On DAT, the sideline scorebook's "[Confirm] [Undo]" is the same "AI proposed, wearer confirms" shape ([FootballHUD.swift](https://github.com/jeremymatthewwerner/meta-glasses-sports-stats/blob/main/packages/SidelineCore/Sources/SidelineCore/Football/FootballHUD.swift)).
- hero-goggles reports dialogs of at most three buttons with the primary focused work well on hardware ([hero-goggles](https://github.com/save-the-world-org/hero-goggles-ios)).

The developer-heavy skew in that evidence is real. Even so, for OpenGlasses this covers Agent Mode, OpenClaw/Hermes bridges, `send_via` and Home Assistant actions, which are mainstream features of this app.

**Effort and risk.** S, low risk: the approval flow and `HUDScreen` buttons both exist.

### 3. A summoned "Today" card should be the launcher's root

**Exists today.** "Today" (Now Playing, calendar, weather) exists only on the Watch (Plan KS). My Day briefing (DY), WeatherKit and the BZ digest glance exist. The launcher (Plan Y) opens on a menu.

**What changes.** Make the launcher's L0 a glance card:

- a `.meta` header with time and glasses battery (from `GlassesConnectionService.batteryLevel`)
- the next calendar event
- the weather
- an active timer or navigation line
- the top one or two digest items
- `ButtonGroup { What's new (primary) · Resume · Navigate }`

Since L0 is now a real screen, Back from it ending the session is acceptable. The current `HUDIcon` set has calendar, location, reminder, message and others, but no weather or music glyph. So either check `IconName` for more glyphs, or draw small white-on-clear `UIImage` glyphs, as [ListLens](https://github.com/michaelcummingsofficial/listlens/blob/main/Sources/ListLensGlasses/GlassesScreens.swift) does for its checkboxes.

**Value and evidence.**
- Dashboards recur in every ecosystem: the four-quadrant Mentra Dashboard ([Dashboard](https://github.com/Mentra-Community/Dashboard)), Faceclaw's "Glanceboard" ([faceclaw](https://github.com/jimrandomh/faceclaw), 113★), and the G1 stock dashboard. Weather is the best-starred plain G2 utility ([weather-even-g2](https://github.com/nickustinov/weather-even-g2), 27★).
- Meta itself added Reminders, Calendar and Weather widgets in March 2026 ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-first-major-os-update-new-app-minigames-features/)). That confirms demand, and it means OpenGlasses' edge is personal context and its own sources, not the widget itself.

**Primitives and input.** `FlexBox` column of `Icon` + `Text` rows plus a `ButtonGroup`, summoned by voice ("show my day"), a temple-tap quick action or the Watch.

**Effort and risk.** S–M, low risk. The data sources exist. It cannot be always-on, because the panel sleeps at 25 s and sessions must be wearer-started.

### 4. Listening and thinking states fix the "blank lens" complaint

**Exists today.** "Got it — one sec" and "Didn't catch that" flashes; spoken Direct-mode replies mirrored by `TextToSpeechService.showText`.

**What changes.** A lifecycle like Hermes uses:

- a Listening card with the live partial transcript, throttled to about one send per 0.4 s, with final utterances always sent
- a Thinking card
- then the KP answer card
- choice replies held on screen while the wearer decides

([HermesDisplayLogic.swift](https://github.com/prasanthsasikumar/hermes-glasses/blob/main/HermesGlasses/Services/HermesDisplayLogic.swift))

**Value and evidence.** UploadVR's month-one review complained that content took 10 seconds or more to load "with no progress indicator" ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-review/)). Seeing a misheard transcript before waiting for an answer saves a full round trip.

**Primitives and input.** `Text(.meta)` state label, `Text(.body)` transcript, a Stop `Button`.

**Effort and risk.** S effort, medium risk: it only works if capture is on the phone mic (#342). That makes it a natural early hardware probe for the mic policy.

### 5. Live-mode answers are the biggest excluded surface

**Exists today.** KP and KV explicitly exclude the live and realtime modes (Gemini Live, OpenAI Realtime, Qwen, Doubao), even though those modes are flagship features.

**What changes.** At each model turn's end, feed the realtime transcript into the existing `HUDAnswerCardBuilder`, paged with follow-ups. Don't stream word by word; at most, push a throttled partial, as Casemate renders deltas no more than once per 350 ms ([LensCards.swift](https://github.com/Umang3211/casemate/blob/main/Sources/LensCards.swift)).

**Value and evidence.** Reviewers say Meta AI "trails leading models in complex reasoning" and that "you can't invoke other assistants" ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-review/)). HN users want their own model ([HN](https://brianlovin.com/hn/45140381)). An assistant whose best conversational mode never reaches the lens wastes the differentiator.

**Effort and risk.** M effort. Medium-to-high risk, because live modes hold the mic open continuously. This is where #342 bites hardest, so the phone-mic policy must be proven on hardware before this ships.

### 6. A thumbnail of "what I looked at" makes vision answers trustworthy

**Exists today.** KV's `HUDPicture` → DAT `Image` pipeline, with inverted drawings and accent marks. KP cards are text-only.

**What changes.** The first page of a vision answer carries a thumbnail of the analysed frame at 552 px or less, and photo capture flashes a "Saved" thumbnail. Because the HUD session currently forces the camera onto the iPhone (`MetaDisplayBackend.swift`), the thumbnail also shows the wearer which camera was used.

**Value and evidence.** Reviewers rank the viewfinder and photo capture second only to the band ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-review/)). Meta's BirdSpotter sample builds its whole card around a downscaled photo, "a photograph scaled past it is bytes the link carries for nothing" ([DatGlassesDisplayRepository.swift](https://github.com/meta/meta-wearables-dat-ios/blob/main/samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesDisplayRepository.swift)). BirdJournal uses 552×368 crops ([DECISIONS.md](https://github.com/lightsailvr/BirdJournal/blob/main/DECISIONS.md)).

**Caveat.** On an additive display, dark photo regions render transparent, so photos look ghostly. Keep the thumbnail small, and treat it as confirmation, not content.

**Effort and risk.** S effort, medium risk. An image costs about 155 ms per send against 47 ms for text ([Rathi Fitness](https://github.com/RATHI-CAPITAL-VENTURES/rathi-fitness/blob/main/app/RathiFitness/Model/LensRenderer.swift)), and session sharing is unwired.

### 7–12. Refinements and niche surfaces with real but narrower value

**7. Captions and translation refinements.**
- *Exists today:* Plan BY, with ambient captions and wearer-leg filtering, plus on-device ASR (SenseVoice).
- *What changes:*
  - a hardware-measured character budget, starting near the roughly 340 characters across 3 rows that the Vigilant Ear captioning app uses ([iOS #251](https://github.com/meta/meta-wearables-dat-ios/issues/251))
  - speaker labels in `.meta`
  - a mic-active `Icon` as a privacy indicator
  - a captions-only mode
  - Borderless-style reply suggestions: two `Button`s that speak the translated phrase aloud through the glasses ([borderless](https://github.com/atlas-open-sources/borderless))
- *To test:* whether top-aligning text in the 600×600 frame eases UploadVR's complaint that captions sit "below the sightline".
- *Why it's worth it:* Meta's translation launched with four languages ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-review/)), and headline features have been US- and English-first while hardware now sells in the UK, Canada, France, Italy and Germany ([Meta blog](https://www.meta.com/blog/meta-ray-ban-display-more-useful-more-people/)). Captions are also the most-replicated accessibility feature across ecosystems ([LiveCaptionsOnSmartGlasses](https://github.com/Mentra-Community/LiveCaptionsOnSmartGlasses); [awesome-rokid](https://github.com/Anezium/awesome-rokid); [Turbo-IO](https://github.com/Turbo1123/Turbo-IO)).
- *Effort:* M.

**8. Navigation arrow or minimap.**
- *Exists today:* Plan CA's text maneuvers.
- *What changes:* render a white-on-clear arrow at the bearing, as [hero-goggles GlassesCard.swift](https://github.com/save-the-world-org/hero-goggles-ios/blob/main/App/GlassesCard.swift) does, or a minimap through the KV picture path, as [MultiSet GlassesDisplayView.swift](https://github.com/MultiSet-AI/wearable-vps-samples/blob/main/iOS/MultisetWearable/MultisetWearable/HandsFree/Glasses/GlassesDisplayView.swift) does: a rotating map drawn slightly ahead to hide latency, at least 1 s per send, and a text fallback when the link is slow.
- *Why value is medium:* Meta's own walking directions now cover the US plus London, Paris and Rome, with cycling and transit announced ([Meta release notes](https://www.meta.com/help/ai-glasses/1809764829519902/); [Meta newsroom](https://about.fb.com/news/2026/09/new-features-for-meta-ray-ban-display-navigation-hologram/)). OpenGlasses' edge narrows to places Meta doesn't cover and to the app's own destinations and context.
- *Effort:* M.

**9. Timer and media cards.**
- *Exists today:* AlarmKit (Plan JH), the Music and Podcasts services, Watch Now Playing.
- *What changes:*
  - Timer: a completion card with `ButtonGroup { Stop (primary) · +5 min }`. Show the countdown when summoned, not continuously; whether a continuously visible timer survives the sleep is an unanswered question ([Android discussion #152](https://github.com/meta/meta-wearables-dat-android/discussions/152)). Large numerals need a phone-drawn image, because `Text` has only three styles.
  - Media: art `Image`, title `Text`, and `ButtonGroup { prev · play/pause · next }`, plus volume buttons. During any DAT session the band's pinch-and-twist volume gesture is suppressed ([iOS #330](https://github.com/meta/meta-wearables-dat-ios/issues/330)), so on-lens volume buttons fix a regression OpenGlasses itself causes.
- *Evidence:* Fahrplan's "Stops" for neurodiverse users ([Fahrplan](https://github.com/meyskens/fahrplan)), and 13 media entries on the G2 list.
- *Caveat:* Meta added timers in May 2026, so this is parity.
- *Effort:* S–M.

**10. Home Assistant controls.**
- *What changes:* a favourites list of tappable `FlexBox.onTap` cards in the DisplayAccess list shape, with state drawn as small images. Use the list rather than a `ButtonGroup`, because two-row button layouts and six-button focus reach are unverified.
- *Learn from:* [CarMaintenanceDisplay.swift](https://github.com/meta/meta-wearables-dat-ios/blob/main/samples/DisplayAccess/DisplayAccess/Samples/CarMaintenanceDisplay.swift), [ListLens](https://github.com/michaelcummingsofficial/listlens). Smart-home cards recur on Mentra, G2 and Display web apps ([awesome-meta-ray-ban-display-glasses](https://github.com/Binaire-0101/awesome-meta-ray-ban-display-glasses)).
- *Effort:* S–M, valuable only to HA users.

**11. Teleprompter voice-follow.**
- *What changes:* advance the page by matching phone-mic ASR to the script (Plan HZ, currently out of scope).
- *Evidence:* Mentra's teleprompter "scrolling follows your voice" ([Mentra docs](https://docs.mentraglass.com/app-devs/getting-started/example-apps)), and reviewers call the teleprompter the G1's best feature ([Tom's Guide](https://www.tomsguide.com/computing/smart-glasses/even-realities-g1-smart-glasses-review)).
- *Effort:* M. *Risk:* the mic policy again.

**12. `VideoPlayer` for Field Assist procedure clips.**
- *Constraints:* MP4 over HTTPS only, under 400 px per side and 70,000 pixels, one at a time ([Display overview](https://wearables.developer.meta.com/docs/develop/dat/display-overview/)).
- *Model:* Meta's own car-maintenance sample has a "Watch video" step ([DisplayAccess](https://github.com/meta/meta-wearables-dat-ios/tree/main/samples/DisplayAccess)).
- *Why it ranks last:* reviewers find video on a monocular display straining, local vault files would need HTTPS hosting, and HIPAA-mode content complicates that.
- *Effort:* M. Build only if a Field Assist customer asks.

One alternative route deserves a sentence. The Web HUD mirror (Plan BP) targets the glasses' built-in web view. Meta's Web Apps runtime gets the band as D-pad keys, Back via `popstate`, and the system handwriting/voice composer without any experimental DAT API ([meta-wearables-webapp AGENTS.md](https://github.com/meta/meta-wearables-webapp/blob/main/AGENTS.md)). That makes it the only non-experimental path to band text entry. It is a separate runtime, and BP P3 reachability is unresolved, so treat it as a later strategic option, not a near-term build.

## Experimental items stay in the JV lane, and three are worth probing

Nothing experimental exists in the repo today. There is no `Sources/Glasses/Experimental/`, no `project.experimental.yml`, and no `#if DAT_EXPERIMENTAL`. Plan JV is "drafted, nothing built". Meta's terms are unambiguous: `MWDATInputs`, `MWDATMotion`, `MWDATSpeech` and `VoiceInvocationsStream` "can be built and tested against, though apps using them cannot be published yet" ([CHANGELOG](https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md)). Inputs is available only in development and beta release channels ([DAT Inputs docs](https://wearables.developer.meta.com/docs/develop/dat/inputs/)). Under the project rules, everything below lives only under `Sources/Glasses/Experimental/` inside `#if DAT_EXPERIMENTAL`, is linked only by `project.experimental.yml`, and is never submitted. JV P0, the lane itself with `DATExperimentalGuardTests` and the archive check, is the prerequisite for all of it.

| Item | Value | Status of the API in the field | Recommendation |
|---|---|---|---|
| Voice launch, "Hey Meta, open Avenkin" (JV P1) | High: today "the wearer can't start us from the glasses at all" ([#267](https://github.com/meta/meta-wearables-dat-ios/discussions/267)) | Not delivered on release-channel builds ([#355](https://github.com/meta/meta-wearables-dat-ios/issues/355)); unmodified sample gets no `LaunchApp` ([#344](https://github.com/meta/meta-wearables-dat-ios/issues/344)); answered by Meta AI instead ([Android #228](https://github.com/meta/meta-wearables-dat-android/issues/228)) | Probe first; ship to testers only if it works on Dev Mode glasses |
| `MWDATSpeech` / camera audio as the HFP-free mic | High: Meta itself recommends in-stream camera audio for #342 ([#342](https://github.com/meta/meta-wearables-dat-ios/issues/342)) | Speech instances reported stopping at 199 callbacks ([#360](https://github.com/meta/meta-wearables-dat-ios/issues/360)) | Probe alongside the phone-mic policy; it decides how live modes coexist with the display |
| Inputs swipe paging: `nav` left/right for answer cards, teleprompter, KV pages; captouch double-tap mapped through `TempleActionResolver` (JV P2) | Medium | Subscribing `.neuralBand` takes the band's swipes from Display focus and native scroll ([BirdSpotter](https://github.com/meta/meta-wearables-dat-ios/blob/main/samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesSessionRepository.swift)); an empty `sources` set gave captouch only on hardware ([meta-glass-test](https://github.com/anoted/meta-glass-test/blob/main/STATUS.md)); Back never delivered ([#349](https://github.com/meta/meta-wearables-dat-ios/issues/349)); captouch double tap is safe during streaming ([#312](https://github.com/meta/meta-wearables-dat-ios/issues/312)) | Captouch first, as JV scopes; band only on screens where the app owns focus |
| Drag (pinch-hold-move) for continuous KV zoom/pan or push-to-talk | Medium | Measured at ~30 Hz, displacement about ±0.18 units, DOWN/UP bracketing a hold ([meta-glass-test](https://github.com/anoted/meta-glass-test/blob/main/STATUS.md)); inherently grabs the volume gesture ([#330](https://github.com/meta/meta-wearables-dat-ios/issues/330)) | Later; unverified as PTT |
| Motion head gestures (nod to confirm) | Low | Band IMU not delivered to DAT, only glasses ([meta-glass-test](https://github.com/anoted/meta-glass-test/blob/main/STATUS.md)); Motion stuck in STARTING ([Android #200](https://github.com/meta/meta-wearables-dat-android/issues/200)) | Skip |

Two cautions shape this lane. First, gestures fire on release ("Nav, Select, and Capture each produce one event per press, emitted on release"), so band gestures add latency, and there is no discrete band "hold" ([DAT Inputs docs](https://wearables.developer.meta.com/docs/develop/dat/inputs/)). Second, the lane's audience is small. Release channels cap at 100 testers ([Meta blog](https://developers.meta.com/blog/build-for-display-glasses/)), end users report being unable to enable Developer Mode ([#325](https://github.com/meta/meta-wearables-dat-ios/issues/325)), and JV's own open question is whether experimental features work outside Developer-Mode glasses at all. Reference implementations:

- [lukietee/DEAL](https://github.com/lukietee/DEAL): maps band select, back and nav onto card next/previous, merging phone buttons as a second input source
- [anoted/meta-glass-test](https://github.com/anoted/meta-glass-test): a hardware probe of every input channel
- Meta's BirdSpotter: [DatGlassesSessionRepository.swift](https://github.com/meta/meta-wearables-dat-ios/blob/main/samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesSessionRepository.swift)
- Meta's `inputs` skill: [SKILL.md](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/inputs/SKILL.md)

## Nine platform constraints should shape every screen

Each constraint below comes from Meta's docs or from Meta staff replies on the SDK issue tracker. "Today" describes what the repo does now (see `openglasses_current_state.md`).

| Constraint | Evidence | OpenGlasses today | What to do |
|---|---|---|---|
| 600×600 additive canvas: black is transparent, no fills for hierarchy | [Display overview](https://wearables.developer.meta.com/docs/develop/dat/display-overview/); [#251](https://github.com/meta/meta-wearables-dat-ios/issues/251) | `HUDCanvas.metaDisplay` 600×600; KV inverts drawings to light-on-clear | Draw white-on-clear glyphs; cap images at ~552 px wide; no large bright fills ([CARBON rules](https://github.com/RRfyOfficial/CARBON/blob/main/ios/Carbon/Glasses/Screens/GlassesScreens.swift)); keep photos small |
| Whole-frame replace; callbacks belong to the latest view; re-send resets focus | [display-access skill](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md); [meta-glass-test](https://github.com/anoted/meta-glass-test/blob/main/STATUS.md) | Latest-wins queue, `renderKey` dedup, `frameRevision` gate, flash-then-restore | Send only on real state change; choose the primary deliberately on every restore |
| No scroll API (native scroll contested) | [#251](https://github.com/meta/meta-wearables-dat-ios/issues/251), [#267](https://github.com/meta/meta-wearables-dat-ios/discussions/267) vs [BirdSpotter](https://github.com/meta/meta-wearables-dat-ios/blob/main/samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesSessionRepository.swift) | KP pages; 120-char ambient condensing; teleprompter 4×32 | Keep paging; measure real chars/line on hardware; test native scroll once, then decide |
| Dims at 20 s, sleeps at 25 s; no sleep-state API; unconfirmed whether a send wakes it | [Android #152](https://github.com/meta/meta-wearables-dat-android/discussions/152) (quoting docs) | 60 s answer auto-clear; held card redrawn on return | Re-send the held card on each new event (BirdJournal's hedge); no designs needing continuous visibility; test wake-on-send first |
| Back gesture and two-finger temple tap end the session; L0 Back ends it | [#349](https://github.com/meta/meta-wearables-dat-ios/issues/349); [Display iOS guide](https://wearables.developer.meta.com/docs/develop/dat/display-ios/) | Close only on some screens; band-check Back lesson never offered | Close on every non-root page; launcher as L0; treat session end as dismissal; offer Resume |
| HFP mic ends the display session; a BT audio recording can show a call UI over the app | [#342](https://github.com/meta/meta-wearables-dat-ios/issues/342); [#186](https://github.com/meta/meta-wearables-dat-ios/issues/186) | Idle wake word on iPhone mic (GU); active-turn route not confirmed | Formal policy: phone mic while a display session is held; probe camera audio/Speech in JV |
| Send cost and silent failure: ~47 ms text, ~155 ms for a 552×220 image; `send()` success ≠ rendered | [Rathi Fitness](https://github.com/RATHI-CAPITAL-VENTURES/rathi-fitness/blob/main/app/RathiFitness/Model/LensRenderer.swift); [#305](https://github.com/meta/meta-wearables-dat-ios/discussions/305) | Queue exists; no throttle or send metrics recorded in the survey | One in flight, ≥0.4 s text / ≥1 s images, timeout + text fallback, last-send time in support report |
| One session per device; camera and HUD must share | [BirdJournal](https://github.com/lightsailvr/BirdJournal/blob/main/DECISIONS.md) | Separate sessions; camera falls back to iPhone while HUD held; `DeviceSessionCoordinator` built, unwired | Wire the coordinator in the first hardware pass; until then say which camera answered |
| Volume twist suppressed during any DAT session; calls, notifications and Display Recording interrupt or blank content | [#330](https://github.com/meta/meta-wearables-dat-ios/issues/330); [#223](https://github.com/meta/meta-wearables-dat-ios/issues/223); [Display overview](https://wearables.developer.meta.com/docs/develop/dat/display-overview/) | `DisplayAvailability` handles `.inUse`, one busy hint per stretch | Release the session when idle so volume returns; volume buttons on media cards; never assume a frame was seen |

The table makes one design rule unavoidable. **The Display is a foreground, on-demand surface, never an ambient one.** The wearer opens it, it sleeps in 25 seconds, Meta's own events pre-empt it, and Back ends it. Faceclaw and Mentra's dashboards are always on; on Meta's display, the equivalent is something the wearer summons. The camera and HUD stack also has stability bugs that hit any combined feature: sessions ending seconds into streaming ([#332](https://github.com/meta/meta-wearables-dat-ios/issues/332)), and stream starts refused after a few minutes until a restart ([#375](https://github.com/meta/meta-wearables-dat-ios/issues/375)). One more repo-specific trap: `MWDATDisplay`'s `Text`, `Button` and `Image` clash with SwiftUI, and OpenGlasses already confines the imports to four files. Keep it that way.

## Don't bother with toys, iOS-impossible features or band hacking

| Skip | Why |
|---|---|
| Games, minigames, karaoke, anime companions, cat-mood captions | Demo-grade; Meta ships 2048 and GOAT first-party ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-first-major-os-update-new-app-minigames-features/)); no assistant value |
| Mirroring other apps' notifications, or turn-by-turn scraped from another nav app's notifications | iOS apps can't read other apps' notifications (the Android projects [OpenRayneo](https://github.com/Tobi1chi/OpenRayneo) and Fahrplan rely on Android); Meta announced first-party mirrored notifications with per-app opt-out ([Meta blog](https://www.meta.com/blog/meta-ray-ban-display-more-useful-more-people/)) |
| Reverse-engineered Neural Band BLE or raw EMG ([kinesis](https://github.com/callbacked/kinesis), [neural-band-poc](https://github.com/callbacked/neural-band-poc), RawMeta) | Needs factory reset and owner enrollment, built on Frida-instrumented Meta AI; terms-of-service and firmware-brick risk; unshippable |
| Meta's research EMG checkpoints ([generic-neuromotor-interface](https://github.com/facebookresearch/generic-neuromotor-interface), emg2qwerty) | Trained on 16 channels while the consumer band exposes 8; noncommercial terms ([runes_mac](https://github.com/Ben-Santana/runes_mac)) |
| Band handwriting or text fields in native DAT | Not exposed; only Web Apps get the system composer ([webapp AGENTS.md](https://github.com/meta/meta-wearables-webapp/blob/main/AGENTS.md)) |
| Always-on status bar, persistent HUD, continuous countdowns | No API; 25 s sleep; wearer must initiate |
| Live viewfinder streamed to the lens, video calls, general video playback | Bluetooth bandwidth, image send cost, monocular strain ([UploadVR](https://www.uploadvr.com/meta-ray-ban-display-review/)); Meta owns the viewfinder |
| Automatic face-recognition name tags | Highest privacy risk; the Meta Acceptable Use Policy text was not reviewed; low ecosystem engagement (≤12★) |
| Neural Band battery, haptics or settings | DAT exposes none (KP plan) |
| Custom fonts, transitions, animation | Unsupported ([discussion #206](https://github.com/meta/meta-wearables-dat-ios/discussions/206)) |

## Build in this order, with hardware as the gate

**Step 0 is acquiring or borrowing a Ray-Ban Display with a Neural Band.** The partner's KV P5 device is the obvious candidate. Then run one combined device pass that settles the open platform facts and retires the owed checks (KP P6, KV P5, CG P3, the band check). That pass should answer:

- whether a send wakes a sleeping panel
- whether Display content natively scrolls under band swipes
- real characters per line for each text style
- `Image` `.fill` sizing
- how far band focus reaches in a six-button `ButtonGroup`, and whether it wraps
- what the session reports when Back, a two-finger tap, a call or the HFP mic ends it
- measured send latency for text and for images

Wire `DeviceSessionCoordinator` in the same pass. Nothing past step 2 should merge as "done" until this pass has run.

**Step 1 is the hardening pass (recommendation 1), built now in the simulated-Display lane.** It covers explicit initiation, Close everywhere, the launcher as L0, primary roles, the send pump with metrics, and the phone-mic policy. The hardware pass then validates it, rather than a pile of screens built on guesses.

**Step 2 is Approve/Deny cards and the listening/thinking states (recommendations 2 and 4).** Both are cheap, headless-buildable and immediately useful on the Watch and phone mirrors too. That matters, because the App Store build carries no glasses SDK until Meta's production channel opens.

**Step 3 is the "Today" glance as the launcher root (recommendation 3).** It reuses My Day, WeatherKit, the digest and the Watch's KS data.

**Step 4, once the hardware pass has confirmed the mic policy and image cost, is live-mode answers and vision thumbnails (recommendations 5 and 6).** Captions budgets (recommendation 7) follow from the same measurements.

**In parallel, and only if a tester has Developer-Mode glasses**, build JV P0, then probe voice invocation and the Speech/camera-audio mic path before any gesture mapping.

## Conclusion

The ecosystem survey shifts the question from "which Display apps should OpenGlasses add" to "which platform truths has OpenGlasses not yet met". The feature map is already broader than any open-source DAT app. The real exposure comes from three behaviours no headless test can show: session-ending gestures, the HFP mic tearing down the display, and a panel that sleeps unobservably. A voice-first assistant meets all three on every turn. That makes the mic-route policy the decision with the most leverage in this report. It determines whether listening states, live-mode answers, teleprompter voice-follow and captions can coexist with the lens at all.

The second insight is competitive. Meta is closing the generic gaps fast: notifications, walking navigation, widgets, timers, teleprompter. Its own roadmap stays US- and English-first and routes third parties toward feeding Meta AI. OpenGlasses' durable edge on the Display is therefore what Meta structurally won't provide: the wearer's choice of model on the lens, confirmable agent actions, Field Assist procedures and manual pages, and captions and translation in languages and markets Meta hasn't reached. Build toward those, keep gestures in the TestFlight lane, and let the first hardware pass decide the details.
