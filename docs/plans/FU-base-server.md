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

**Jobs.** A job is created in the console, assigned to one phone (by enrolment id) or left for anyone,
and served as a signed `.ogjob` — the same file `Scripts/make-job-file.swift` makes today, whose `Body`
must stay field-for-field identical to the app's `JobFile.Body`. The phone fetches it and runs it
through `JobFileImportPolicy` unchanged, so a job from the server and a job from email are the same
file. The email path stays beside the server (FT's leaning), and the console can download a job as an
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
- **Does Part 5 need a shift at all**, or is "a job is open or travelling to one" enough? Leaning:
  an explicit shift, because an engineer between jobs is exactly who dispatch wants to find.
- **Is the *Linked* flag in `PrivacyInfo.xcprivacy` set for location** once a named person's position
  goes to the organisation's server? The server is not the developer's, which is the argument for
  leaving it; the answer belongs in the PR that sends the first position.
- **Does the console need to show the job's live progress** (the task the technician is on), or is
  "status as last reported" enough? Leaning: last reported, fetched like everything else.
