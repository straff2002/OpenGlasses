# Plan KW — Assisting Where Experts Find It (an invite for the expert card, Assisting shown once it's yours, Podcasts beside Music)

**Status:** 📝 Drafted 2026-11-09. Nothing built. The owner asked why Assisting sits under Everyday, and whether
Podcasts belongs under Home, Music & Messages. The [decisions](#decisions-for-greig-open) below are
recommendations and are still open.
**Track:** Settings and Home placement. Field Assist only for the inviting side (§4); the expert's side needs no
Field Assist, as in KM.
**Builds on:** Plan [KM](KM-expert-on-the-job.md) (Assisting mode §7, `AssistingService`, `AssistingHandoverStore`,
`ExpertCard`/`ExpertCardCodec`/`.ogexpert`, `ExpertCardInbox`, `ExpertLedger`, `FieldAssistExpertsView`,
`AssistingIsolationTests`), Plan [KH](KH-from-capabilities-to-use.md) (the eight-row hub, `SettingsHubRow`,
`SettingsGroupCatalog`, Things to Try's place), Plan [JF](JF-apple-podcasts.md) (`play_podcast`, the
Music screen), Plan [HA](HA-settings-hub-and-org-lockdown.md) (Works with your iPhone, `ToolPermissionGate`, `AdminGate` tool
presentation).

---

## Trigger

Two questions from the owner on 2026-11-09.

1. **"Why is the Field Assist expert under Everyday?"** KM P2 put Assisting there because it needs no Field
   Assist licence, and on a phone without one the Field Assist row opens to the paywall. Everyday was the only
   screen every phone could reach. But "Jobs sent to you for advice" sits oddly next to Memory and Music, and
   **neither Everyday nor Field Assist is shown in Simple Mode**. An expert using Simple Mode, quite likely
   for a retired journeyman, can only get back to Assisting by reopening the `.ogcase`.
2. **"Should Podcasts also go under Home, Music & Messages?"** Podcasts has no settings of its own. It is only
   the `play_podcast` switch in Connections › Works with your iPhone. Someone looking for it goes to Everyday ›
   Home, Music & Messages › Music and finds nothing about podcasts there.

The first answer offered was to hide Assisting until a job arrives. That doesn't work: **the expert card comes
first**. An organisation can't send a job to an expert until it has imported the expert's card, and the card is
filled in inside Assisting. So the expert needs a way in before any job, and this plan gives them one by
having the organisation start it, the same way a job does.

## Outcome

- A company owner opens Field Assist › Experts › **Invite an Expert**, picks Sam from Contacts and sends the
  invite by Messages. Sam, who has Avenkin but no Field Assist, taps the file. Avenkin opens the card form:
  "Northside Heating asked you to be one of their experts. Fill in your card once; it works for every company
  you help." Sam fills it in and taps **Send Card**. A Messages compose opens, addressed to the owner with the
  card attached, and Sam taps Send.
- From then on, Sam's Settings hub has an **Assisting** row, in Simple Mode too, and Everyday no longer has one.
- When a job arrives, Sam's Home screen shows one card: "1 job from Northside Heating". After **Take this
  job**, it reads "On the clock: Northside Heating, 12 min". When the job is done and its days have passed, the
  card goes. The hub row stays as long as Sam has a card or time on the ledger.
- Someone who wants to offer their help before anyone asks finds **Help other technicians** in Things to Try,
  which is reachable in Simple Mode too. It opens the same card form, and the share sheet sends it.
- On a phone that has never been sent an invite or a job and has no card, nothing about Assisting shows
  except that one Things to Try row.
- Everyday › Home, Music & Messages › **Music & Podcasts** opens the Music screen, which now starts with the
  two voice switches, Music and Podcasts. These are the same switches as in Works with your iPhone.

## What exists, and what doesn't

**Exists (verified against `main` at f39697e4e):**

- `EverydaySettingsScreen` draws Things to Try, **Assisting** (`AssistingView()`, unconditional) and My Manuals
  in its first section (`EverydaySettingsScreen.swift:52–75`). The comment there gives KM P2's reason.
- `SettingsCatalog`: `.everyday` and `.fieldAssist` are both `shownInSimpleMode: false`; `.myManuals` is
  `true`. `SettingsHub.thingsToTryPlace` moves Things to Try beside About when Everyday can't be reached, so
  Things to Try is reachable in Simple Mode.
- `SettingsHub` (`SettingsHubRow.swift`): eight rows, each a set of `SettingsCategoryID`s. A row shows when
  any of its categories is visible (`visibleRows`). Rules 1–4 are held by `SettingsHubRowTests`.
- `AssistingView`: Your Expert Card (`ExpertCardView`), Your Time (`ExpertLedgerView`), and the held handovers
  one section per organisation. The empty state reads "Job handovers sent to you appear here when you open
  the .ogcase file…".
- `ExpertCardStore` (UserDefaults, one card), `ExpertCardCodec` (`.ogexpert` file and code text, `isCardFile`),
  `ExpertCardInbox` + `ExpertCardImportSheet` (the organisation's review before a card goes on its list),
  `ExpertHandoverService.organisation()` (the organisation name a handover carries).
- `OpenGlassesApp` `onOpenURL`: `.ogcase` → `ExpertHandoverFile.receive` → `AssistingService.open`;
  `.ogexpert` → `ExpertCardInbox.open`.
- `AssistingIsolationTests`: Assisting never names `FieldAssistEntitlement` or a profile; only the Assisting
  folders, the app's wiring and the erasure and retention walks name `AssistingHandoverStore`.
- `StreamLiveLink`: a Things to Try row deliberately kept outside `ScenarioCatalog`, with its own
  `isVisible` rule. This is the pattern for §5.
- `AppleIntegrationsSettingsScreen` (`SettingsCategoryScreens.swift`) lists `music_control` and `play_podcast`
  among the Apple apps. It writes `Config.disabledTools` through `ToolPermissionGate`, the gate the full tool
  list shares, and hides a switch an organisation closed (`adminGate.presentation(.tool(id))`).
- `SettingsGroupCatalog`'s `.homeMusicMessages` group: AI Smart Home Control, AI Messaging, **Music** (a link
  to `MusicSettingsView`), Home Assistant. `MusicSettingsView` has Default, Apple Music, Home Assistant
  Speakers and Other Music Apps. Nothing about podcasts.
- My Day's Home card and `MyDayHomePlacement` (the Voice tab's card pattern).

