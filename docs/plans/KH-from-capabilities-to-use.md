# Plan KH — From Capabilities to Use (what to try first, settings by what you want done, showing what it has learned)

**Status:** 📝 Drafted 2026-10-31. Nothing built.
**Track:** App-wide. Field Assist keeps its own guided flows and gets its own scenarios.
**Related:** Plan [HA](HA-settings-hub-and-org-lockdown.md) (the fixed hub, and the shelf it removed),
Plan [DE](DE-settings-capability-journey.md) (the journey HA retired), Plan
[EA](EA-voice-home-grid.md) (the home grid's canned turns), Plan [GW](GW-home-grid-pages.md) (grid
pages), Plan [IW](IW-goals-and-activity-trail.md) (Goals and Activity), Plan
[CT](CT-org-configuration-profiles.md) (organisation profiles), Plan
[JO](JO-watchers.md) (noticed, then offered), Plan [KI](KI-tasks-that-wait.md) (tasks that wait on
someone).

---

## Why

Greig, 2026-10-31: people get connected and then ask what they can do with it. "We've all these
capabilities, how do we turn them into features?" And on settings: "there's so much detail in the
settings, and tbh, they aren't grouped together well."

These are two problems. Settings says how to adjust the app, not what it is for, so a tidier Settings
alone will not answer the question people are asking.

**A capability is something the app can do. A feature is a situation, a result and what it needs.**
"Photo → Event" is a capability. "Photograph the school notice and the dates are in your calendar" is
a feature.

## Outcomes

1. **First win.** In the first session, someone does one thing useful in their own life, not a demo.
2. **A habit.** In week one they come back unprompted for the same job.
3. **The "more than my model" moment.** In week one, Avenkin uses something it remembered, or acts on
   their phone or their day.
4. **A one-line answer.** A user can say what it is for, and the "what next?" questions stop.
5. **Settings is optional.** People get value without opening it, and can find anything when they do.

Knowing every feature is not an outcome. The app has no analytics by design, so outcomes are checked
by watching new users and by the on-device count in P1, never by telemetry.

## What exists (verified 2026-10-31, main at 9f8ff22d4)

- **The Ready page sells configuration.** `OnboardingView.readyPage` lists voice, camera, "Switch
  personas for different AI personalities" and "Add more models or tweak settings anytime". The moment
  of highest interest points at Settings and offers nothing to do.
- **The how-to is filed behind the feature.** "Where did I park?" is in the Parking settings footer,
  "navigate to…" in the Navigation footer, "start [playbook name]" in Playbooks. You find the sentence
  only after finding the setting.
- **The grid is utilities, not situations.** `HomeGridCatalog` holds ten canned turns (Meetings, Tasks,
  Photo → Event, Photo → Task, Brief, Weather, Note, Timer, Scan Doc, Read Text). The turn pipeline is
  the right one: a tile submits a turn the wearer could have spoken, through
  `HomeGridSession.submitHomePrompt` / `submitHomePhotoPrompt`, and calls no tool itself.
- **`discover_capabilities` is written for automation.** It lists Shortcuts, apps, tools and tasks,
  and tells the model to propose scheduled tasks. It is not an answer to "what can you do for me?".
- **`docs/CAPABILITIES.md` is by ability**, in nine sections, and is not in the app.
- **The promise of learning is mostly off by default.** User Memory is on, so "remember that…" works.
  Memory Suggestions (`memoryNudgesEnabled`) is off, so nothing offers to remember. Memory Enrichment is
  off and needs Agentic Features and a cloud model. My Day is off. A person who never opens Settings
  sees an assistant that remembers only when told to.
- **Settings is grouped by how it was built.** The hub has 13 categories and the code has 151 `Toggle(`
  call sites in 58 files, before `InfoToggle` and switch rows.
  - Memory's switches sit under AI & Personality › How It Behaves, beside Intent Classifier.
  - Goals and Activity are also under AI & Personality.
  - My Day is under Connections › Works with your iPhone.
  - Navigation, Parking, Music and Translation are under Connections › Services & Integrations, a
    1,167-line screen that also holds voice engines, web search, camera, recording and streaming.
  - AI Smart Home Control and AI Messaging are under Works with your iPhone › AI Access.
  - Health and First-Aid Coaching are on the Devices & Privacy hardware screen.
  - Scheduled tasks open only from Agentic Features.
