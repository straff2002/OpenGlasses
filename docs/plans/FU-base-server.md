# Plan FU — Base Server (the organisation's own server and its admin console)

**Status:** 📝 Drafted 2026-09-25. This is the server side. The phone side and the wire contract
are Plan [FT](FT-organisation-administration.md) (setup, overlays, jobs, reports, manuals), Plans
[L](L-webrtc-expert-transport.md) and [M](M-webrtc-infra-and-audio.md) (live support transports), and
Plan [EM](EM-work-record-and-parts.md) (the report envelope the office endpoint receives today).
**Origin:** FT closes with *"the base server needs its own plan."* The owner then asked, on
2026-09-25: should it be a web app people log into or something that runs locally at a firm; should
it also cover viewing the stream when Field Assist needs support, sending jobs and receiving
invoices; and is a TURN server really needed. This plan records the answers.
**Depends on:** FT1's written wire contract. Nothing here should be built against a guessed shape.

---

## The shape

One server per organisation, with a browser console served by the same server. It does five
things, built and shipped as separate parts behind one login:

| Part | What it does | Phone side |
|---|---|---|
| **1 · Core** | sets phones up, manages them with overlays, sends jobs, receives reports | FT1–FT3 |
| **2 · Live support** | relays the glasses' view to an administrator's browser when a technician asks for help | the MJPEG transport (Plan L), pointed at the server |
| **3 · Accounting hand-off** | turns a finished job's record into a draft invoice in the firm's accounting package | nothing new |
| **4 · Manuals** | holds the organisation's manuals and serves them by hash | FT4 |
| **5 · Where the crew is** | a status board from job events, and each engineer's last known position while on shift | FT5 |

Core ships first, because a phone can't be set up without it. The others can each wait for the
pilot to ask for them.

## Where it runs

**Decided direction, 2026-09-25: one self-contained package, one organisation per install.** A
single container (or binary) with an embedded database, the phone-facing endpoints and the web
console. It never holds more than one organisation's data.

**Not a vendor-hosted service for every firm.**

- The plans already rule it out. FT: *"the product still runs no server of its own."* Plan EE prices
  the team seat as software, not a hosted service. Plan CR turned down multi-tenancy for the same
  reasons.
- One breach would reach every customer. The server holds each firm's two private signing keys, its
  AI key, its jobs and customers, signatures, photos, and licensed manuals the firm may not
  republish. Whoever held a shared server could push settings, jobs and AI keys to every crew. The
  phone's own limits (an overlay can't touch entitlement or loosen a vendor ceiling) bound the
  damage, but not by much.
- Holding customer data would make the vendor a processor for every firm, which widens the SOC 2 and
  ISO 27001 work in Plans ER and ES considerably.

**Not a box in the office by default.**

- Technicians are in vans and other towns, so the server must answer HTTPS from anywhere, all day.
  An office box needs a stable public hostname, a certificate, an open port or a tunnel, backups and
  power. Most small trade firms have nobody to look after that.
- LAN-only doesn't work at all: a technician on site could neither fetch a job nor send a report.
- The server's address is locked into the vendor-signed profile (`baseServer`). Changing it is a
  re-minted profile, so an address that moves (a dynamic IP) is expensive.
- An office box that goes off overnight is survivable: the phone fetches rather than waits for a
  push, reports queue on the phone, and the lease has slack. So running it in-house is a supported
  option for a firm that wants it and can look after it.

**For the pilot, the partner runs the firm's instance in the cloud.** FT notes the partner may already
run dispatch for its customers. This still needs the partner's agreement (see *Open questions*).

**Hosted in the firm's own region.** The primary market is Canada and the United States (owner,
2026-09-25). A Canadian firm's instance is normally hosted in Canada, and a Quebec firm's ideally in
Quebec: Quebec's Law 25 requires a privacy impact assessment before personal information leaves the
province. The partner hosts each firm's copy in that firm's region rather than wherever is cheapest.

**The address lives on the firm's own domain**, for example `jobs.firmname.com`, and that is what
the profile's `baseServer` names. Moving from partner hosting to in-house hosting is then a DNS change,
not a re-minted profile.

**Two faces.** The phone API has to be public. The console does not: it sits behind an administrator
login and, where the host allows, a network restriction (an allow-list, a VPN or the partner's single
sign-on). Keeping them apart means an attack on the admin login is not an attack on every phone
endpoint, and the other way round.

## What it holds

| Secret | Why | How |
|---|---|---|
| `adminKey` (Ed25519, private) | signs overlays (FT) | kept apart from the web tier; only the signing step touches it — the same isolation Plan EI asks for the vendor's key, and a KMS/HSM where the host has one |
| `organizationJobSigningKey` (Ed25519, private) | signs `.ogjob` files (FO) | as above, and a **different** key, so either can be rotated alone |
| the organisation's AI key | sealed to each phone's registered key and sent in an overlay | encrypted at rest; never shown again once entered; never sent anywhere except sealed to a registered phone |
| the organisation's licence code | handed to a phone at registration (FT step 2) | not secret in itself (the phone verifies it against the vendor key), but it is the firm's |
| administrator accounts | console login | per person, never shared; every approval, overlay and job records who did it |

