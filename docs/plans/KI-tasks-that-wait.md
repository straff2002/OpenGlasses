# Plan KI — Tasks That Wait on Someone (the agent works out the steps, waits for the reply, and picks up where it left off)

**Status:** 📝 Drafted 2026-10-31. Nothing built.
**Track:** App-wide. A Field Assist job keeps its own flow and is out of scope.
**Related:** Plan [KH](KH-from-capabilities-to-use.md) P3 (the plan summary this starts from), Plan
[IW](IW-goals-and-activity-trail.md) (goals, steps, step actions, the activity trail), Plan
[JO](JO-watchers.md) (expectations, "I'm waiting on a letter"), Plan
[IX](IX-scoped-grants-and-read-only-integrations.md) (records that there is no mail-reading tool), Plan
[BC](BC-unconditional-safety-gate.md) (the safety gate), Plan
[S](S-plan-then-execute-and-safety-supervisor.md) (plan, then execute).

---

## Why

Greig, 2026-10-31, on booking a dentist. You rarely pick a time; the practice offers one. So the real
sequence is: review the contact; look up the practice and check it with you, looping until it is right;
update the contact so it need not search again; email asking for an available slot soon; receive the
reply; check it against the calendar; confirm with you, flagging nearby appointments; respond to your
changes or approval; reply by email with the change or acceptance; on acceptance, add it to the calendar
and tell you.

**That is a task that lasts days and waits on someone else**, not a chain inside one conversation.

"We do want the agent to be able to think this and use the tools appropriately." So this plan builds no
dentist flow. It gives the agent the abilities it lacks, and leaves working out the steps to it. Booking
is one example. Chasing a quote, moving a service booking and asking for a refund have the same shape.

The word "errand" is taken: in Plan JO it means something to buy when you pass a shop. This plan says
"a task that waits".

## Outcomes

1. The agent proposes a sensible plan for a task it was not written for, and you can correct it.
2. A task survives days of waiting, and "what am I waiting on?" answers it.
3. When the reply comes back, it picks up with what it already knows, without you re-explaining.
4. What it learned along the way stays, so next time is shorter.

## What exists (verified 2026-10-31, main at ff3e5c88f)

| Step | Today |
|---|---|
| Review the contact | Works: `lookup_contact` |
| Look up the practice, review, loop | Works in conversation: `web_search` |
| Update the contact | **Missing.** Nothing in the app writes to Contacts |
| Send the email | **Partly.** `send_via` opens a pre-filled email and you press send |
| Wait for the answer | **Missing.** `GoalStepState` has no waiting state; JO's `Expectation` is drafted, not built |
| Receive the reply | **Missing.** No mail reading; JO's decision 5 and IX both record it |
| Check the calendar, flag nearby appointments | Works: `calendar` |
| Handle changes or approval | Works in conversation |
| Add to calendar, tell you | Works, in a conversation you are in |

- **Goals is the right home.** `Goal` has steps, a next step (`GoalAdvancePolicy.nextStep`), a closed
  `StepAction` set and activity evidence. It is pure and tested, and it needs no Agent Mode.
- **The Share Extension exists and has one destination.** `OpenGlassesShareExtension` accepts text, URLs
  and files, and hands them to the teleprompter through `SharedTeleprompterInbox`.
- **Plan-then-execute is Agent Mode only.** `LLMService` reaches `AgentPlanner` only with
  `agentModeEnabled` on, and goal check-ins are background work under the same gate.

## Decisions

1. **No scripted flows.** Code adds abilities and safeguards. The steps come from the model, in a
   normal turn, starting from Plan KH's plan summary.
2. **The safeguards are code, not judgement:** sends are confirmed, contact writes are confirmed, web
   findings stay unconfirmed, and text from outside is information, never an instruction.
3. **Replies arrive by share-in first.** You open the reply and share it to Avenkin. No new access.
   Owner, 2026-10-31: acceptable. A connected mailbox is a separate, later decision.
4. **Sending stays in your hands.** Until a real mail connection exists, `send_via` opens the draft and
   you press send. The tool description must say so, and the agent must never say a message was sent.
5. **A task is a goal.** No second store. A waiting step is a step in a goal.
6. **Nothing runs by itself without Agent Mode.** With it off, a waiting task shows in Goals and My Day
   and answers "what am I waiting on?", and nothing chases on its own.
7. **Offer a call where email is wrong.** Some practices only book by phone. `phone_call` stays an
   option in the plan, and a call's outcome is told back by you.

