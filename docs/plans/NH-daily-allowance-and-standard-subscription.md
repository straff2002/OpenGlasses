# Plan NH — Daily Allowance and the Standard Subscription (15 minutes of the assistant a day for everyone, unlimited for subscribers)

**Status:** 📝 Drafted 2026-11-25. Nothing is built. 13 [decisions](#decisions-for-greig), each with a
recommendation.
**Track:** Consumer pricing. The phone-only App Store build first; the glasses build gets the same rules.
**Builds on:** Plan [GB](GB-field-test-round-3.md) P5 (the spend cap: a pure policy and a gate in
`LLMService` that answers a turn instead of sending it), Plan [JK](JK-my-manuals.md) (the My Manuals
subscription and its paywall), Plan [MH](MH-app-store-compliance-gaps.md) P0 (the trial and price line on
every paywall), Plan [A](A-accessibility-tier.md) (accessibility is never charged for).
**Prices:** set in App Store Connect and the local `.storekit` only, never in this plan or any PR text.

---

## Trigger

The owner, 2026-11-25, preparing the first App Store submission. Personal users were going to pay once
for the app. Ongoing maintenance means it has to be a subscription instead: **15 minutes a day free across
the whole app, and a monthly Standard subscription for no limit** (the intent first recorded 2026-11-20).
The Field Assist solo prices were set the same day. Nothing on `main` meters anything: there is no
allowance, no Standard product and no paywall for one. The Standard subscription can't be sold until this
is built, because a subscription has to unlock something.

## Outcome

- A new user downloads the app for free, picks a model and talks to it. The Home card's status line shows
  *14 min left today* once they've started.
- With 3 minutes left the line turns amber. When the minutes run out, the reply that was in progress
  finishes, and the next request is answered with: *"That's today's 15 free minutes. Unlimited is in
  Settings, under Subscription, or the minutes come back at midnight."* The subscription sheet opens on
  the phone. From Siri, the Watch or CarPlay the line is spoken and a notification opens the sheet.
- A Live session that reaches zero gets one spoken warning, finishes the answer it's giving, and closes 60
  seconds later.
- A subscriber never sees a counter.
- Someone using VoiceOver, or with Accessibility or the assistive modes switched on, never sees a counter.
- Anyone asking for first aid is never counted and never refused.

## What exists (verified 2026-11-25 on `origin/main` 4d70cafe1)

- **A gate in the right place.** `LLMService` checks `spendCapOutcome(utterance:config:)` on every turn
  before sending it: the turn proceeds, proceeds with a notice, or is answered with a line and never sent.
  `SpendCapPolicy` is pure and `SpendCapGate` applies it. The allowance gate goes beside it, in the same
  shape.
- **Live sessions don't pass that gate.** `GeminiLiveService.connect()`, `OpenAIRealtimeService.connect()`
  and `DoubaoRealtimeAdapter` open their own sessions. They need a gate at connect and a meter while open.
- **Usage counting exists but counts money.** `UsageTracker`/`UsageStore` record tokens and dollars per
  provider. `RealtimeUsage` extracts tokens from live sessions. Nothing records time.
- **StoreKit.** `StoreKitService` knows the Medical, Field Assist and My Manuals products.
  `SubscriptionOfferTerms` and `offerTerms(for:)` give every paywall its trial and price line. The local
  `.storekit` has a `My Manuals` group of its own, not the one level below Field Assist that the My
  Manuals plan intended. It also holds placeholder prices (Field Assist monthly and annual equal, My
  Manuals annual far below monthly).
- **Who is a subscriber or licensed.** `FieldAssistEntitlement` (solo, team, enterprise, licence codes and
  org profiles), `isMedicalComplianceActive` and `myManualsSubscription`.
- **Accessibility.** `Config.accessibilityModeEnabled` is a plain user toggle, and the assistive modes live
  under `Services/Accessibility`. Plan A's rule is no product id, no entitlement check and no paywall for
  accessibility.
- **First aid.** `FirstAidAssistService`, `CPRMetronome` and `AEDFinder`.
- **Which build is running.** `AppBuildIdentity` tells a store install from TestFlight (`sandboxReceipt`).

## Design

### 1 · What a minute is

The allowance counts **assistant time**: time the assistant is working for you.

- **A turn** (typed, spoken, from Siri, the Watch, CarPlay or a shortcut) counts from the moment it is sent
  to the model until its reply has finished, either spoken or, if silent, shown. Tool calls inside the turn
  are part of it. Each turn counts at least 5 seconds and at most 3 minutes, so a stuck turn can't drain the
  day.
- **A Live session** counts every second it is connected.
- **Not counted:** listening for the wake word, on-device captions and the meeting recorder while they only
  record (their summary is a turn), alarms, timers, music, navigation guidance and anything else that runs
  no model.

Every provider counts the same, whether a cloud model on the user's own key, a local model or Apple
Intelligence (decisions 2 and 3). The subscription pays for the app, not for compute.

### 2 · Never counted, never refused

`AllowanceExemption` is pure. It answers *exempt* when any of these hold:

1. **A paid tier or licence:** Standard, My Manuals, Field Assist at any tier (store or licence code),
   Medical Compliance, or an organisation profile.
2. **Accessibility:** VoiceOver is running (`UIAccessibility.isVoiceOverRunning`), Accessibility mode is on,
   or an assistive mode is active. A sighted user could switch the toggle on to avoid the meter. That is
   accepted (decision 4).
3. **First aid:** the turn is routed to first aid, or a CPR or AED session is running. The gate runs after
   first-aid routing, so an emergency phrase is never metered or refused, even at zero.
4. **TestFlight and Xcode builds,** unless the developer setting **Meter as a store build** is on
   (decision 9).

### 3 · The ledger

`AssistantTimeLedger` keeps seconds used per local calendar day, on the phone only, file-protected, and
part of the subject-erasure walk. The day resets at local midnight. Changing the clock or reinstalling can
reset it, and that is accepted (decision 10). It is not stored in iCloud and never leaves the phone.
`DailyAllowancePolicy` is pure. It takes seconds used, the allowance (900), exemption and the clock, and
returns `.proceed`, `.proceedWithNotice(remaining)` below 3 minutes, or `.exhausted`.

### 4 · The gate

- **Turns:** `allowanceOutcome` runs in `LLMService` beside `spendCapOutcome`, before the turn is sent.
  `.exhausted` answers the turn with the line and sends nothing, the same way the spend cap answers. A
  turn that started under the limit always finishes.
- **Live:** the gate runs at `connect()`. While a session is open, a one-second tick charges the ledger. At
  60 seconds left, one spoken line. At zero, the answer in progress finishes, the session closes 60 seconds
  later at most, and the line is said.
- **Background and other surfaces** (Siri, the Watch, CarPlay, the widget, Live Activity buttons): the
  line is spoken or returned as the reply, and a notification opens the subscription sheet. Nothing waits
  for hidden UI. That matches the cloud-sharing consent rule.

### 5 · The Standard subscription

- **Products:** `com.openglasses.standard_monthly` and `com.openglasses.standard_annual`.
- **One subscription group for the ladder** (decision 7): Standard, then My Manuals, then Field Assist
  solo, lowest to highest. Moving up or down prorates. The My Manuals products move into the group from
  their own one. Medical Compliance stays its own group and also includes unlimited.
- **No free trial on Standard** (decision 13). The daily allowance is the trial.
- **The paywall** reuses the My Manuals paywall's layout: what Standard includes ("No daily limit"), the
  price and period from StoreKit, `SubscriptionOfferTerms`, Restore, and the Privacy and standard EULA
  links. It opens from the exhausted line, from **Settings › Subscription** and from the minutes line on
  Home.
- **Settings › Subscription** shows the current plan, minutes used today and the plans above it.

### 6 · What the user is told

- **Home card:** *n min left today* once a turn has run today. Amber below 3 minutes. Hidden when exempt.
- **The exhausted line** (above), spoken in voice modes, as a reply in chat.
- **Review notes:** one line saying the free allowance, what counts and the exemptions, with a sandbox
  account to show the paywall. The notes are at their byte limit, so P1 trims to fit.
- **Privacy:** no new egress and no new data type. The ledger never leaves the phone, so the manifest and
  in-app copy say nothing new.

## Phases

One PR each.

### P0 — The core (headless)

`DailyAllowancePolicy`, `AllowanceExemption`, `AssistantTimeLedger` and the per-turn floor and ceiling, all
pure or injected, with the clock, the build channel, the entitlements and the accessibility signals passed
in. Tests:

- the midnight reset and its time zones;
- the 5-second floor and the 3-minute ceiling;
- each exemption, alone and combined;
- first aid at zero;
- the notice threshold;
- a turn that starts at 1 second left and finishes;
- the subject-erasure walk.

### P1 — Wiring, products and paywall

- **The gates:** the turn gate in `LLMService`; the Live gate, tick and close in the three live sessions;
  and the refusal on each surface.
- **StoreKit:** the products in `StoreKitService` and the one subscription group. The `.storekit` gets the
  Standard products, the corrected Field Assist and My Manuals figures, and the group move.
- **Screens:** the paywall, **Settings › Subscription**, the Home line, and the developer setting.
- **Review notes:** the trimmed notes with the allowance line.
- **Tests:** the gate never sends an exhausted turn; a Live session at zero closes after its grace; an
  exempt user never sees a counter.

### P2 — String catalog sync

The lines, the paywall and the settings page in all 13 languages, add-only.

### P3 — Sandbox and device pass (owed)

On the phone-only archive with a sandbox account:

- use 15 minutes and see the line, then subscribe and see the counter go;
- restore on a second phone;
- let the sandbox subscription expire and see the counter come back;
- turn on VoiceOver: no counter;
- ask for first aid at zero: it answers;
- run Live to zero: one warning, then a clean close;
- ask Siri at zero: the line is spoken and the notification opens the sheet.

## Decisions for Greig

1. **What counts is assistant time, as §1 defines it**, not turns or tokens. *Recommended:* yes. It is the
   "15 minutes" the owner named, and it treats a long Live chat and many short questions the same way.
2. **Local models and Apple Intelligence count too.** *Recommended:* yes. The subscription pays for the
   app, and one rule for every model is easier to explain and harder to game.
3. **Cloud models on the user's own key count too.** *Recommended:* yes, for the same reason.
4. **Accessibility exempts the whole user**, when VoiceOver is running, Accessibility mode is on or an
   assistive mode is active, accepting that the toggle can be misused. *Recommended:* yes. A blind user's
   weather question is as much accessibility as a reading request, and policing the toggle would put a
   check on accessibility, which Plan A rules out.
5. **First aid is never counted and never refused.** *Recommended:* yes.
6. **Every paid tier and organisation licence includes unlimited.** *Recommended:* yes.
7. **One subscription group: Standard, then My Manuals, then Field Assist solo.** My Manuals moves out of its
   own group, and Medical stays separate with unlimited included. *Recommended:* yes. Upgrades prorate, and
   a user is never charged twice for the same thing. My Manuals stays its own tier above Standard rather than
   folding into it.
8. **The app is a free download**, with no upfront price. *Recommended:* yes. An upfront price plus a daily
   limit charges twice.
9. **TestFlight and Xcode builds are unmetered**, with a developer setting to meter them for testing.
   *Recommended:* yes. Sandbox subscriptions renew daily and stop after six renewals, which would lock
   testers out.
10. **Stored on the phone only, reset at local midnight; reinstalling or changing the clock can reset it.**
    *Recommended:* yes. Anything stronger needs an account or a server, which the app doesn't have.
11. **At zero, the current turn finishes and a Live session gets 60 seconds of grace.** *Recommended:* yes.
    Cutting off mid-answer is the worst way to meet a limit.
12. **An annual Standard product as well as the monthly.** *Recommended:* yes. The figure is set in App
    Store Connect.
13. **No free trial on Standard.** *Recommended:* yes. The daily allowance is the trial, and it keeps the
    paywall's terms simple.

## Acceptance

- A store build without a subscription stops sending turns after 15 minutes of assistant time in a day,
  and starts again after local midnight.
- Subscribing removes the limit at once, and restoring on another phone does the same.
- No exempt user ever sees a counter or a refusal, and first aid answers at zero.
- No exhausted turn reaches any model, local or cloud.
- No usage data leaves the phone.
