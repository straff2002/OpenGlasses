# Plan NK — Clinic Stock in the Clinic's Own Workbook (one fridge's count shared by several staff, kept in the clinic's Microsoft 365, with no server of ours)

**Status:** 🚧 P0–P1 built (headless) 2026-11-27; decisions 1–4 taken as recommended. Built: the
workbook schema (`Movements`, `Counts`), row keys and the per-workbook send ledger (top-ups and
corrections as new rows), the fold back with the phone's ledger semantics and a patient-column
refusal, the comparison, `GraphRequestBuilder` and its transport, the `EntraOAuth` core, the
tenant-country notice, the `clinicStockRows` op and its sink, the `clinicStockRecord` route, the
sign-in, the connection sheet and the Stock screen's shared figure, and the support report line
(see "Built" below). 77 new tests in 8 classes. **Owed:** the app's Entra registration and its
client ID (owner; the build ships with `AVENKIN_ENTRA_CLIENT_ID` empty, so the feature says it isn't
set up), P2 catalog sync, P3 a real Canadian tenant, and P3 confirming the narrowest Graph
permission (whether the selected-files permission can replace `Files.ReadWrite`). It still waits on
where the clinic's stock spreadsheet lives (MY open question 10). Comes after Plan
[NJ](NJ-canada-inventory-only-clinic-stock.md), whose allow-listed row is the only thing this plan writes.
**Track:** Field Assist stock, for a medical clinic.
**Builds on:**
- Plan [MY](MY-vaccine-stock.md) §8b: several staff, one fridge, one shared record. Staff record
  what they take, never a new total; only a count states one.
- Plan [NJ](NJ-canada-inventory-only-clinic-stock.md): `ClinicalStockShareRow`, rows per day, no
  staff, no free text.
- Plan [MM](MM-stock-in-the-business-system.md): the connector pattern. A key in the Keychain, a
  transport that refuses redirects and foreign hosts, a pure request builder that allows only the
  writes its contract names, and a durable sink through the offline queue.