- **Two constraints on any regroup.** Category raw values are stable, because a profile names them
  (`SettingsCategoryID`: "never change one"). A managed phone locks by category
  (`ManagedLockdown.lockedCategories`) and by key (`SettingKey`), and hides locked rows
  (`SettingsVisibilityPolicy`).

## Decisions

1. **Scenarios are data, in one catalogue.** First-run choice, Voice tab cards, the Things to Try list
   and the spoken answer all read it.
2. **A scenario is a turn the wearer could have said**, submitted through the grid's existing seam. It
   calls no tool and adds no capability.
3. **Nothing on the home screen is permanent.** Plan HA removed the Discover shelf because "the
   suggestions always being there looks crap". Cards leave when tried or dismissed, and the shelf ends
   for good after three.
4. **A scenario never promises what this phone cannot do.** Each declares what it needs, and a test
   checks every named tool exists. A setting that switched on a behaviour the app never had has already
   been removed once (Expressive Voice, Plan HR).
5. **Phone first.** The general set works with no glasses. A glasses scenario appears only with
   glasses added.
6. **A parent toggle covers one consent.** Turning a parent off turns its members off. Turning it on
   restores what was on, and never turns on a separate-consent member for the first time.
7. **These never go under a parent:** face recognition, Agentic Features, sharing health data with the
   AI. Memory Enrichment is shown in the Memory group but keeps its own switch, because it sends turn
   text to the provider.
8. **A parent never writes a locked key** and never overrides HIPAA's hard-disable. A locked member is
   not drawn. A group whose members are all locked is not drawn.
9. **Parents write through the existing setters.** Side effects such as starting the agent scheduler
   stay where they are.
10. **No new home for how-to copy in rendered strings beyond the catalogue.** Settings footers stay.
    No plan letters in any rendered string.

## Rejected

- **Grouping alone.** It reduces the fear, not the question.
- **A tour or feature walkthrough.** It explains capabilities before anyone has a need for them.
- **Default Simple Mode on.** Plan DE already ruled this out: it is a caretaker lock, and leaving it
  needs Face ID.
- **Bringing back folding on the hub or the Discover shelf.** Accordions go inside screens and carry
  no pitches.
- **Renaming or merging category ids.** Profiles name them.
- **A cloud-side recommendation or usage telemetry.** Contradicts the app's no-analytics position.
- **Listing all tools in the app.** Same mistake as the question it is meant to answer.

## Phases

One PR per phase, against the usual one PR per plan: each delivers on its own, and P2 changes what
managed phones show, so it should be reviewable alone. P1 goes first because it answers the question
people are asking.

### P0 — Check the scenarios on paper (no code)

Send the draft list below to the people who asked. Ask which they would try this week and what is
missing. Drop what nobody picks. This tests the riskiest assumption, that these situations are theirs,
before anything is built.

### P1 — Things to try

**Core (headless):**
- `Sources/Services/Scenarios/ScenarioCatalog.swift`: pure data. Each `Scenario` has a stable id, an
  intent (`everyday`, `seeing`, `gettingAround`, `work`, `field`), a title, one line of situation, a
  `HomeGridAction.Kind`, a prompt and its needs.