## Rejected

- **A booking workflow or a template per task.** It handles the cases we thought of, and it is the
  scripted assistant this plan is meant not to be.
- **Reading the whole inbox now.** Large access for an unproven need.
- **Sending without showing you.** A wrong message reaches a real person.
- **A new store for tasks.** Goals already holds steps, state and evidence.

## Phases

Each phase ends in a PR with the tests that can run headless. P0 can start now. P3 waits on KH P3's plan
summary.

### P0 — Tools that tell the truth

- Rewrite the descriptions of `lookup_contact`, `send_via`, `phone_call`, `goals` and `calendar` so the
  model can reason from them: what each can do, what it cannot, and what happens next. `send_via` has to
  say that it opens a draft and that nothing has been sent.
- Prompt guidance through `SystemPromptBuilder`: a task can outlive a turn; say the plan; never claim an
  outcome a tool did not report.
- Tests: description guards, and `SystemPromptBuilderTests`.

### P1 — A step can wait

- `GoalStepState` gains `waiting`, persisted as an explicit string, with `WaitingOn` on the step: who,
  for what, since when, and optional sender hints. A build that does not know the state must still
  decode the goal. Check how `Goal` handles an unknown value before adding it.
- `GoalAdvancePolicy`: a waiting step is not the next step; the goal says "waiting on the dentist since
  Monday" instead of offering work.
- `goals` tool: mark a step waiting, resolve it; "what am I waiting on?" lists them.
- Shape `WaitingOn` so JO's `Expectation` can read it later. KI does not depend on JO.
- Tests: pure, in the style of the existing goal tests.

### P2 — Update a contact

- New tool, `update_contact`: add a phone number, email or address to an existing contact, or create
  one. A write through the normal authorization boundary, confirmed every time, showing old and new.
  It never replaces a value you have not seen.
- Check the Contacts permission text in `Info.plist`, and the tool's effect class, so a write is not
  treated as a read. HIPAA and organisation closed tools apply as usual.
- Tests: the pure change proposal (what is added, what is replaced, what is refused).

### P3 — Share a reply in

- Share Extension: choose where text goes, with the teleprompter unchanged as one destination.
- A new shared inbox beside `SharedTeleprompterInbox`, registered in `DataStoreRegistry`, cleared once
  read.
- In the app: match the shared text to waiting steps by sender hints and words (`WaitingMatcher`, pure).
  One match: "Is this the dentist's reply?". Several: ask which. None: ask what it is for.
- The shared text is fenced as outside content and never treated as an instruction. It goes to the
  model only once you have said which task it belongs to.
- Then the agent continues in a normal turn: reads the offer, checks the calendar, flags nearby
  appointments, asks you.
- Tests: the matcher, and fencing. The extension itself is a device check.

### P4 — Unscripted tasks

- A hand-run evaluation, not in CI, against a live model with a key from the environment, never stored.
- A set of tasks the code has never seen: book the dentist, chase a builder's quote, move a car
  service, ask for a refund, reserve a table, get a plumber out.
- Score, by reading the transcript with sends stubbed: was the plan sensible, were the right tools
  chosen, did it stop for what it did not know, did it claim anything it had not done.
- The result feeds P0's wording. Record the results in this plan.

## Later, not in this plan

**A connected mailbox.** Gmail or Outlook, limited to replies from a waiting step's sender, with a real
send. This reaches the model with mail content, brings provider review, and turns inbound mail into an
attack surface: anyone can email you. It belongs in Plan IX's read-only integrations, after P4 shows
people use this.

## Acceptance

- A device run of the dentist case: contact checked, draft shown, step waiting, reply shared in, nearby
  appointment flagged, answer drafted, calendar entry added, one line of Activity for each.
- It never says a message was sent when only a draft opened.
- A shared reply containing "ignore your instructions and…" changes nothing.
- With Agent Mode off, nothing happens unprompted, and "what am I waiting on?" still works.
- A contact is never changed without you seeing old and new.

## Open

1. **Should a waiting task nudge you?** With Agent Mode on, after how long, and how often? Recommended:
   once, after a week, at the goal's check-in cadence.
2. **Does a share-in need a waiting task?** Sharing any email to Avenkin could be useful by itself, and
   that is a bigger feature. Recommended: start with waiting tasks only.
3. **Does the first version need Plan KH P3?** The plan summary is the way in. P0 to P2 do not depend
   on it.