- Plan [T](T-offline-field-queue-and-sync.md): `OfflineQueue` and its `OpKind`s (`QueuedOp.swift`).
- The OAuth pattern of Plan [AI](provider-auth-and-fallbacks.md): `GoogleOAuth` (a pure core, the
  user's own client, `ASWebAuthenticationSession`) and `GoogleOAuthService` (the edge).

---

## Trigger

MY §8b set out where one fridge's shared count could live. The clinic's EMR is first choice, but
the EMR is not yet known and the research found no vaccine-inventory API in the major Canadian
EMRs. The clinic's own shared spreadsheet comes next. A company server is ruled out.

The research report of 2026-11-27 (kept outside the repo; not legal advice) compared the three
routes. It found that a **Microsoft 365 tenant provisioned in Canada keeps Exchange, SharePoint,
OneDrive and Teams data at rest in Canada, at no extra cost**, under Microsoft's standard product
terms (Microsoft Learn, 2026-10-08). An Excel workbook in SharePoint or OneDrive is covered.

**Google Workspace data regions are the United States or Europe only** (Google Workspace Admin Help,
2026-11-10). For inventory-only data that hardly matters. For patient data it would.

The phone talks straight to the clinic's tenant with the clinic user's own sign-in, and the company
holds no tokens and no data. On that design the company is plausibly a software supplier, not the
clinic's agent or information manager [confirm with Canadian counsel].

## The point, said once

Each phone writes the day's stock rows (per lot, no staff, no times) to a table in a workbook the
clinic owns, in the clinic's own Microsoft 365. Each phone reads the rows back to know the fridge's
count. Nothing passes through us.

## What exists (verified 2026-11-27 on `origin/main` a93bd76b5)

- **No Microsoft Graph code.** Nothing under `OpenGlasses/Sources` calls `graph.microsoft.com` or
  signs in with Entra ID.
- **An OAuth pattern to follow:** `GoogleOAuth` (`Utils/GoogleOAuth.swift`) is a pure core over a
  client the user registers, with the browser flow in `ASWebAuthenticationSession`.
  `GoogleOAuthService` is its edge.
- **A durable queue:** `OfflineQueue` (`Services/Offline/OfflineQueue.swift`) with `OpKind`s
  including `stockSystemParts` (MM) and `partsRequest` (EM).
- **One clinical write-back allowed under Local Only:** the FHIR export, because its destination is
  the operator's own record system (`NetworkRouteRegistry.swift` L451-453). Every other route is
  blocked while Local Only is on.
- **The phone's own ledger** (`VanStockStore`, `VanStockLedger`) and MY's count per lot.

## Design

### 1 · The workbook

The clinic creates (or the app offers to create) one workbook in a SharePoint site or OneDrive
folder it chooses. The workbook holds two Excel tables:

- **`Movements`:** one row per day, line, lot, kind and reason, exactly `ClinicalStockShareRow`
  (NJ §1). The columns are day, line number, line name, lot, expiry, kind, quantity, reason and a row
  key. **No staff, no time, no free text, no patient.**
- **`Counts`:** one row per count. Day, line, lot, the figure counted, and a row key.

The fridge's figure is the fold of these rows. The phone computes it with the same ledger code as
for its own list, so the workbook needs no formulas. Staff can still read it, sort it and print it
as an ordinary spreadsheet.

### 2 · Writing without conflict

- **Append only.** A phone adds rows. It never edits or deletes another phone's row. A correction
  is a new row with the opposite quantity, the way `reversed` works in the log.
- **Once each.** Every row carries a key made from the phone's seat, the day, the line, the lot, the
  kind and a sequence. A row queued offline and sent twice is found by its key and not added again.
- **When a phone sends.** It folds its own new movements into per-day rows and sends them through
  `OfflineQueue` under a new `OpKind`, `clinicStockRows`: at the end of the daily check, on demand,
  and on the next launch after an offline day. A day still open is sent as "so far", and its rows are
  topped up later, never rewritten.
- **Reading back.** The phone reads both tables (paged), folds them and shows the shared figure
  beside its own. When the two differ it says so. It never overwrites either one.

### 3 · Sign-in, scope and residency

- **Whose app registration** (Decision 1). The app ships one multi-tenant public-client
  registration, which the clinic's administrator consents to once. The alternative is the clinic's
  own registration, the way `GoogleOAuth` takes the user's own client ID. Either way the token stays
  on the phone, in the Keychain (`…ThisDeviceOnly`), and never reaches us.
- **The narrowest permission that reaches one workbook.** P3 (on a real tenant) confirms whether Graph's
  selected-files permission works for an Excel table, or whether delegated `Files.ReadWrite` is
  needed. If it is the broader one, the request builder allows only the one workbook's table
  endpoints.
- **The tenant's country.** At first sign-in the app reads the organisation's country from Graph.
  If it is not Canada (for a Canadian clinic), it says plainly that the data may be stored outside
  Canada. It never blocks: for inventory-only rows this is a disclosure, not a prohibition.
- **The transport** follows MM: Microsoft's hosts only, no redirects off them, response size capped,
  and only the named writes allowed.

### 4 · The route, under Medical mode

The workbook gets its own entry in `NetworkRouteRegistry`, `clinicStockRecord`, with data classes
"inventory rows" and "an OAuth token". Its medical policy is `.notApplicable` for the same reason as
the FHIR export: the destination is the clinic's own record system, and Local Only governs
third-party egress.

**A guard test fails if the route's payload type is anything other than `ClinicalStockShareRow`.**

`MedicalEgressGuard`'s wording ("nothing derived from what was captured may leave this device")
gains the exception it already lives with for FHIR: "except to your own record system".

### 5 · Google Sheets (Decision 2)

The same design fits a Google Sheet through the Sheets API, for inventory-only rows. It is not built
here, because Workspace has no Canada region and Google's verification rules for Drive scopes were
not checked. A clinic on Google can still use the phone-only ledger and MY's exports.

### 6 · A clinic with neither (not built)

For a clinic with no Microsoft 365 or Google Workspace, the research's fallback is the company portal
(the Mac and tunnel of Plans [JS](JS-licence-sales-and-device-seats.md) and
[ND](ND-company-settings-from-the-portal.md)), **inventory-only and with these fixes**:

- This plan's row type, and nothing else.
- No edge caching on clinic paths (ND already serves signed profiles from an edge copy).
- A one-page data schedule naming the New Zealand host and Cloudflare's decryption in transit.
- The Mac hardened: FileVault, an encrypted off-site backup with a restore test, a UPS, and MFA on
  admin.

The research sized that at 1–2 weeks with almost no cash cost. It also found the portal **not
acceptable as built for patient-linked data** in Canada, New Zealand, the US or Australia (Plan NL).
It is recorded here so the choice is not made again from scratch. It is a separate plan if a clinic
needs it.

## Phases

- **P0 — the core (headless).**
  - The workbook schema: both tables and their column order.
  - Row keys, and folding the phone's movements into per-day rows.
  - Folding the tables back into figures.
  - Comparing the shared and own figures.
  - The pure Graph request builder, allowing only table add-rows and list-rows on one workbook.
  - The OAuth core with PKCE, and the tenant-country check.
  - The `clinicStockRows` `OpKind` and its sink.
  - The route-registry entry and its payload guard.
- **P1 — the edge and the screens.**
  - Sign-in in `ASWebAuthenticationSession`, and choosing or creating the workbook.
  - The shared figure on the Stock screen.
  - The "differs" line.
  - The country notice.
  - The support report lines: connected, the workbook's name, the last send, rows queued (counts
    only, no values).