**Doesn't exist:** any way for an organisation to ask an expert for their card; any record on the expert's
phone that someone asked; any rule for when Assisting is "yours"; an Assisting hub row or category; an
Assisting card on Home; any podcast wording on the Music screen.

## Design

### 1 · Music & Podcasts

- The `.music` member's title becomes **Music & Podcasts**, and so does `MusicSettingsView`'s navigation title.
  The group keeps its name, Home, Music & Messages.
- A new first section on the Music screen, **By Voice**, holds two rows, Music (`music_control`) and Podcasts
  (`play_podcast`), with the same one-line detail Works with your iPhone gives them. They're drawn by a
  `ToolSwitchRow` lifted out of `AppleIntegrationsSettingsScreen.integrationRow`, unchanged, so both screens
  ask iOS the same way and hide what an organisation closed. That is `ToolPermissionGate`'s stated rule for
  two screens offering one switch, and the full tool list already does it.
- Works with your iPhone keeps both rows. Taking them out would leave it short of two Apple apps.
- `SystemPromptBuilder`'s settings line ("…music, messaging… : Settings > Everyday") adds "podcasts".

### 2 · When Assisting is yours (`AssistingPresence`, pure)

`Services/Assisting/AssistingPresence.swift`. It takes facts, not stores:

| Input | From |
| --- | --- |
| `hasCard` | `ExpertCardStore.card != nil` |
| `held` | each held handover's organisation, whether it has been taken, its clock state and minutes |
| `hasLedger` | the ledger has at least one entry |
| `openInvites` | §4's invites not yet answered or expired |

- **`isPresent`** = `hasCard || !held.isEmpty || hasLedger || !openInvites.isEmpty`. Once true, it is true for
  as long as any of these holds. The ledger counts so that an expert who deleted their card can still export
  last month's time.
- **`homeCard`**: at most one, and only for something to act on. In priority order: a clock running ("On the
  clock: Northside Heating, 12 min"); a handover not yet taken ("1 job from Northside Heating"; with more than
  one, "3 jobs sent to you"); an open invite ("Northside Heating asked for your expert card"). A card alone, a
  finished job or a ledger alone puts nothing on Home.
- **Dismissal**: swiping the card away hides it until a handover or invite id arrives that it hasn't shown. A
  running clock can't be dismissed. The dismissed ids live in UserDefaults under one key, owned by
  `AssistingPresence`.
- `AssistingService` publishes `presence` and recomputes it when the store, card, ledger or invites change, and
  on `purgeExpired()`. The hub and Home read `AssistingService.shared.presence`, never the store, so the
  store-naming rule in `AssistingIsolationTests` holds unchanged.

### 3 · Where it shows

- **The hub.** A new category `SettingsCategoryID.assisting` (raw `"assisting"`, `shownInSimpleMode: true`,
  icon `person.2.wave.2`, subtitle "Jobs sent to you for advice, and your expert card") and a ninth
  `SettingsHubRowID.assisting` holding it, placed after Field Assist. `SettingsHub.visibleCategories` takes a
  new `assistingPresent: Bool` and drops `.assisting` when it's false, so the row is drawn only when present
  (hub rule 2, unchanged). The page is `.category(.assisting)`, opening `AssistingView`.