The vendor holds none of this. Its part is minting the profile that names `baseServer` and the public
half of `adminKey` (`Scripts/make-org-profile.swift` needs those two fields, which is FT1's).

## Part 1 · Core: phones, jobs and reports

Everything here is FT's contract, served. FU adds the console and the storage around it.

**Setting phones up.** *Add a phone* and *Add phones* mint FT's `og-setup:` code: the server's address
plus a 128-bit token, single-use, fifteen minutes by default, tied to the slot the administrator
named. The slot shows as used the moment it is, with the time and app version. Phones set up with a
typed activation key land in an **approval queue** showing the six-character fingerprint beside the
label; nothing is sent to a phone until an administrator approves it.

**Managing phones.** The console builds FT's overlays: whole desired state, addressed to one enrolment
id, with a sequence number that only goes up, signed with `adminKey`. The console never offers what
the phone will refuse — the licence, its tier or packs, a vendor ceiling, `baseServer`, `adminKey` or
the lease. The phone list shows label, app version, overlay sequence, lease date and **"last checked
in"**, never "online".

**Jobs.** A job is created in the console — or arrives through a dispatch connector (*Later parts*),
which is optional — scheduled (a date and time window, which `.ogjob`'s `scheduled_for` already
carries), assigned to one phone (by enrolment id) or left for anyone, and served as a signed
`.ogjob` — the same file `Scripts/make-job-file.swift` makes today, whose `Body` must stay
field-for-field identical to the app's `JobFile.Body`. The phone fetches it and runs it through
`JobFileImportPolicy` unchanged, so a job from the server and a job from email are the same file.
The email path stays beside the server (FT's leaning), and the console can download a job as an
`.ogjob` to email when a phone can't reach the server.

**Reports.** The endpoint the phone posts to today is `EndpointSyncSink`
(`OpenGlasses/Sources/Services/Offline/EndpointSyncSink.swift`), and its behaviour is the server's
contract until FT3 changes it:

- one JSON envelope per record: `op`, `op_id`, `session_id`, `created_at`, `job_reference` when there
  is one, and `payload` (the Plan EM work record or parts request)
- `Idempotency-Key` carries `op_id`, which is stable across retries, so the server must file a repeat
  as the same record, never a second visit
- 2xx means **accepted and durably stored**. Plan CT PR 4 counts a record as delivered only on 2xx and
  then may erase the phone's copy, so answering 2xx before the record is safely written loses it
- 409 means the job moved on while the phone was offline, with a reason in the body
- 401/403 and other 4xx are permanent on the phone: it stops retrying

FT3 replaces the bearer token with a request signed by the phone's key and keeps everything else.

**Files are the gap.** The endpoint takes JSON only (`EndpointSyncSink.carriesFiles = false`), so
photos, clips and full logs never reach the office unattended today. Plan CT expects them to once the
base server exists. FU1 defines an upload shape (per file: the op it belongs to, a SHA-256, resumable
upload); the phone half flips `carriesFiles` and teaches `AttachmentBudget` that the office channel
now has one.

**The console, for Part 1:** phones (list, approvals, add, label, unenrol), jobs (create, assign,
status as the phone last reported it), reports (inbox by job and phone, with the PDF and JSON), and an
audit log of who approved, sent or changed what.

## Part 2 · Live support: the server is the relay, and there is no TURN

**Decided 2026-09-25: for the pilot, live support is the MJPEG transport with the base server as its
relay. No TURN server.**

**Why TURN drops out.** TURN is only needed by the **WebRTC** transport, where the phone and the
expert's browser connect directly and a relay is the fallback when a mobile network's carrier-grade
NAT or an office firewall blocks the direct path. The MJPEG transport has both ends connect *outward*
to the relay over a WebSocket, so neither end's router matters, and the phone already talks to its
own server.

**What the three transports give an expert** (`Config.expertStreamTransport`, Plan L):

| Transport | Shows | Needs | Catch |
|---|---|---|---|
| **MJPEG relay** (default) | the glasses' view, after the outbound frame path (Plan CP; the transport is rostered under `expertStream`) | a relay | video only; more delay; all video passes through the server |
| **Meeting link** | whatever the meeting app shows, normally the **phone's** camera | nothing | `MeetingLinkTransport.start` ignores the `framePublisher` it is given, so the glasses' view never reaches the call |
| **WebRTC** | the glasses' view, plus two-way audio | signalling relay, TURN, and Plan M's missing room authentication | the most to run |

**The relay protocol the app already speaks** (`WebRTCStreamingService.swift`). There is no reference
relay for it in the repo — `docs/webrtc/signaling-server.js` speaks the WebRTC signalling protocol, not
this one — and the hosted relay the app used to default to was removed in
[#471](https://github.com/straff2002/OpenGlasses/pull/471). So the server implements:

- the phone connects to `wss://…?role=streamer&room=<id>` and sends
  `{"type":"stream_start","room","format":"mjpeg","fps"}`
- frames arrive as binary (`0x01` then the JPEG bytes, for frames over 50 KB) or as JSON
  `{"type":"frame","data":<base64 JPEG>,"timestamp"}`, plus `heartbeat` and `stream_stop`
- the server sends `viewer_count` (`count`), `viewer_joined`, `viewer_left` and `error` (`message`)
- the room id is 128 random bits and the viewer link is `webRTCViewerBaseURL?room=<id>`

**What the base server adds to it:**

- **The streamer is a registered phone.** The WebSocket upgrade is signed with the phone's key, like
  every other request to `baseServer`; an unregistered streamer is refused.
- **A viewer is a logged-in administrator.** Today the room id in the viewer link is the whole of the
  access: whoever holds the link watches. On the base server the link opens only inside a console
  session, so a join link forwarded out of a chat is useless on its own.
- **The request for help lands in the console.** `WebhookExpertNotifier` already posts
  `{text, reason, asset_id, session_id, room_url}` to `Config.expertWebhookURL`. Pointed at the server,
  the request appears beside the phone and its open job, and can also be forwarded to Slack or Teams
  (without the link working there).
- **A viewer cap** (default two), and the phone told how many are watching. The service already
  tracks `viewerCount` from those messages, but no screen shows it yet; FU3 shows it to the
  technician, who should know when someone is watching.
- **No recording by default.** Frames are relayed and dropped. Recording is Plan M's open consent
  question and stays open.
- **Voice is an ordinary phone call** alongside the video.

**Bandwidth.** At the app's defaults (15 fps, JPEG quality 0.4) a call is probably a few megabits per
second through the server. That is an estimate, not a measurement: measure it on the pilot and size
the host from it.

**Phone-side work.** With a profile naming `baseServer`, the relay and viewer addresses are derived
from it rather than typed in Settings, the streamer connection is signed, and the technician sees
how many people are watching. The addresses are derived, not sent in an overlay, because only the
vendor profile may name the organisation's server.

**WebRTC and TURN come later, and only if the firm asks** for two-way voice and video in one call or
for less delay than the relay gives. Then: Plan M's room authentication first (the base server issues
the room token), a managed TURN service before running coturn (Plan L's own recommendation), and the
TURN host disclosed as a new destination in the privacy manifest and in-app copy in the same PR.

## Part 3 · Accounting hand-off, not invoicing

**Decided direction, 2026-09-25: the server does not produce invoices.** It turns a finished job's
record into a **draft** invoice in the accounting package the firm already uses, where the firm
reviews, numbers, sends and reconciles it.

- **Why not invoice in the server:** tax rules, numbering, payments, credit notes and customer
  accounts duplicate what every firm already pays for, and they would make the server a financial
  system in ER and ES's scope.
- **Where the lines come from:** the customer summary the customer signed (Plan FO P2c) — completed
  work, parts used, time or billing units. It is an allow-list, so internal notes and escalations can
  never reach an invoice, and the record keeps it verbatim with a SHA-256 digest, so the draft can
  cite exactly what the customer agreed to. FO puts the acceptance block in the record's JSON, minus
  the signature image; FU3 confirms that is what reaches the endpoint before relying on it. A job
  closed without sign-off drafts from the work record's parts and time, and says so on the draft.
- **One draft per job.** Keyed on the report's `op_id` and the job reference, so a resent report
  updates the draft rather than making a second one.
- **Order of work:** a CSV export first, then one connector for the pilot's package. Which package
  (Xero and MYOB are the likely ones in New Zealand) is an open question.
- **Suppliers' invoices** for parts belong in the accounting package. At most, the server matches one
  to the parts request on the job.

## Part 4 · Manuals

FT4's server side. The server stores the organisation's manuals, lists them in the overlay as a
manual set (file names, sizes, SHA-256s, target vault id), and serves each file to a signed request,
resumably (HTTP range requests), because a binder of scans is large. Withdrawing a file is a new set
without it, which removes it from each phone at its next check-in.

## Part 5 · Where the crew is: a status board, and position only while on shift

**Decided direction, 2026-09-25: the console shows where each engineer is in their work day, not a
live dot that follows them.** A dispatcher's real questions — who is free, who is on site, who is
closest to an urgent job — are answered by status plus a recent position during working hours.
Continuous tracking adds legal exposure, battery drain on a phone already streaming from the
glasses, an App Review justification, a change to FT's fetch-only design, a dataset that reveals
where every van parks overnight, and a crew that feels watched.

**What the phone already does with location.** A job records where it started and ended
(`FieldSession.startLocation`/`endLocation`), and the start travels in the exported report
(`SessionExporter`). A help request can send the technician's location to the organisation's
notification address, and `privacy.html` says so. The app's "Always" permission is explained, in the
permission string and in `privacy.html`, as used **only** for location reminders, and the app declares
no `location` background mode.

**The design:**

- **Status board first.** Each engineer shows as *Travelling to job 1042*, *On site at ⟨site⟩ since
  10:42*, *Available* or *Off shift*, derived from job events the phone already produces (a job
  started, a job closed) plus shift start and end. This needs no position at all.
- **Last known position, only on shift.** The phone attaches its position to each check-in and job
  event between the technician's own *Start shift* and *End shift*, and never outside them. The
  console shows it with its age — *"as of 10:42"* — the same discipline as "last checked in". No
  continuous stream and no `location` background mode; in the background the phone uses whatever
  check-ins FT already makes.
- **Latest position only.** The server keeps each engineer's most recent position and overwrites it,
  never a trail. Job records keep their start and end as today. Ending a shift clears the position.
- **The technician can always tell.** An indicator on the phone — *"Base can see your location"* —
  whenever sharing is on; shift start and end are the technician's actions.
- **Never switched on silently.** The organisation turns the feature on in its profile; the enrolment
  review sheet says so; the technician acknowledges the organisation's monitoring policy before the
  first shift, and the acknowledgement is recorded.
- **Company phone or personal phone** is set per enrolment. On a personal phone the default is status
  only, with no position.
- **A help request** sends a precise position, as it can already.

**The monitoring-policy record.** The console stores the organisation's written monitoring policy,
its version, and when each technician acknowledged which version. That one record serves the
jurisdictions below.

**Designed once, to the strictest rules in the primary market** (Canada and the US). These are the
drivers as understood when this was written, and counsel should confirm them before FU6 ships:

| Where | What it asks for | Met by |
|---|---|---|
| Ontario | employers with 25+ employees keep a written electronic-monitoring policy saying whether and how they monitor, GPS included (Employment Standards Act, as amended by the Working for Workers Act 2022) | the policy record |
| Quebec (Law 25) | tell people when a technology can locate them and how the function is activated; a privacy impact assessment before information leaves Quebec | the technician's own shift toggle, the enrolment review, hosting in region |
| Alberta, BC (PIPA) | employee information reasonable for managing the employment, with notice; commissioners have accepted vehicle GPS for dispatch and safety, not much beyond | on shift only, latest only, notice at enrolment |
| Federally regulated employers (PIPEDA) | legitimate purpose, effective, proportionate, no less intrusive way | status first, position only on shift |
| California (CCPA/CPRA) | employee data covered; notice at collection; precise geolocation is sensitive personal information with limited use | notice at enrolment, use limited to dispatch |
| New York, Connecticut, Delaware and others | written notice of electronic monitoring, with acknowledgement in some | the policy record |
| Everywhere | off-shift and personal-phone tracking is where privacy claims arise | never off shift; status only on a personal phone by default |

## Later parts: what the office does with what the phone sends

Added 2026-09-25. Candidates for the console once Parts 1–5 are in, ranked by how much of the data
already arrives. **Where the phone lacks something a tool needs, the phone gains it** (owner,
2026-09-25): a missing capture is phone work to schedule, not a reason to drop the tool. The split
stays the same throughout — **the phone captures, the console decides and answers** — and every
phone addition keeps working without a server (it lands in the report and the email route as well)
and is disclosed in the same PR if it sends anything new.

| Tool | Console | Phone side |
|---|---|---|
| **Parts desk** | a queue of parts requests; the office answers ("ordered, arriving Thursday") | **small:** the request already carries a manual-checked part number, quantity, urgency, on-van and model, and `PartsRequest` already has `status: .answered` and `baseAnswer` ("what base said"). Today the technician records base's answer by saying it (`FieldSessionService.answerPartsRequest` via `PartsRequestTool`); the check-in delivers it instead, and it is spoken at a turn boundary |
| **Follow-up queue** | the debrief's *Follow-ups* and *For base* lists (`DebriefSummary`) as an office to-do list; one click makes a return-visit job with site and equipment filled in | **none** beyond FT3's reports |
| **Equipment and site history** | every visit to a serial or site across the crew | **small:** send the crew's history with a job so the brief (FO P3c) cites it; `.ogjob` is a strict schema, so this is a new, optional field and a format version, not a free-text note. Today `JobHistoryIndex` knows only this phone's visits |
| **Job archive and search** | any job by customer, serial or date; the PDF and the signed summary; resend the report | **none** |
| **Escalation log** | reasons, time to resolve, which models cause the most calls | **none:** `FieldSession.escalations` carries reason and resolution time |
| **Team-learning review** | Plan FP's reviewer queue in the console | per FP; its reviewer-phone decision stands until the pilot asks |
| **Timesheets** | time per job and shift start and end, exported for payroll | **none** beyond FT5: `billableSeconds` is already on the job |
| **Certifications** | each technician's tickets and expiry dates (US EPA Section 608 for refrigerant work; provincial refrigerant certification in Canada), and a warning before a job goes to someone uncertified | **none:** office data. At most, the phone shows the technician their own expiry |
| **Refrigerant log** | the service and leak-repair records US rules require above a refrigerant-charge threshold, per appliance | **new:** structured fields on the job (refrigerant type, amount added and recovered, leak found and repaired). Task readings today are free text (`WorkTask` evidence `readings: [String]`), which a regulator's record can't be built from. Thresholds and fields confirmed with the partner or counsel first |
| **"On the way" message** | an arrival estimate sent to the customer from the status board — the estimate, never the engineer's position | **small:** a *Heading to the next job* event, which FT5's job events can carry |
| **Manual-gap report** | questions the assistant could not answer from the manuals, grouped by model, so the office knows which manuals to add | **new:** the phone records when the retrieval gate refuses (`VaultRetriever`) and sends the question with the report. The question is the technician's own words going to base, so it is disclosed, and the technician can see what was sent |
| **Performance figures** | first-visit fix rate, time on site, repeat visits by model | **none:** derived from reports |

Suggested order: parts desk, follow-up queue, then history and the archive — cheapest, because the
data already arrives, and what the office uses every day.

**Dispatch connectors: offered, never relied on** (owner, 2026-09-25). Most North American
field-service firms already run dispatch software (ServiceTitan, Jobber, Housecall Pro, Salesforce
Field Service and others). The server connects to it where a firm has it, but **the console's own
jobs and schedule are the baseline and always work**: a firm with no dispatch software, or one whose
connector is down, still creates, schedules, assigns and sends jobs from the console.

- **The base server owns what the phones receive.** Every job reaches a phone as the server's signed
  `.ogjob`, whatever its source. **The phone never talks to dispatch software**, so no connector adds
  a destination to the phone's privacy copy, and changing or dropping one changes nothing on the
  phone.
- **Jobs in, status and reports out.** A connector imports jobs (by webhook where the product offers
  one, polling where it doesn't) and posts status and the finished report back. Outbound posts go
  through a queue keyed on the report's `op_id`, the same idempotency the phone uses, so an outage
  delays them and never duplicates them.
- **One owner per field.** An imported job's schedule and customer details belong to the dispatch
  system and update from it; a local change in the console is marked as an override and shown as
  one. What the phone reports (status, the work record) belongs to the base server and is only ever
  pushed out. That stops two systems overwriting each other in a loop.
- **An imported job is keyed on the product's own id**, so a re-import or a replayed webhook updates
  the job instead of creating a second.
- **A failing connector is visible, not blocking.** The console shows each connector's last good
  sync and what is waiting to go out; dispatch carries on regardless.
- **CSV import and export are the universal connector**, available for any product and any firm from
  the start. Then **one connector per product behind a common interface**, the pilot's product first.
- **Credentials** (usually OAuth tokens) are held on the firm's server, encrypted at rest like the AI
  key; the egress is from the firm's server to the firm's own dispatch vendor.

The accounting hand-off (Part 3) follows the same rule: the CSV export always works, and a connector
is an addition, never a dependency.

## Blue sky: what only this product can give the office

Added 2026-09-25 from the owner's question *"blue sky, from a base user, what else would be good to
have?"* All kept as candidates; none is scheduled. They come from what competitors' dispatch software
does not have: a first-person view of every job, answers grounded in the manuals, an identified
machine, and a structured, cited debrief. The same rule as *Later parts* applies — the phone
captures, the console decides, and missing phone capture gets built.

**The rule that comes before any of them.** Anything that reuses what the glasses saw or heard —
training footage, a senior's recorded walk-through, a review of past jobs — must fit the consent
rules already in the plans or change them openly: clips are silent and faces blurred (Plan FO P2b),
and live support is not recorded by default (Part 2, Plan M). Anything that runs a model on the
server is a new use of the organisation's AI key, which today is only sealed to phones: the
provider and what is sent to it are disclosed in the console, and the firm turns it on.

| Idea | What it gives the office | Builds on | Phone side | Consent and risk |
|---|---|---|---|---|
| **Ask the crew's work** | *"Which of our Lennox units threw E223 this winter, and what fixed it?"*, answered with the jobs, debriefs and manual pages cited | reports (Part 1), debrief items that already cite their turns, the manuals (Part 4) | none | a model on the server (above); answers cite or say there is nothing on file, never guess |
| **The job at a glance for the helper** | on a help request: tasks, manual pages opened, what the assistant suggested, photos, fault report — help without asking the technician to start over | escalations, the work record, Part 2's help queue | **small:** a live job snapshot sent with the help request (bounded, like the continuity snapshot) | only while help is requested; not kept after |
| **One senior, several apprentices** | a help queue ordered by urgency, each with a short summary ready before the senior joins | Part 2, the snapshot above | none beyond the snapshot | the summary is a model on the server (above) |
| **Record a senior's know-how** | a senior does a job while explaining it; base turns it into a guided procedure the glasses walk juniors through | vault procedures, Plan FP's review before anything is published | **new:** a narrated-procedure capture mode | audio and video of a customer's site; needs its own consent question, which FO P2b deliberately never asked |
| **Warranty claim packs** | a drafted manufacturer warranty claim — serial, fault code, failed part, photos — for base to check and submit | equipment identity (Plan EL), the vault's code tables, parts used, evidence | none | base submits, never the server on its own |
| **Same-day quotes** | a finding ("heat exchanger corroded") becomes a good/better/best quote with photos, reviewed by base and sent that day | debrief findings, evidence, the customer summary (FO P2c) | none | base reviews every quote; nothing goes to a customer unreviewed |
| **Equipment register and recalls** | every serial the crew sees: age, warranty status, contract renewal; a recall on a serial range, once the office confirms the match, gives it a call list and reaches the technician in the next brief | *Later parts* history, Plan EL | **small:** a recall notice delivered with the job and spoken in the brief | recall data from a trustworthy source only; a false recall alarm costs trust |
| **Parts for tomorrow** | from tomorrow's fault reports and each machine's history, what each van should carry; restock lists from what was used | the parts desk, history, `onVan` on parts requests | none | a suggestion, never an order |
| **Lone-worker safety** | a missed check-in, or no movement during a job, alerts base | Part 5's shift and check-ins | **small:** an *"I'm OK"* prompt and a timer the technician sets | inside Part 5's on-shift rules; never outside a shift |
| **Site notes that carry forward** | "dog in the yard", "asbestos in the ceiling", "needs a 10 m ladder", recorded once and read out before the next visit | the job brief (FO P3c), site history | **small:** a site-note capture, and a section in the brief | notes are about the site, never about the customer as a person |
| **Quality spot-checks** | a random sample of finished jobs reviewed from their evidence, feeding fix rates and coaching | the archive, *Later parts* figures | none | coaching, not discipline, by default; the technician can see which of their jobs were reviewed |
| **Voice messages to base** | *"tell base…"* on the phone; base's reply is read into the technician's ear | the parts-desk answer loop, generalised | **small:** a message tool and replies delivered by check-in, spoken at a turn boundary | the message is the technician's own words going to base, disclosed like the manual-gap report |

**Suggested first three:** warranty claim packs (recovers money from data that already exists),
asking the crew's work (makes everything recorded useful to the office), and the job at a glance for
the helper (makes every help call faster).

### Each idea in detail

Each section says what the office struggles with today, how the idea works, what it reuses, what
the phone and the server need, the consent and risk points, how we would know it works, and a rough
size (S: a few days, M: a couple of weeks, L: a month or more, server and phone together).

#### Warranty claim packs (M)

**The problem.** A manufacturer's warranty claim needs the serial, the install and failure dates, the
fault, the failed part and proof. Gathering them afterwards from a technician's memory and a phone's
camera roll takes long enough that firms often don't claim at all, and the parts cost comes out of
the firm's margin.

**How it works.**
1. A job closes with a part replaced on a machine the crew identified.
2. The server checks the machine against the equipment register (below) and the manufacturer's
   warranty terms, where the firm has entered them, and marks the job *possible warranty claim*.
3. It drafts the pack: make, model and serial, each with **where it came from**; the fault code and
   what the manual says about it; the failed and fitted part numbers; the job date; the *Fault* and
   *Fix* photos; the technician's name.
4. The base user checks it and submits it through the manufacturer's own portal, using a PDF and a
   CSV laid out the way that manufacturer asks.
5. The claim's status and the amount recovered are recorded against the job.

**Reuses.** `DeviceIdentityField` records model, serial, board part number, firmware and
refrigerant, each with its source (nameplate, spoken or the machine's display). Its own comment
already says why: *"a record that cannot say whether a serial was read by a camera or spoken by a
technician is a record a warranty department cannot use."* Evidence is already marked `fault` or
`fix` (`EvidenceSelection.Role`); parts are in the work record; fault codes are in the vault's code
tables.

**Phone side.** None to start. Later, the install date if the register can't supply it, read off the
nameplate or asked for.

**Server side.** Warranty terms per manufacturer (entered by the firm), claim templates, and a
claims list with status and amounts.

**Consent and risk.** Base submits every claim; the server never files one itself. Photos are the
blurred copies. A wrong serial is a rejected claim, so each value shows its source and a spoken
serial is flagged for checking.

**Measure.** Claims filed per month and dollars recovered, compared with before.

**Open.** Which manufacturers first. The pilot's vault is Lennox, so probably Lennox.

#### Ask the crew's work (M)

**The problem.** What the crew knows is spread across hundreds of reports that nobody rereads.
Questions such as *"what fixed E223 on these units?"* or *"when were we last at 14 Elm St, and
what did we replace?"* go to whoever happens to remember.

**How it works.** A search box in the console. The server finds matching reports, debrief items,
approved team learnings and manual passages, and a model writes a short answer **citing each job,
debrief item or manual page it relies on**. Each citation opens the source. If nothing matches, it
says there is nothing on file, as the job brief already does, and never guesses.

**Reuses.** The report archive; debrief items, which already carry `sourceTurnIds`; Plan FP's
approved learnings; the manuals from Part 4. The phone's retrieval rules (EJ's gate: cite, or
refuse) are the model to copy.

**Phone side.** None. Technicians already get the relevant history in the job brief (FO P3c).

**Server side.** A search index over the archive, and a model call using the organisation's AI key.

**Consent and risk.** A model on the server (see the rule above). Answers can contain customers'
names and addresses, so only administrators can use it and every question is kept in the audit
log. The technicians' own words in debriefs are the firm's records and are quoted as such.

**Measure.** Questions asked per week; how many answers the base user marks as useful; how many
answers came back with no citation (the target is none).

#### The job at a glance for the helper (S)

**The problem.** A help call opens with the technician explaining everything from the start:
which machine, what they've tried, what the manual said. That is the slowest part of the call.

**How it works.** A help request also sends a bounded snapshot of the open job: the machine and how
it was identified, the tasks and where each stands, the manual pages opened, what the assistant
suggested, the fault report, and thumbnails of the photos. The console shows it beside the relayed
view, so the helper starts from the same page as the technician.

**Reuses.** `FieldSessionContextSnapshot` already builds a bounded working view of the job (8,000
characters) for the live model; the helper's snapshot is the same kind of view, built for a person.
Escalations already carry a reason and a resolution time.

**Phone side.** Small: build the snapshot and attach it to the help request (the
`WebhookExpertNotifier` payload, or the base server's help endpoint).

**Server side.** Show it; drop it when the help request closes.

**Consent and risk.** Sent only with a help request, and kept only while that request is open. It
carries the assistant's suggestions labelled as suggestions, never as work done.

**Measure.** Time from the helper joining to the first useful instruction, and help-call length.

#### One senior, several apprentices (M)

**The problem.** Experienced technicians are scarce. Sending an apprentice out alone is a risk,
and sending two people costs twice as much.

**How it works.** One senior at base works a help queue. Each request shows how long it has waited,
whether a safety concern was raised, whether the customer is waiting, and a three-line summary of
the problem. The senior picks by urgency, answers some by voice message without video, and joins the
relayed view for the rest. Over time the firm sees which apprentices need help, on what, and how
often, and can decide when each is ready to work alone.

**Reuses.** Part 2's relay, the snapshot above, voice messages to base (below), the escalation log.

**Phone side.** None beyond the snapshot and voice messages.

**Server side.** The queue, the ordering, and the model call for summaries.

**Consent and risk.** The summary is a model on the server (see the rule above). "Who needed help"
is information about an employee's performance, so the firm's monitoring policy (Part 5) covers it,
and the apprentice can see their own history.

**Measure.** Apprentice jobs per senior per day; first-visit fix rate on those jobs; how long
apprentices wait for help.

#### Record a senior's know-how (L)

**The problem.** When a senior retires, their way of doing the jobs the manual explains badly
leaves with them.

**How it works.**
1. The senior switches on *Record a walk-through* on a job and explains what they're doing as they go.
2. **The phone keeps the transcript, not the audio.** Transcription happens on the phone and the
   recording is discarded, so a bystander's voice never becomes a file. The senior marks steps by
   voice ("next step") and takes photos as usual (faces blurred).
3. At base, the walk-through becomes a draft procedure: steps, the checks at each step, and photos.
   A model can do the first split into steps; a person edits it.
4. It is reviewed the way Plan FP reviews team learnings, then published into the organisation's
   vault as a procedure (the `procedures/*.json` format the glasses already walk technicians
   through), marked with who recorded it and who approved it.

**Reuses.** On-device transcription, vault procedures (Plan F), FP's review before anything is
published. Publishing is new: Part 4's manual set fills a vault's *documents* tier, and a
procedure is a vault file, so the overlay needs a procedure set of its own, signed and hash-checked
the same way.

**Phone side.** New: the walk-through capture mode and step marking.

**Server side.** A draft editor, the review queue, and publishing.

**Consent and risk.** The senior agrees to each recording. The customer is told a walk-through is
being recorded on their site, since photos and the senior's words are about their equipment. Plan
FO P2b never asked about recording audio, and this design avoids having to by keeping no audio.
A procedure can be wrong: it carries its review, and cites the manual wherever it contradicts it.

**Measure.** Procedures published; how often juniors use them; juniors' fix rate on those models.

#### Same-day quotes (M)

**The problem.** The technician finds a failing heat exchanger, and the quote goes out days later,
by which point the customer has called someone else.

**How it works.**
1. A debrief finding, or a task the technician skipped or put off, becomes *quote suggested*.
2. The console drafts good/better/best options from the firm's price list (kept in the console, or
   taken from the dispatch connector), with the *Fault* photos and a plain explanation drawn from the
   customer-facing summary wording.
3. The base user edits it and sends it by email or text link the same day.
4. The customer accepts on a simple page, and the acceptance becomes a new job.

**Reuses.** Debrief findings, tasks and their states, evidence roles, the customer summary's
allow-list (FO P2c), dispatch connectors.

**Phone side.** None. Later, *"quote them for it"* by voice, which is a voice message to base.

**Server side.** A price list, quote drafting, a customer acceptance page, and conversion to a job.

**Consent and risk.** Base reviews every quote; nothing reaches a customer unreviewed. Internal
notes never reach a quote, for the same allow-list reason as the customer summary. **The acceptance
page is the first page the base server shows to the public**, so it gets its own security review:
a single-use link, nothing on it but the quote, and it expires.

**Measure.** Quotes sent within 24 hours; the share accepted; revenue from accepted quotes.

#### Equipment register and recalls (M)

**The problem.** Firms don't know what equipment they look after, how old it is, when its warranty
ends or when a service contract is due. When a recall comes out, nobody can tell which customers are
affected.

**How it works.**
1. Every report adds or updates a register entry: make, model, serial, site, what was fitted, when.
   Entries merge on make plus serial.
2. The age comes from the serial where the manufacturer documents how the build date is encoded
   (many do, differently per make), and otherwise from the install date.
3. Warranty end and contract renewal dates come from the firm's own terms, giving a renewals list for
   the office.
4. **Recalls.** The server checks public recall sources (the US Consumer Product Safety Commission's
   recalls, Health Canada's recalls and safety alerts) and manufacturers' bulletins against the
   register. A match is a **lead**: the office confirms it, and only then does it produce a call list
   and a line in the next brief for that site.

**Reuses.** `DeviceIdentityField`, equipment identity (Plan EL), site details on jobs, the
*Later parts* history.

**Phone side.** Small: the recall line in the job brief (the *Known equipment* section).

**Server side.** The register, serial decoding per make, renewal dates, and the recall matcher.

**Consent and risk.** A false recall match costs trust, which is why the office confirms every one.
The register is the firm's customer data, held on the firm's server like everything else.

**Measure.** Contracts renewed from the renewals list; recall matches confirmed.

#### Parts for tomorrow (S–M)

**The problem.** A second trip because the van didn't carry the part is the most expensive way to
fix anything.

**How it works.** The evening before, the server looks at each of tomorrow's jobs: the fault report,
the manual's likely causes for that fault code, and what has failed on that machine and model
before. It suggests a short list per van (*"a flame sensor for the 9:00, a capacitor for the
11:30"*), each suggestion saying why. The technician ticks off what is already on the van. A weekly
restock list comes from parts used.

**Reuses.** Upcoming jobs and their fault reports, the vault's code tables, the history, parts
requests and their `onVan` flag.

**Phone side.** None beyond showing the list in the job brief (*Parts and prerequisites*).

**Server side.** The suggestion rules. These can start as plain rules (fault code to likely parts)
before any model is involved.

**Consent and risk.** A suggestion, never an order. Each item shows its reason, so a technician can
ignore it with good cause.

**Measure.** Return visits because a part was missing, compared with before.

#### Lone-worker safety (S)

**The problem.** A technician alone in a plant room or on a roof who falls or is hurt may not be
missed for hours. Several Canadian provinces, British Columbia and Alberta among them, require
employers to have a check-in procedure for people working alone.

**How it works.** On shift, the technician can start a working-alone timer (for example 60
minutes). When it runs out, the glasses ask *"are you OK?"*, and the technician answers by voice or
tap. No answer within a grace period alerts base, with the job, the site and the last known position.
A spoken *"I need help"* alerts base immediately.

**Reuses.** Part 5's shift and check-ins, the escalation path.

**Phone side.** Small: the timer, the spoken check and the alert. It must work when the app is in
the background, which is the hard part on iOS and needs testing on a device.

**Server side.** An alert that is hard to miss, with a clear record of who acknowledged it.

**Consent and risk.** Inside Part 5's rules: only on shift, and the technician starts it. It adds to
existing safety procedures and never replaces them. That limit is written down, because a phone that
can be out of signal is not a guarantee.

**Measure.** Check-ins answered, alerts raised and how quickly they were acknowledged, and meeting
the provinces' working-alone rules.

#### Site notes that carry forward (S)

**The problem.** The dog, the asbestos ceiling, the gate code and the need for a 10 m ladder are
learned again on every visit.

**How it works.** The technician says *"site note: …"* on a job. Base can add notes as well. A note
is one of three kinds: **hazard**, **access** or **equipment location**. It shows who recorded it and
when, and it has a review date. Hazard notes are read out before arrival and appear at the top of the
brief's *Site and history* section.

**Reuses.** The job brief (FO P3c), the site history.

**Phone side.** Small: the note tool and the section in the brief.

**Server side.** Notes per site, review dates, and editing.

**Consent and risk.** Notes are about the site and never about the customer as a person: no
opinions, which the customer could ask to see. A stale hazard note is worse than none, so notes past
their review date are shown as such.

**Measure.** Notes recorded, and notes read on later visits.

#### Quality spot-checks (S)

**The problem.** The only way to check a technician's work today is a ride-along, so it seldom
happens.

**How it works.** Each month the console picks a random sample of each technician's finished jobs.
A reviewer checks each against a short rubric (evidence present, tasks match the report, sign-off
handled, manual followed where it applies) using the job's own record. The results feed fix rates
and coaching.

**Reuses.** The archive, the evidence, *Later parts* figures.

**Phone side.** None.

**Server side.** Sampling, the rubric, and results per technician.

**Consent and risk.** Covered by the firm's monitoring policy (Part 5). The technician sees which of
their jobs were reviewed and what was found. By default it is for coaching; using it for discipline
is the firm's decision to state in its policy, not something the console does by default.

**Measure.** Share of jobs reviewed; trends in rubric scores.

#### Voice messages to base (S)

**The problem.** Small questions to the office ("is this covered by their contract?", "can I order
the blower motor?") mean a phone call that interrupts both people.

**How it works.** *"Tell base the customer wants a quote for a new furnace."* The phone reads the
message back and queues it with the job reference. Base sees it in the console and replies in
writing. The reply is delivered at the next check-in and read to the technician between turns. An
urgent message says so, and base is prompted to phone instead.

**Reuses.** The parts-desk answer loop, generalised; the read-back pattern from job intake.

**Phone side.** Small: the message tool and spoken replies.

**Server side.** An inbox beside the job, and replies.

**Consent and risk.** The technician's own words go to base, disclosed like the manual-gap report.
It is not a radio: a reply arrives at the next check-in, and the phone says so when a message is
sent.

**Measure.** Messages per day, time to reply, phone calls avoided.

**Deferred: drawing on what the technician sees.** The base user circles a part on the relayed
picture and it appears on the lens. Deferred on 2026-09-25 because most crews' glasses have no
display. Revisit when display glasses are common in the crews the product sells to.

## Privacy

- **On the phone:** `baseServer` is disclosed as FT requires. The relay and the manuals use the same
  host, so they add no destination. The in-app copy should add one sentence: when you ask for help,
  live video from the glasses goes to your organisation's server. A managed TURN service, if it ever
  comes, is a third-party destination and needs disclosing in `PrivacyInfo.xcprivacy` and the in-app
  copy in the same PR.
- **On the server:** the firm is the controller of its jobs, customers and reports. When the partner
  hosts it, the partner is the firm's processor and they need a data-processing agreement. The vendor
  is neither, because the vendor holds nothing.
- **Accounting:** the connector is an egress from the firm's server to the firm's own accounting
  package. It is not an egress from the phone.
- **Location (Part 5):** the phone's "Always" permission string and `privacy.html` currently promise
  location reminders only. The PR that first sends a position to `baseServer` rewrites both, and adds
  the on-shift sharing to the enrolment review. It also answers the question
  `PrivacyInfo.xcprivacy`'s header comment leaves open — revisit every *Linked* flag once there is a
  backend — for a named person's position sent to the organisation's server.

## Delivery

| PR | What |
|---|---|
| **FU0** | this plan; the partner agrees to host the pilot instance; the pilot's accounting package is named |
| **FU1** (server, headless) | the package skeleton, storage, administrator accounts and audit log; FT1's contract served — registration, the setup token, the approval queue, overlays signed in an isolated signer, job issuance as `.ogjob`, check-in, report intake with `EndpointSyncSink`'s semantics; the file-upload shape. Tests run against **shared golden fixtures** kept in this repo beside FT1's `Codable` shapes, so the phone and the server are proved against the same bytes |
| **FU2** (server) | the console for Part 1: phones, approvals, add phone(s) with QR codes, jobs, reports inbox |
| **FU3** | Part 2: the authenticated relay and the viewer page in the console; the escalation webhook received; **phone side** — relay and viewer addresses derived from `baseServer`, the streamer connection signed, the watcher count shown, the privacy sentence |
| **FU4** | Part 3: CSV export, then the one connector |
| **FU5** | Part 4: manual storage, the set in the overlay, signed resumable download (with FT4) |
| **FU6** | Part 5: the status board from job and shift events, the latest-position store, the monitoring-policy record and acknowledgements; counsel's confirmation of the jurisdiction table first (phone side is FT5) |
| **FU7** | dispatch connectors: CSV import and export first, then the connector interface and the pilot's product; per-field ownership, overrides, keyed imports, the outbound queue and connector health in the console. No phone change |

FU1 can start once FT1's contract is written, and it is also the stub FT2's tests need. Only FU3 has
phone-side code of its own; the rest of the phone side is FT's.

## Traps

| Trap | Consequence |
|---|---|
| One shared instance for several firms "to save hosting" | one breach, or one bad administrator on the host, reaches every firm's crew |
| `baseServer` on the partner's domain instead of the firm's | moving the firm in-house means re-minting and redistributing its profile |
| Answering 2xx before a report is durably stored | the phone may erase its copy (CT PR 4) and the record is gone |
| Treating a repeated `Idempotency-Key` as a new report | one visit filed, and invoiced, twice |
| The console offering an overlay field the phone refuses | an administrator believes a setting changed that never did |
| Signing keys readable by the web tier | a web-tier bug becomes the ability to sign overlays and jobs |
| Showing the AI key after it is entered, or logging it | the one secret the design keeps from everyone, leaked by the console |
| A viewer link that works without a console login | a forwarded link is a live view of a customer's site |
| Recording relayed video "for training" | consent nobody asked for (Plan M) |
| Invoice lines taken from the work record's notes instead of the signed summary | internal notes and escalations reach a customer |
| Adding TURN "just in case" | a third-party egress and a service to run, for a transport the pilot doesn't use |
| Calling "last checked in" "online" | an administrator trusts a stale phone as current (FT) |
| Hosting a Canadian firm's instance in the US "because it's cheaper" | a Quebec privacy impact assessment, and a harder sale |
| Letting dispatch wait on a connector | an outage at the firm's dispatch vendor stops its crew getting work |
| A phone that talks to dispatch software directly | a new destination per product on every phone, and the server no longer the one source of signed jobs |
| Both systems editing the same field | changes bounce between them, or one silently overwrites the other |
| Importing without the product's own id as the key | a replayed webhook dispatches the same job twice |
| Keeping a trail of positions "for reports" | a record of where each named engineer goes, including where the van parks overnight |
| Sending position outside a shift, or on a personal phone by default | the monitoring the law and the crew object to most |
| A position shown without its age | a dispatcher sends the nearest engineer who left an hour ago |
| Turning location sharing on without the enrolment review saying so | undisclosed monitoring, and the "Always" string's promise broken |

## Open questions

- **Does the partner agree to host the pilot instance**, and on what terms (the data-processing
  agreement with the firm, backups, who is on call)?
- **Which accounting package does the pilot firm use?**
- **Where does the server's code live?** Leaning: its own repository, with the wire contract and the
  golden fixtures kept here, because the phone is what they constrain.
- **Which language and stack?** Whatever the partner can run and maintain. Nothing in the contract
  prefers one.
- **Should the reviewer's queue for Plan FP (team learnings) move to the console?** FP designed it
  for a reviewer *phone* because there was no server. A console is the more natural home, but FP's
  decision stands until the pilot asks.
- **Which dispatch connector comes first?** Whichever product the partner or the pilot firm runs. The
  console's own scheduling is built either way (see *Later parts*).
- **Does Part 5 need a shift at all**, or is "a job is open or travelling to one" enough? Leaning:
  an explicit shift, because an engineer between jobs is exactly who dispatch wants to find.
- **Is the *Linked* flag in `PrivacyInfo.xcprivacy` set for location** once a named person's position
  goes to the organisation's server? The server is not the developer's, which is the argument for
  leaving it; the answer belongs in the PR that sends the first position.
- **Does the console need to show the job's live progress** (the task the technician is on), or is
  "status as last reported" enough? Leaning: last reported, fetched like everything else.
