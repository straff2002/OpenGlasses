# Plan IQ — Close-Out the Customer Can Act On, a Next Step for an Unknown Unit, and Calling Base With the Job

**Status:** 📝 Drafted 2026-10-17 — nothing implemented.
**Track:** Field Assist (B2B).
**Related:** Plan [EM](EM-work-record-and-parts.md) (the work record), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (the guided job, the debrief, evidence at close), Plan
[GB](GB-field-test-round-3.md) / [GD](GD-field-test-round-3-closeout.md) (recommended tasks, the
"Verify:" retest), Plan [EL](EL-equipment-identity.md) (equipment identity and the out-of-vault
unit), Plan [IF](IF-photographed-manuals.md) (`manual_capture`, built), Plan [F](F-field-assist.md)
and Plan [K](K-integration-polish.md) (escalation and the expert bridge), Plan
[FX](FX-desktop-office-and-device-sync.md) (FX8, the office's live-support phase), Plan
[IO](IO-sealed-proof-of-work-photos.md) (proof photos), Plan [IP](IP-organisation-feature-switches.md)
(organisation switches).
**Origin:** The October 2026 competitor review. Three things the new technician assistants do that
we don't, each small on top of what is already built:
1. They end a call with a customer-ready close-out sorted by urgency: critical repairs, recommended
   work, observations.
2. They start from a nameplate photo, and they have somewhere to go when the unit is one they don't
   know.
3. When the AI runs out, a human is one step away. One HVAC data company relaunched a paid live
   support line in 2026, and an enterprise vendor's voice line hands off to a person.

We copy the shape, not the selling. The close-out is the technician's recommendation, never an
upsell script. We don't build a cross-manufacturer equipment database; that is a partner
question, see "Not in this plan".

---

## Verified starting point (`main` @ `0606aeabb`, 2026-10-17)

- **The customer sees three things.** `CustomerSummary.lines(for:)` (`Job/CustomerSignOff.swift`)
  is an allow-list: work done (titles of `.done` tasks), parts used, and time on the job or billable
  units. It omits on purpose the why, notes, evidence, escalations and anything open or
  recommended. The signed summary is what the PDF reprints. `GuidedJobFlow` can hold the close
  until the customer signs or declines.
- **The work order prints everything, for the organisation.** `SessionExporter` prints
  `WorkRecord.summaryLines` whole, with every task status in `statusOrder` (Done, In progress,
  Accepted, "Recommended, no decision yet", Deferred, Declined, Abandoned), "Why:", notes, parts,
  captures, escalations, photos, acceptance, debriefs and "Sources Cited". `ReportAudience`
  (`office`/`customer`) only strips team learnings and governs the transcript. There is no separate
  customer document.
- **Recommendations already exist as tasks.** A `recommended` task does nothing until the
  technician accepts it, and declined and deferred ones are kept (`WorkRecord.notDone`). A fix that
  needs a retest leaves an open "Verify: …" task (`TaskClosePolicy`), printed "Not yet verified".
  **No urgency exists for the customer.** The only `Urgency` is `PartsRequest.Urgency` (routine,
  today, emergency), which is internal and goes to base.
- **The debrief's `customer_notes` is what the customer said**, not advice to them. Each debrief
  item cites its turns, is read back, and can be edited or removed before saving. Nothing from the
  debrief reaches the customer summary.
- **An unknown unit is recorded honestly, then left there.** `equipment_lookup` reads a nameplate
  on device (`OCRService`, `.accurate`) and matches through `VaultModelIndex`. A model the vault
  lacks is recorded as stated (`EquipmentIdentity.isOutOfVault`), announced as "not a model the
  loaded manuals cover", and printed so on the work order. The next steps offered are to confirm
  the nameplate, "load its manual", or escalate. `manual_capture` (Plan IF) is built but not
  offered from this path, and nothing offers to ask the office for the manual.
- **Escalation sends a pointer, not the job.** `escalate_to_expert` and `field_session escalate`
  go through `EscalationCoordinator`. `CompositeExpertNotifier` posts a local notification on the
  technician's own phone and a Slack-style webhook (`Config.expertWebhookURL`) carrying reason,
  asset id, session id and room URL, with no photos, pages or summary. The live view
  (`ExpertStreamBridge`: MJPEG one-way, a meeting link, WebRTC unavailable) is real but needs a
  relay or a meeting. The "Phase 3 placeholder" comments in `EscalationCoordinator` and
  `ExpertBridge` are stale.
- **The pieces to send the job exist separately.** `phone_call` places a `tel://` call to a
  contact or number, untied to the job. `deliver_report` stages the work-order PDF (with chosen
  photos and Sources Cited) and JSON on the open job through `DeliveryChannel` (email, messages,
  WhatsApp, Telegram, share sheet, endpoint), and a person taps Send. WhatsApp and Telegram get
  only a short summary and the job reference.

## Decisions proposed (owner to confirm)

1. **Three customer levels, and the technician sets each one.** `critical` ("needs fixing now:
   unsafe or about to fail"), `recommended` ("worth doing soon") and `observation` ("noticed, no
   action needed yet"). The model may *propose* a level when it drafts the close-out, but nothing
   reaches the customer until the technician has heard it read back and confirmed it. Each item
   is a sentence the technician said or approved, never invented. A safety item from the vault's
   safety file, or a finding a procedure marks safety-critical, cannot be confirmed lower than
   `critical`.
2. **No prices, no sales wording.** The close-out says what and why, not what it costs. Quoting is
   the field service system's job (Plan HT), and a "spots missed repairs and service opportunities"
   framing is not ours. The customer copy is headed "Your technician's recommendations".
3. **The customer summary grows; the allow-list stays.** `CustomerSummary` gains a fourth
   section, the confirmed recommendations, and nothing else. Notes, evidence, escalations and team
   learnings still never reach the customer. An organisation can turn the section off (an IP switch,
   on by default).
4. **An unknown unit gets three offers, and none of them is a guess.** "I don't have a manual for
   the <model>. I can photograph its manual if there's one here, ask the office for it, or carry on
   without one and say so on each answer." Photographing goes to `manual_capture`. Asking the office
   files a manual request with the job report (or an office `records` item in the opt-in build).
   Carrying on is today's behaviour.
5. **Calling base is a phone call plus a pack, sent by the technician.** "Call the senior tech"
   stages a *help pack*: a short summary of the unit, what's been tried, the readings, the open
   question, the chosen photos and the cited pages as images. It goes by the organisation's
   channel, then the call is placed. The technician sees the pack before it goes. It does not wait
   for FX8's live video, and it uses no relay or server.
6. **Who "base" is.** It is an organisation-owned contact list (a new CT `profileOwned` key,
   `organizationEscalationContacts`: name, role, phone, and channel for the pack), with a personal
   fallback in Field Assist settings. "Call base" picks the first available, and "call Sam" picks
   by name.
   *2026-11-03:* Plan [KM](KM-expert-on-the-job.md) builds this list first, as `EscalationContact`
   with specialties, on-call hours and contracted rates, under the CT key `organizationExperts`. The owner
   took "both" for decision 6 there (2026-11-03): the organisation sets the list, and a technician
   may add unpaid colleagues.

## Phases (one PR each)

### P0 — Recommendations with a level (headless core)

- `WorkTask.CustomerLevel` (`critical | recommended | observation`) on recommended tasks and on a
  new `CloseOutItem` (text, level, source turns, confirmed, optional task id). A `CloseOutDraft`
  pure builder proposes items from the session: recommended tasks with no decision, open "Verify:"
  retests, findings from the debrief, and safety-file hits through `LearningSafetyCheck`'s matcher.
  Each item keeps the turns it came from.
- `CloseOutReview`, a pure state machine: read back by level ("One critical: the heat exchanger
  is cracked…"), then confirm, change level, edit, or remove. A safety item can't go below
  `critical` (decision 1).
- `CustomerSummary.lines(for:)` gains the confirmed items under the heading of decision 2,
  ordered by level. `WorkRecord` carries them, and the organisation's work order prints them with
  their levels beside the existing task statuses.
- **Exit tests:** the builder over scripted sessions (a recommendation, a retest, a safety
  finding); the review's level floor; the allow-list test extended (no note, evidence or learning
  text reaches the customer); PDF snapshot tests of both audiences.

### P1 — The close-out by voice, on phone and CarPlay

- At job close, after the work is recorded and before sign-off, the guided flow asks "Anything
  you'd recommend to the customer?" and reads back the draft. One "no" skips it. On CarPlay it
  belongs to the debrief, where an item confirmed after the customer has signed goes to the
  addendum, never the signed summary.
- The sign-off sheet shows the recommendations above the signature, so the customer signs having
  seen them.
- **Exit tests:** guided-flow transitions (asked once, skippable, never after the signature on the
  same summary); the CarPlay template contract.

### P2 — A next step for an unknown unit

- When `equipment_lookup` resolves out-of-vault, or `set_equipment` records an unlisted model, the
  tool result carries the three offers of decision 4 as structured choices. That makes them
  answerable as "the first one" from glasses through Plan IA's choice questions once it lands, and
  by name before that.
- "Ask the office for it" appends a `manualRequest` (model, nameplate text with its redactions,
  job id) to the job report. In the opt-in office build it becomes an office `records` item. The
  request is shown on the Job tab as asked and pending, and is answered by FX's manual assignment
  when the office has the manual.
- "Photograph it" starts `manual_capture` bound to the job and the stated model, so the captured
  manual answers for that unit in that job (IF's exact-scope retrieval).
- **Exit tests:** out-of-vault resolution offers exactly the three steps; the request is in the
  record and the report; the capture is scoped to the unit; an in-vault unit offers none of it.

### P3 — Call base with the job

- `call_base` (`who?`, `question?`): composes the help pack (decision 5) from the session, through
  the same redaction and photo choices as the report (`decideEvidence`), with cited pages rendered
  as images the way `ManualFigureAttachment` renders them. It stages the pack on the contact's
  channel (`DeliveryRequest.Payload.helpPack`, a new case beside the job report and the learning
  bundle), then places the call with `phone_call`'s `tel://` route once the pack has been handed
  off. The escalation is logged on the session as today, with the pack's existence (not its text)
  on the record.
- `escalate_to_expert`'s webhook payload gains the help pack's summary text (not photos) when the
  organisation's webhook is set, so a Slack channel sees the question, not just a session id.
- The stale "Phase 3 placeholder" comments are removed.
- **Exit tests:** pack composition from a scripted session (summary, readings, chosen photos only,
  cited pages); an excluded photo never in the pack; HIPAA mode withholds the tool; with no
  contacts configured it refuses by name and points to settings.

## Not in this plan

- **A cross-manufacturer equipment and parts database.** It's the biggest gap the review found,
  and it is a licensing decision: an equipment-data partner's SDK, or an OEM library with
  permission. It is not something to build. If a partner is chosen, its answers enter as a third
  `RetrievalSource` with its own citation, like team learnings.
- **Live human support as a paid line.** Who answers is the organisation's business. This plan
  only makes reaching them one step.
- **Apprentice logbooks.** Waiting on a partner's answers about whether apprentices must keep a
  record, who signs it, and in what format.

## Acceptance

- At the end of a furnace job the technician says "the heat exchanger's cracked, that's urgent,
  and the filter's due in a couple of months". The customer's summary shows one critical item and
  one recommendation, in the technician's words, and the customer signs having seen both.
- At a unit whose manual isn't loaded, the technician hears the three offers. "Ask the office"
  leaves a request on the job report.
- "Call base about this" shows a help pack with the readings, the two photos the technician kept
  and the cited page. It goes to the senior tech's WhatsApp, and the call rings.

## Open questions for the owner

1. Decision 1: three levels, or two (needs doing now / worth doing)?
2. Decision 3: recommendations on the customer summary on by default, or opt-in per organisation?
3. Decision 6: does the escalation list belong to the organisation profile (the office sets it)
   or to the technician?