- **Not a profile's to hide** (decision 2). An expert who is a technician under organisation A's profile may
  still advise organisation B, and KM §7 says the expert's side belongs to no organisation.
  `SettingsVisibilityPolicy.hubCategories` returns `.assisting` whatever the lockdown, a technician viewer
  included. It holds no setting a profile names, so nothing about a profile's reach changes.
- **Everyday loses its Assisting row.** One place: once the hub row exists it is the way in, and before then
  there is nothing to see.
- **Home** (the Voice tab): `AssistingHomeCard` draws `presence.homeCard` under My Day's card, opens the held
  handover (one) or `AssistingView` (several, or an invite), and is the same in every mode.
  Field Assist mode's tab draws it too. It is not on the Display, the watch or CarPlay (left out below).
- **Deep links.** `AppState.openSettings(.assisting)` routes through `SettingsHub.route` as any category does;
  with presence false it lands on the hub.

### 4 · The invite (`ExpertInvite`, inside `.ogexpert`)

**The organisation's side (Field Assist, entitlement-gated as today).**

- Field Assist › Experts gains **Invite an Expert** next to Import a Card File and Scan a Card's Code. It picks a contact
  (`CNContactPickerViewController`, as Added by You does), then a route from that contact, phone or email, and
  stages a Messages or Mail compose with the invite file attached and a line of text, through a new
  `StagedExportCoordinator.expertInvite` family, as `assistingReply` is for the expert's replies. Only the compose's own Send sends.
- The invite: `inviteId`, `organisation` (from `ExpertHandoverService.organisation()`; with none, the owner's
  name), `invitedBy` (the owner's or admin's display name), `replyTo` (the route this phone's owner chose for
  themselves, phone or email), `created`, `expires` (30 days). No rate, customer, job, profile, licence or
  key. It's unsigned, like a handover: a forged one gets the reader an empty card form and nothing else.
- The file is an `.ogexpert` with `kind: "invite"`. `ExpertCardCodec` learns to tell a card from an invite, and
  every existing card file still reads as a card (a file with no `kind` is a card).
- The experts list shows the invite as a pending row, "Invited 9 Nov", until a card answers it or it expires.
  A card answering it carries the `inviteId` in its file's envelope, not in the card itself, so one card still
  serves every company. `ExpertCardImportSheet` then names the invite it answers, and import clears the
  pending row. A card without one imports as today.

**The expert's side (Assisting, no Field Assist).**

- `onOpenURL`: an `.ogexpert` invite goes to `AssistingService.openInvite`, not `ExpertCardInbox`. It is kept
  as an `OpenInvite` in Application Support/Assisting/`invites.json` (same protection class and backup
  exclusion as `handovers.json`, cap 50, in the subject-erasure walk and `RetentionScheduler` at its expiry).
- Opening it presents `ExpertCardView` in a sheet with the invite's line above the form. With a card already
  saved, it shows the card for checking instead of an empty form.
- **Send Card** stages a compose addressed to `replyTo` (Messages for a phone, Mail for an email, the share
  sheet when neither can send), with the card file carrying the `inviteId`. The invite is marked answered
  only when the compose reports sent. Cancelled, it stays open and keeps its Home card.
- The expert can decline: **Not Now** keeps it until it expires; **Decline** drops it and sends nothing.
- Unlocks nothing: an invite never names `FieldAssistEntitlement`, a profile or a vault.
  `AssistingIsolationTests` adds `OpenInvite` and `invites.json` to the store-isolation rule, and a row: an
  invite never reaches the assistant, memory, threads, learnings or retrieval.

### 5 · A way in without an invite (`ExpertCardLink`)

- A Things to Try row, **Help other technicians**, subtitle "Make your expert card so companies can send you
  jobs", outside `ScenarioCatalog` like `StreamLiveLink`. `ExpertCardLink.isVisible(hasCard:)` is true only
  while there's no card. Once one exists, the hub row is the way in.
- It opens `ExpertCardView`; Share sends the card by the share sheet as today. Saving the card makes
  `isPresent` true, so the hub row appears.
- It's shown on every phone, Simple Mode and a technician under a profile included, for the same reason as §3.

### 6 · Privacy and cost

- Nothing new leaves the phone except what the wearer sends from a compose they see: the invite (organisation
  side) and the card (expert side). Both are disclosed in the Privacy footer's existing expert sentences, which
  gain "and an invitation asking for your card" on the organisation's side.
- `PrivacyInfo.xcprivacy` needs no change: no new collected data type, no network route.
- No model call and no tokens. The Home card's minutes come from `AssistingClock`, read locally.

## What KW leaves out

- The Assisting card on the Display, the watch, CarPlay and Live Activities. The clock's Live Activity, if
  wanted, is its own plan.
