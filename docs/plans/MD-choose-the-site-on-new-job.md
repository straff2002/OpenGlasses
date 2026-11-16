# Plan MD — Choose the Site on New Job (the customer or site first, and its units with it)

**Status:** 📝 Drafted 2026-11-16. Nothing is implemented yet.
**Track:** Field Assist / jobs.
**Builds on:** Plan [HC](HC-jobs-list.md) (the New job page), Plan [HV](HV-site-system-vaults.md) (site documents in
a vault and `SiteSystemMatcher`), Plan [FO](FO-guided-job-flow-and-job-tab.md) (jobs ahead and `applyJobAhead`), Plan
[JR](JR-workiz-from-the-phone.md) (Workiz jobs in Scheduled).

---

## Trigger

The owner, 2026-11-16: should a technician be able to choose manuals on the New job page already, or at least
the site or customer, with that site's subset?

Today `NewJobView` offers three things: the vault in use (a link to Field Assist settings), an optional job
number with **Start job**, and **Schedule a job for later**. A job started there has no site until a job
ahead supplies one. The vault's site document is matched only from evidence: serials, models, or the
external location or equipment ids in a job file (`SiteSystemMatcher`). A Workiz job brings the customer's
name, address and phone but no location or equipment ids, so it never matches a site document. A job started
by voice or from New job matches only once a serial is heard.

## The answer, in one line

**Choose the site, not the manuals.** A site brings its units, and the units bring their manuals. A manual
picker would be a second source of truth that could disagree with the identified machine. That is the same
reason the vault row links to settings and has no picker of its own.

## Proposal

### 1. A Site row on New job

It sits between *Vault in use* and *Start now*. It reads **Site: none chosen** until something is chosen,
then shows the site's label and how many units the site lists ("Smith Street plant room · 4 units").
Choosing is optional. Start job with no site behaves exactly as it does today.

### 2. What the picker offers, in order

One searchable list, built by a pure model (`NewJobSiteChoices`):

1. **Today's jobs from Scheduled**, including Workiz's. Picking one makes Start job start **that job ahead**
   (`startUpcomingJob`), with its number, site, fault, notes and brief, exactly as tapping it in Scheduled
   does. Its number fills the job-number field.
2. **Documented sites in the vault in use** (`VaultStore.siteDocuments()`), by `location_label` else name,
   with the unit count. Picking one sets the job's site match as **chosen by the technician**.
3. **Recent sites from this phone's past jobs** (`JobHistoryIndex`), by customer and address, deduplicated
   by `siteKey`. Picking one fills the job's `JobSite`, so the history's "same site" visits and the report's
   site line work from the start. These carry no units unless one also matches a site document.
4. **A new site**: customer and address typed in, the same fields as *Schedule a job for later*.

When a recent site or a scheduled job is also a documented site, it is shown once, as the documented site,
with the customer's details beside it.

### 3. What a chosen site does to the job

- **`SiteSystemMatch` gains a basis `.chosen`**, with strength `confirmed`. The technician is on site and
  said so, which is stronger than a model match and weaker than a serial. The brief, the live line, the
  announcement and the job page then say the site and list its units, as HV already does for a match.
- **A serial heard later is weighed with the choice, not instead of it.** If the serial names a unit at the
  chosen site, nothing changes. If it names a unit at another documented site, the job says so once ("That
  serial is listed at Elm Road, not Smith Street — which is it?"). It never switches the site silently.
- **Manuals:** the site's units are the ones the model is told about first. Retrieval still scopes to the
  identified machine as it does today (decision 2 below).
- Logs carry the site's id and the unit count only. No customer text reaches a log, as HU and HV already
  require.

### 4. Workiz and other connected jobs (later phase, decision 3)

A Workiz job never matches a site document on its own. When a technician picks a documented site for a Workiz
job, the phone can **remember that the Workiz client is that site**: a local link from `workiz` `CL-…` to the
site document's id. The next job for that client then matches as `confirmed` with basis `location`, with no
choice needed. The link lives on this phone only. It is listed and removable in Field Assist settings and
never written back to Workiz.

## Decisions owed (the owner)

1. **Is a technician's choice `confirmed` or `probable`?** *Recommended: confirmed, basis `chosen`,* so the
   site is said plainly. A contradicting serial still raises the question (§3).
2. **Should a chosen site narrow manual search to its units?** *Recommended: prefer, not restrict.* The
   site's units are ranked first until a machine is identified, and nothing is excluded. Site documents can
   be out of date, and a machine missing from the document still needs its manual.
3. **Remember a Workiz client's site (§4) in this plan, or later?** *Recommended: in this plan, as P2.* It is
   what makes a Workiz firm's site documents useful at all.
4. **By voice:** should "start a job at Smith Street" choose the site? *Recommended: yes, but only against
   the same choices list, read back before the job starts,* the way a job number is read back today.

## Phases

- **P0 — the choices and the chosen match** (headless). `NewJobSiteChoices` (sources, order, dedupe,
  search), `SiteSystemMatch.Basis.chosen`, and the contradiction rule in `SiteSystemMatcher`, all with tests.
  Choosing a scheduled job routes to `startUpcomingJob`. Choosing anything else starts an ordinary job, then
  applies the `JobSite` and the match.
- **P1 — the Site row and the picker** in `NewJobView`, with VoiceOver labels. A catalog sync for the new
  strings is owed in its own PR.
- **P2 — remembered Workiz client sites** (if decision 3 is taken): the local link, its settings list, and
  the matcher reading it as a location reference.
- **P3 — device check:** start from a documented site, a recent site, a Workiz job and a new site. Hear a
  serial that agrees and one that contradicts. Confirm the report's site line and the history's same-site
  visits.

## Not in this plan

- A manual picker on New job (see "The answer, in one line").
- Pulling sites or equipment from Workiz. Its v2 API has no location or equipment resource. Custom fields
  for model and serial would be a separate plan.
- Writing a chosen site back to any field-service system.
