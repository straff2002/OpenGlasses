# Plan HM — Organisation Agent Endpoint (other people's assistants can ask; a person releases)

**Status:** 📝 Drafted (not scheduled) 2026-10-03 — nothing implemented. Mostly an office feature;
this plan fixes the contract and the phone half.
**Track:** Field Assist (B2B).
**Related:** Plan [BL](BL-ops-platform-agent-bridge.md) (two-way agent messaging with an operations
platform — the same protocols, the opposite direction of trust), Plan [E](E-mcp-server-mode.md)
(the phone's own tool server), Plan [R](R-mcp-egress-and-tool-poisoning-screen.md) (screening
untrusted agent text), Plan [FX](FX-desktop-office-and-device-sync.md) (signed jobs from the
office), Plan [FO](FO-guided-job-flow-and-job-tab.md) (upcoming jobs and the brief), Plan
[HC](HC-jobs-list.md) (the Jobs list), Plan [EL](EL-equipment-identity.md) (`VaultModelIndex`),
Plan [CT](CT-org-configuration-profiles.md) (organisation policy).

---

## Trigger

Greig, 2026-10-03: people increasingly ask their own assistant to "find someone who services this"
rather than searching and emailing themselves. An organisation that an assistant can ask directly —
what do you service, where, can you take this job — gets found; one that only has a web form and an
inbox gets a stream of machine-written email instead. The useful version has one firm rule: the
outside assistant can ask and can leave a request, and nothing happens until a person in the
organisation says so.

## Outcome

- **The organisation has one address an assistant can query**, hosted by its own Avenkin Office.
- **It answers three things:** what the organisation services, where and when it works, and
  whether it will look at a described job.
- **A request becomes a draft**, never a booking. It waits in the office for a person to accept,
  change or decline.
- **An accepted request reaches the technician as an ordinary signed job** that says where it came
  from and which details nobody in the organisation has checked.
- **Nothing about customers, jobs, technicians or prices leaves** through the endpoint.

## What exists today (verified against main @ f2f49220)

- **The phone can serve tools to an agent, behind two gates.** `MCPServer/MCPGlassesServer.swift`
  exposes a bearer-token tool server, off unless agent mode and the server switch are both on.
- **There is no agent-to-agent task endpoint in the app.** BL plans one for a trusted operations
  platform; no source file implements it yet.
- **Untrusted agent text already has a screen.** Plan R's egress and tool-definition screens treat
  third-party tool descriptions and results as data that may be hostile.
- **A scheduled job records its origin.** `UpcomingJob.origin` exists, and each attachment records
  its signature state and signer; a fault report records its source and when it was received.
- **The vault knows which models it covers.** `VaultModelIndex` derives model tokens from the
  vault's headings.
- **Jobs from the office are signed and receipted.** FX defines the job message, its verification
  and the phone's receipt.

## Design

### 1 · Three questions, nothing else

The endpoint speaks the open agent protocols the product already uses (a tool list and a task
submit/poll), and offers exactly three operations:

| Operation | Answers with | Source |
|---|---|---|
| `describe` | The organisation's public card: name, trades, brands and model families serviced, service area, working hours, how to reach a person | Written by the office; the model families are **suggested** from the vaults it publishes, and a person edits the list before it is public |
| `can_you_take` | `likely`, `unlikely` or `ask_a_person`, with one line of reason | Deterministic rules over the card only — area, trade, model family, hours. Never the calendar |
| `request_job` | A reference and "a person will reply" | Creates a draft in the office |

There is no operation that returns a price, a technician, a time slot or anything about another
customer. `can_you_take` deliberately does not read the diary: an outside assistant that can probe
availability can map the organisation's workload.

### 2 · A request is untrusted text

A `request_job` carries a closed schema: contact, site address, equipment make and model as
stated, fault description, preferred times, and optional photos within a small byte budget.
Everything in it is treated as written by a stranger:

- Unknown fields are rejected, and lengths are capped.
- The text passes Plan R's screen before any model in the office reads it, and it is never placed
  in a prompt as instructions.
- Photos are size- and type-checked, stripped of metadata, and never opened by a tool that can act.
- The asking assistant's claimed identity is recorded and never believed.

### 3 · Limits that hold without anyone watching

- Per-caller and overall rate limits, with a daily ceiling on drafts; over the ceiling the answer
  is "contact a person" and the card's phone number.
- Drafts expire if nobody acts on them.
- The endpoint is **off by default**, and enabled per organisation in the office. A solo
  technician with no office has no endpoint.
- Every call is logged in the office's audit log with what was asked and what was answered.

### 4 · A person releases

A draft sits in the office's inbox marked with its origin. A person there accepts it (it becomes a
job like any other and is sent to a phone over FX), edits it first, or declines it. The asking
assistant can poll its reference and learns only `received`, `accepted`, `declined` or `expired`,
and — if accepted — the time the organisation chose to share.

No rule, model or schedule accepts a draft. This is the invariant the tests pin first.

### 5 · The phone half

The phone never talks to an outside assistant. It receives the accepted job as a normal signed FX
job, with two additions it must honour:

- **Provenance.** `UpcomingJob.origin` gains a case for a request raised through the endpoint, with
  the time it was received and who in the office accepted it.
- **Unverified fields.** The job names which fields came from the request unchanged (typically the
  equipment model and the fault description). The brief reads them as reported, not as known:
  *"The customer's assistant reported a Carrier 59TP6 with a pressure-switch fault. Nobody has
  confirmed the model."* Equipment identity (Plan EL) is not set from an unverified model; the
  nameplate read on site sets it, and a mismatch is said aloud.

The Jobs list shows the origin on the job's row. Nothing else about the job differs.

## Phases

- **P0 — the contract.** Schemas and fixtures for the card, the three operations, the draft and
  the status poll, in `Contracts/`, with a validator and the release invariant as executable tests.
- **P1 — the phone half.** The new origin case, the unverified-fields list on a job, the brief's
  wording, the Jobs-list row, and equipment identity refusing an unverified model.
- **P2 — the office endpoint.** Built in the office app against the P0 contract: the card editor
  with model families suggested from published vaults, the inbox, the limits and the audit log.
- **P3 — being found.** Publishing the card where assistants look. Deferred until there is a
  settled place to publish it.

## Tests

- A request with an unknown field, an over-long field or an oversized photo is rejected whole.
- `can_you_take` gives the same answer for the same card and question, and never reads a calendar,
  a job or a technician.
- No operation's response contains a customer, a job, a technician, a price or a time slot, for any
  input.
- A draft is never accepted without a recorded human action; expiry, retries and restarts do not
  change that.
- Over the daily ceiling, `request_job` creates nothing and returns the card's contact line.
- On the phone, a job with unverified fields is briefed as reported, does not set equipment
  identity, and says so when the nameplate disagrees.
- A job from the endpoint that fails FX verification is refused exactly as any other job is.

## Out of scope

- Quotes, prices and payment.
- The organisation's own assistant negotiating on its behalf.
- A directory of organisations. This plan makes one organisation askable; it does not list many.
- Any endpoint on the phone. The phone's tool server (Plan E) and the operations bridge (Plan BL)
  are separate, trusted-peer features.

## Open questions

1. Is this an office feature every Field Assist organisation gets, or an add-on?
2. Should `describe` list model families at all? It helps a matching assistant and also tells a
   competitor what the organisation holds manuals for.
3. Does an accepted request need the customer's consent recorded before their details reach a
   technician's phone, and where is that asked?