- **P2 — catalog sync.**
- **P3 — a real tenant (owed).** A test tenant provisioned in Canada; two phones writing the same
  day offline and online; the clinic's administrator consent screen; a row inspected.

**Rough size:** P0–P1 take 1–2 weeks for one developer. P2 takes a day.

## Built (P0–P1, 2026-11-27)

Code under `Services/FieldAssist/ClinicWorkbook/`, `Utils/EntraOAuth.swift` and
`App/Views/Job/ClinicWorkbookViews.swift`. Where it differs from the design above, and why:

- **Row keys** are `<seat>.<base>.<sequence>`: a hash of a random seat id made on the phone (kept in
  the Keychain, not the licence seat, so nothing the vendor knows reaches the clinic's workbook), a
  hash of what the row is about, and a sequence. The phone keeps a per-workbook ledger of what it
  has sent by key, so a day sent twice adds nothing and a top-up or correction adds only the
  difference under the next sequence. The sink also reads the tables' keys before adding, so a retry
  after a lost reply adds nothing. A row taken back by undo becomes a row of the opposite quantity; a
  count is never taken back (the next count replaces it). The first send covers the list's whole
  history, later ones a 62-day window from the start of its first week. A phone with no ledger (a new
  install) rebuilds it from its own seat's rows in the workbook.
- **A count stands for the end of its day.** The workbook has the day, not the minute, so a dose given
  after the day's count is in the record but the day closes at the figure counted; on that day the
  shared figure and the phone's can differ by it, and the "differs" line says so. The rest of a day's
  movements fold as one net change per lot, so the order rows sit in the table does not matter.
- **Creating the tables needs two more writes** than §1 listed: the heading row of each new sheet
  (exactly the fixed headings) and the new table's name (one of the two). Reading needs each table's
  column names (`…/columns?$select=name`). The builder allows these and nothing else.
- **Text cells go with a leading apostrophe** so Excel keeps a lot "1E5" or a line number "0123" as
  text; numbers go as exact decimals. Reading accepts Excel's date serials too. P3 confirms both on a
  tenant.
- **Quantities are exact** in the workbook (the small-cell rule is for reports and exports); a
  sensitive line still goes by the week.
- **The opening figure of an imported list is not a movement**, so it does not reach the workbook; the
  clinic's first count does.
- **When rows go (Decision 3):** at the end of the check against the EMR, on demand ("Send to the
  clinic's workbook"), and on the first launch of a day. Only a clinical list; a van's list is refused.
- **Sign-in:** authority `organizations`, PKCE S256, redirect `avenkin-entra://auth` (registered in
  the Info.plist), scopes `offline_access User.Read Files.ReadWrite`, an ephemeral browser session.
  The client is the clinic's own when entered on the phone, else the build's
  (`AvenkinEntraClientID`).

**For the owner — the Entra registration:** in the Microsoft Entra admin centre, App registrations ›
New registration; supported account types "Accounts in any organizational directory (multitenant)";
platform "Mobile and desktop applications" with the redirect URI `avenkin-entra://auth`; Authentication ›
Allow public client flows: Yes; API permissions › Microsoft Graph delegated `User.Read`,
`Files.ReadWrite` and `offline_access` (no secret, no certificate). Put the Application (client) ID in
`AVENKIN_ENTRA_CLIENT_ID` in `project.base.yml` and regenerate. A clinic's Microsoft 365 administrator
then consents once (the app's sign-in shows them the consent screen, or they grant it from Enterprise
applications).

## Tests

- `ClinicalStockWorkbookSchemaTests`: the column order; a row round-trips; no column outside NJ's
  allow-list.
- `ClinicalStockRowKeyTests`: the same day sent twice adds once; a correction is a new row; a topped-up
  day adds the difference only.
- `ClinicalStockWorkbookFoldTests`: rows and counts fold to the same figures as the phone's ledger
  over a fixture.
- `GraphRequestBuilderTests`:
  - Only the named table endpoints on one workbook id.
  - A foreign host, a redirect and an oversized response are each refused.
- `EntraOAuthTests`: PKCE, the redirect, token parsing, and refresh.
- `TenantCountryNoticeTests`: Canada gives no notice; another country gives the notice and does not
  block.
- `ClinicStockRouteGuardTests`:
  - The route's payload is `ClinicalStockShareRow`.
  - Its medical policy is `.notApplicable`.
  - It is still refused for a van list.
- `OfflineQueue` tests for the new `OpKind`, and every existing stock, network-route,
  medical-egress, org-profile and catalog guard class; the full suite and a Release build.

## Decisions for Greig

1. **App registration.** *Recommend:* one multi-tenant registration of ours, consented to by the
   clinic's administrator. It is one step for the clinic, and still no server of ours.
   *Alternative:* the clinic registers its own app, as Vertex does. That gives the most control but
   is a hard ask of a clinic.
2. **Google Sheets.** *Recommend:* not now. Build it only if a pilot clinic is on Google.
   *Alternative:* build both connectors in P0.
3. **When rows are sent.** *Recommend:* at the daily check, on demand, and after an offline day.
   *Alternative:* within a minute of each movement, which is more current but sends near-dose-level
   rows during a quiet day.
4. **A different tenant country.** *Recommend:* notice, not a block, for inventory-only rows.
   *Alternative:* block outside Canada for a Canadian clinic.

## Not in scope

- **The EMR's own inventory** (MY Decision 9, MM's pattern). That waits on the EMR, an API and the
  vendor.
- **Patient data of any kind** (Plan NL).
- **Editing the workbook's rows from the app**, other than appending.
- **The company-portal fallback** (§6), recorded but not built.

## Risks

- **Graph's permissions may be broader than one file.** The request builder then carries the
  narrowing, and the consent screen shows the broad scope. P0 settles which.
- **Staff edit the workbook by hand.** Rows they add are read like any other. A deleted row changes
  the shared figure, and the "differs" line shows it.
- **A tenant provisioned outside Canada.** §3's notice tells the clinic. For inventory-only rows that
  is enough.
- **Consent friction.** A clinic without an IT administrator may not know how to consent. P1's
  setup screen says who has to do it and what they will see.