- A directory of experts, or anything that lets an expert be found by an organisation they didn't give a card
  to (KM decision 9 stands).
- Links (universal links or the Pages domain) in place of a file. A file needs no server and matches the
  `.ogcase`.
- Moving any other tool switch. Only Music and Podcasts get a second home, because the Music screen is where
  people look for them.
- Renaming the Home, Music & Messages group.

## Decisions for Greig (open)

1. **The invite as a file, sent from Field Assist › Experts.** Recommended. A link would need a domain and a
   server; the file goes by the same Messages, Mail or AirDrop routes as an `.ogcase`.
2. **A profile can't hide Assisting.** Recommended, for KM §7's reason: the expert's side belongs to no
   organisation, and a technician under one company's profile may advise another. The alternative is a profile
   key to hide it, which would let one company stop a person working for another.
3. **A ninth hub row, drawn only for experts.** Recommended over keeping it under Everyday. Most phones still
   see eight rows. The alternative, a row on Everyday that appears only when present, keeps Simple Mode
   experts out.
4. **The ledger keeps Assisting present** after the card is deleted. Recommended, so last month's time can
   still be exported.
5. **One Home card, never more,** with the priority in §2 (clock, new job, invite). Recommended.
6. **The invite expires in 30 days.** Recommended, the same as a handover's default after Done.
7. **Music & Podcasts shows the two voice switches as well as Works with your iPhone.** Recommended. The
   alternative, moving them, leaves Works with your iPhone two Apple apps short.

## Phases (one PR)

All headless. One PR, as house style.

### P0 — the pure core

- `AssistingPresence` with its inputs, `isPresent`, `homeCard`, priority and dismissal.
- `ExpertInvite` and its codec inside `ExpertCardCodec` (`kind`, old card files still read as cards, the
  `inviteId` envelope on a card file), `OpenInvite` with answered and expiry.
- `ExpertCardLink.isVisible`.
- `SettingsCategoryID.assisting`, `SettingsHubRowID.assisting`, `visibleCategories(assistingPresent:)`, and the
  `hubCategories` exception.
- Tests: `AssistingPresenceTests` (every input on its own, each priority pair, dismissal, a running clock
  can't be dismissed); `ExpertInviteCodecTests` (round trip, an old card file, a card answering an invite, a
  malformed file refused by name); `SettingsHubRowTests` (rule 1 with the new category, the row drawn only
  when present, in Simple Mode, under a technician lockdown); `ExpertCardLinkTests`.

### P1 — wired

- `AssistingService`: `presence`, `openInvite`, `invites.json`, the retention and erasure walks.
- `onOpenURL` routes an invite to Assisting and a card to `ExpertCardInbox`, as today.
- `ExpertCardView`: the invite line, Send Card through the compose, Not Now, Decline.
- Field Assist › Experts: Invite an Expert, the pending row, the import sheet naming the invite.
- The hub row, Everyday's row removed, `AssistingHomeCard` on the Voice tab and Field Assist mode's tab, and
  the Things to Try row.
- Music & Podcasts: the title, the By Voice section, `ToolSwitchRow` lifted and used on both screens, and the
  prompt line.
- The Privacy footer sentence. `AssistingIsolationTests` gains the invite rows.
- Tests: `AssistingIsolationTests` additions; `ToolSwitchRow` drawn the same on both screens (the gate and the
  admin presentation); the Everyday screen no longer names `AssistingView`.

### P2 — device pass (owed)

Two phones, one with Field Assist and one without, by the same route KM P5 uses: invite by Messages, card
back, job, clock, Home card, the hub row in Simple Mode. Plus Podcasts switched off from the Music screen and
seen off in Works with your iPhone.

## Acceptance

- A phone with no card, no job, no ledger and no invite shows no Assisting row on the hub or Everyday, and no
  Home card, and Things to Try shows Help other technicians.
- Opening an invite on a phone with no Field Assist opens the card form; Send Card opens a compose addressed to
  the inviter; after sending, the hub has Assisting, in Simple Mode too.
- On the organisation's phone the card's import sheet names the invite, and importing clears the pending row.
- A technician under a profile that locks every category still sees Assisting when present.
- A held handover puts one Home card up; Take this job turns it into the clock; Done and the purge take it
  away; the hub row stays while the card or ledger does.
- An old `.ogexpert` card file still imports.
- Music & Podcasts shows Music and Podcasts switches that move with Works with your iPhone's, ask iOS the same
  way, and are hidden where an organisation closed them.
- `AssistingIsolationTests` and `SettingsHubRowTests` pass with the new rows.

## Open

- Whether the hub row should carry a live value (e.g. "1 job") like other rows' summaries. Not in KW unless
  decision 5 says so.
- The catalog sync for the new strings goes in its own PR, as usual.