- `ScenarioReadiness`: pure. From a value context (available tools after `disabledTools` and an
  organisation's closed tools, glasses added, HIPAA mode, Simple Mode, Field Assist active, memory on)
  gives ready, needs one named setup step, or hidden.
- `ScenarioShelfPolicy`: pure. Picks at most three cards: chosen intent first, ready before needing
  setup, untried only. Ends the shelf after three tried or dismissed.
- `ScenarioProgress`: on-device record of tried and dismissed ids. Registered in `DataStoreRegistry`
  and covered by erasure.

**Surfaces:**
- **Ready page.** Replace the four rows with "What do you want it for first?" and the intents, each
  starting a real turn on "Try it now", with a quiet skip. No new page, so `OnboardingFlow.Page` and
  `OrgFirstRun`'s index are unchanged. A managed or Field Assist first run shows the field scenarios.
- **Voice tab.** Cards in the transcript's empty state (`TranscriptOverlay`), so they never compete
  with a conversation. Tap runs the turn. Each dismisses individually and works with VoiceOver.
- **Things to Try.** The full list, by situation, one row in the hub beside About.
- **"What can you do for me?"** `discover_capabilities` gains a `scenarios` category that returns ready
  scenarios in plain words, and its description says to use it for that question. Check it is exposed
  under on-demand tool definitions and in `FieldToolProfile`.
- **Support report.** One line, "Things to try: 3 of 12", a count with no content.

**Tests:** every named tool is registered; every id unique and stable; general set needs no glasses;
locked or closed tools hide a scenario; HIPAA hides any scenario that would leave the phone; shelf
never exceeds three and stays ended; no plan letters in strings; all copy goes through `String(localized:)`.

Catalogue strings are committed on their own, per the catalog rule.

### P2 — Settings by what you want done

**Core (headless):**
- `SettingsGroupCatalog`: pure data. Group id, title, members. Each member is `.follows`,
  `.separateConsent` or `.link`, and names its `SettingKey` where it has one.
- `SettingsGroupState`: pure. Gives the summary ("On · 3 of 4", "Off") and the writes for a parent
  change, with remembered member states. Enforces decisions 6 to 8.
- One new category, `everyday`, shown after Voice & Triggers. No existing id changes, and the hub stays
  one fixed list. It is locked by default on a managed phone, because `ManagedLockdown` locks every
  category not listed as open. `shownInSimpleMode` is false, matching where the rows are today.

**Groups (all rows move, none is rewritten):**

| Group | Members | From |
|---|---|---|
| Memory | User Memory, What Avenkin Remembers, Conversation History, Memory Suggestions, Goals, Activity; Memory Enrichment as separate consent | AI & Personality |
| My Day & Routines | My Day, leave-by, scheduled delivery; a link to Scheduled Tasks | Connections; Agentic Features |
| Getting Around | Navigation, Parking | Services & Integrations |
| Home, Music & Messages | AI Smart Home Control, AI Messaging, Music, Home Assistant | Works with your iPhone; Services & Integrations |
| Translate | Translation | Services & Integrations |
| Health & Fitness | Health, First-Aid Coaching; sharing with the AI as separate consent | Devices & Privacy |

The switch rows live in one place only, so nothing is on two screens. Scheduled Tasks stays gated by
Agentic Features, and its link says so.

**Also in P2:** Intent Classifier becomes a plain-words row ("Ignore nearby chatter") under Voice &
Triggers. Services & Integrations keeps the engines and keys it still holds.

**Tests:** extend `SettingsHubTests` and `SettingsVisibilityPolicyTests`. A profile that opened
`connections` or `intelligence` must be checked against the moved rows, and the review sheet must say
what it now covers. A profile naming `everyday` must not break an older build. Parent on never enables
a separate-consent member. Parent never writes a locked key. Accessibility's guarantees are unchanged.

### P3 — Suggestions that learn, and offers that follow through

**What it has learned:**
- **Offer to remember by default on a new install.** Memory Suggestions on for fresh installs, with
  `CapabilityDefaultMigration`'s rule that nobody's existing choice moves. It is spoken, confirmed by
  voice, and only filed on a yes. Owner decision, see Open.
- **`LearningRecap`:** pure composer over memory facts and the Activity trail. "This week I learned 4
  things about you and did 11 things for you", each one openable. On-device only, no new egress.
- **Where it appears:** a My Day row when My Day is on, and by voice ("what have you learned about
  me?"). A first memory-backed answer gets one line pointing at What Avenkin Remembers, once.
- **Copy says what is true.** Retrieved is not the same as used, so no "from memory" badge on an answer
  unless a turn can show the fact was used.

**Personal suggestions:**
- **`ScenarioRanker`:** pure and on-device. Reorders the catalogue by each scenario's `topics`, from what
  has been used, remembered and dismissed. It only reorders: it writes no scenario, so it cannot
  promise what the app cannot do. It changes Things to Try and the spoken answer. The home shelf still
  ends for good.
- **A "Personalise suggestions" switch,** on by default because nothing leaves the phone. It sits on
  Things to Try and moves to the Memory group with P2. Off returns the catalogue order, deletes nothing,
  and also stops learned offers. It is off whenever User Memory is off.

**Offers and plans:**
- **Offer templates:** fixed wordings with a gap for a learned detail ("You mentioned the dentist on
  Tuesday."). The template opens the conversation; it is not the limit of what happens next, because
  yes starts a normal turn and the agent may chain tools.
- **A plan summary before a chain.** When a chain has several steps or reaches outside the phone, the
  agent says what it will do, briefly, and you confirm, trim or clarify. One-step requests just happen.
  Spoken plans are one breath; with the phone in hand it is a list you can edit.
- **Yes covers the plan, not the send.** The message does not exist yet when you approve, so you still
  see the final text. Each step's own rules still apply. If a step fails or finds two answers, it stops
  and asks. Each step shows in Activity.
- **Corrections teach it.** "Skip the email, I'll call" feeds the ranker.
- **Outside Agent Mode there is no planner.** `LLMService` reaches `AgentPlanner` only with Agent Mode
  on, so the summary is the model's own turn, from prompt guidance. A background chain needs Agent Mode.
- **Web findings stay unconfirmed.** First check whether web text can reach memory during a normal turn
  today. Findings are filed as `provisional` with their source until you confirm them, page text is
  never an instruction, a search carries no name or reason for the visit, and HIPAA mode stops before a
  web search. This is the part to review hardest.

### P4 — Scenarios that move goals

A goal says where you are going; a scenario is the next useful move. Goals already picks a next step,
offers a `StepAction`, and suggests when a step looks done (Plan IW).

- **Stages:** try a scenario; repeat it and get offered a routine; related requests lead to "want to
  make it a goal?"; a goal's next step picks the scenario that moves it; a finished goal raises those
  topics, and dismissed ones fade.
- **`Scenario.moves`:** the `StepAction.Kind` a scenario performs. `GoalScenarioMatcher`, pure and
  rule-based with no model call, matches it to `GoalAdvancePolicy.nextStep`. A due step offers a
  calendar hold; a stalled step offers to break it down.
- **No new home shelf.** It appears in My Day's goal line, on the Goals screen, and in "what's next?".
- **It only offers.** The assistant never runs a step unasked, and the Personalise switch covers it.
- **Order:** the next-step match and finish signals first. Repeat and goal spotting last, because they
  speak up unprompted, and their rules should be tuned from real use.
- **Limits today:** goal check-ins need Agent Mode, which is off by default, and My Day is off by
  default. Without them these offers appear only on the Goals screen or when asked. Plan IW's device pass
  is still owed, so nobody knows yet how Goals is used.

Tasks that wait on someone else are Plan [KI](KI-tasks-that-wait.md), which starts from P3's plan summary.

## Draft scenarios (for P0)

| Situation | What you do | Needs | What it shows |
|---|---|---|---|
| Before you leave the house | "Brief me on my day" | Calendar, reminders, location | Reach across your day |
| A paper notice or invitation in your hand | Photograph it, the event is added | Camera, calendar | Acts, not just answers |
| A bill with a due date | Photograph it, a reminder is added | Camera, reminders | Acts, not just answers |
| Something you keep having to look up | "Remember that…", then ask in a new conversation | Memory | It remembers you |
| Coming back to the car | "Where did I park?" | Location | Everyday recall |
| A sign or menu in another language | Show it and ask | Camera, translation | Sees and helps |
| An errand you will forget | "Remind me when I get to the shop" | Location, always | Works when you are not asking |
| After a meeting with captions on | "Summarise that meeting" | Captions | Turns talk into notes |
| Hands full at home | "Turn off the lights" | Home access | Does what Siri does, in your words |
| An appliance or gadget manual | Add it and ask a question | My Manuals | Answers from your documents |
| Field Assist, first job | "Start a job" | Field Assist | The guided job |
| Field Assist, a question on site | Ask the vault | Field Assist vault | Cited answers |

Each needs checking against its tool during P1. Voice phrases follow what the tools actually accept.

## Acceptance

- **P0:** at least half the scenarios are picked by someone who asked the question, and the list is
  revised from the answers.
- **P1:** a new install reaches a real, useful turn from the Ready page. An offline or phone-only user
  is never shown a card that cannot run. A new user watched without help finishes one scenario.
- **P2:** a person can find Memory, Parking and Health without opening a wrong category first. A
  managed phone shows nothing it did not show before, except where a profile is deliberately updated.
- **P3:** within a week of normal use a tester can say something it learned, unprompted.
- **Device:** Ready page and Voice tab cards on a phone with VoiceOver, on a managed phone, and in one
  right-to-left language.

## Open

1. **Who is asking?** This plan assumes general phone users. If they are mostly technicians, P0's list
   and the first-run choice should lead with the job day.
2. **Name of the `everyday` category.** Its title is free to change, its raw value is not.
3. **Memory Suggestions on by default (P3).** It delivers the promise, but it speaks up unprompted.
   Owner's call.
4. **Does a profile that opened `connections` or `intelligence` also open `everyday`?** Recommended:
   no, the organisation chooses, and the review sheet says so.
5. **Website and store copy.** Outcome 4 needs one sentence for what Avenkin is for. This plan does not
   write it, and the scenarios that land in P0 should inform it.
