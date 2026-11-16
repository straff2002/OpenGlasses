# Plan MB — Crash-Aware Support Reports (the phone notes where a crash happened, and the report says so)

**Status:** 📝 Drafted 2026-11-16 — nothing implemented.
**Track:** Diagnostics, every build and every channel (store, TestFlight, phone-only).
**Builds on:**
- Plan [DC](DC-diagnostics-and-bug-reporting.md): `DiagnosticsReportBuilder`, `DiagnosticsRedactor`
  and its rule that a report exists only when someone makes one. This plan keeps that rule and the
  "no crash-reporting SDK" stance in DC's *Out of scope*.
- `DiagnosticRing` (`Services/Diagnostics/DiagnosticRing.swift`) and `DiagnosticExportBuilder`: the
  local, bounded event history that already survives relaunches.
- The screen breadcrumbs added with the September list hardening (`ea965c4ba`): `.diagnosticScreen()`
  and `.ogFormStyle()` in `App/Views/Components/OGDesign.swift`, and `ChatListView`'s `listUpdated`.
- Support reporting (`App/SupportReporting.swift`): `SupportPrompt`, the review sheet, nothing sent
  without Send.

**Sits beside:** `DataStoreRegistry` (every store on the phone declared, with retention and delete),
`PrivacyLog`'s classification table, `TelemetryOptOutGuardTests`.

---

## Trigger

Build 688 crashed three times in forty minutes on one tester's phone. Organizer showed UIKit's
*invalid number of items in section* assertion, raised while a SwiftUI `List` applied an update, and
not one frame of our code. We could say *a list repeated a row id* but not *which list*. A sweep of
every `ForEach` found eleven that could; we fixed all eleven and still cannot say which one crashed.

The phone knew. Every `Form` and `List` screen styled with `.ogFormStyle()` logs when it appears, and
`DiagnosticRing` keeps those events for seven days across runs. But:

- nothing tells the tester the app crashed, or asks them to send a report;
- a report that is sent says of the earlier run *"exit reason unknown"*
  (`DiagnosticExportBuilder.swift:83`), so the run that crashed reads like any other;
- the ring writes to disk on a one-second delay (`DiagnosticRing.swift:405`), so a crash can lose the
  very events that matter;
- and Apple's crash logs in Organizer cannot carry any of it.

## Outcome

- **After a crash, the next launch says so, once.** *"Avenkin closed unexpectedly at 9:45 pm. Send a
  report so we can fix it?"* Tapping it opens the same review sheet as today; nothing leaves the phone
  without Send.
- **The report names the run that crashed and what was on screen.** The earlier run's section reads
  *"Ended in a crash at 21:45:20 — SIGABRT, NSInternalInconsistencyException (UICollectionView):
  invalid number of items in section %ld …"*, followed by the last screens that run opened, newest
  last.
- **Our own frames can be named on the Mac.** The report carries the crash's call stack as binary
  UUIDs and offsets; a script symbolicates it against the archive.
- **The last screen survives the crash.** Screen changes are written at once, not a second later.
- **A list that repeats a row id is caught before it crashes** — by a source test for new
  text-keyed loops in a `List` or `Form`, and by a count-only event when a list's data repeats an id
  at run time.

## What exists, and what doesn't

**Exists (verified against `main` on 2026-11-16):**
- `DiagnosticRing`: up to 14,000 events per run, 7 days, a launch window that is never evicted, each
  entry tagged with its run's random id; persisted on a 1 s coalesced write; cleared by
  `DiagnosticRing.shared.clear()`; declared as `.diagnosticBreadcrumbs` in `DataStoreRegistry`.
- `.diagnosticScreen(_:)` logs `screenAppeared` / `screenDisappeared` with the call site's file name
  (fixed vocabulary, never a title). About 163 call sites use it through `.ogFormStyle()`; the app has
  about 192 `List {` / `Form {` bodies, so some screens are not covered.
- `DiagnosticExportBuilder` prints the current run, then *"Previous run (may be a different app
  build; exit reason unknown)"*.
- `SupportPrompt` + the review sheet: offered today only after a failed AI turn, with a quiet period
  after a dismissal.
- `AppBuildIdentity`: build, commit and channel at the top of every report.

**Doesn't exist:**
- Any MetricKit use. The app never learns that it crashed.
- A crash-time-safe record of the last screens.
- Any check, at build time or run time, that a list's rows have distinct ids.

## Design

### 1 · Crash diagnostics from MetricKit, kept on the phone

`MXMetricManager.shared.add(_:)` at launch. On the next launch after a crash, iOS hands the app an
`MXDiagnosticPayload` with an `MXCrashDiagnostic` (and `pastDiagnosticPayloads` holds ones delivered
while the app was not subscribed). MetricKit sends nothing anywhere; it is a local delivery from the
OS. On iOS 27.3 the Objective-C exception reason moves to `CrashDiagnostic.ObjectiveCExceptionReason`;
the deployment target is iOS 26, so the reader takes the `MX…` types and the newer struct behind
`#available`, and both decode to one value type.

`CrashNote` (pure, `Codable`) is what is kept, built from the payload's `jsonRepresentation()` so
the core is tested on JSON fixtures, headless:

- when: the payload's time window and the crash's own timestamp where present;
- app build and OS version from the diagnostic's metadata;
- `exceptionType`, `exceptionCode`, `signal`, `terminationReason`;
- for an Objective-C exception: `exceptionName`, `className`, and `formatString` with only its
  **numeric** arguments filled in. `composedMessage` is not kept: an exception message can embed an
  object's description, which can be user text. *"invalid number of items in section %ld … (%ld)
  must be equal to … (%ld)"* is what we need, and it survives.
- the call stack tree as frames of (binary name, binary UUID, offset), capped at the crashed thread
  plus 40 frames — no symbol names are resolved on the phone.

Stored in `CrashNoteStore` (Application Support, `completeUntilFirstUserAuthentication`, excluded
from backup), at most 10 notes, 7 days, cleared with the ring. Declared in `DataStoreRegistry` as
`.crashNotes`, data class `.operationalAudit`.

### 2 · The report names the crashed run

`CrashRunMatcher` (pure) matches each note to a run in the ring: the run whose events span the crash
time (first event ≤ crash ≤ last event + 5 s), and whose build matches the note's. No match, or two,
and the note is printed on its own under *"A crash the phone recorded (run not identified)"*.
`DiagnosticExportBuilder` then prints, for a matched run, *"Ended in a crash at …"* with the
summary line and the crash's frames, in place of *"exit reason unknown"*. An earlier run with no note
keeps today's wording: no note is not proof of a clean exit.

### 3 · Ask once, after a crash

On the launch that receives a new note (newer than the last one shown), the support banner shows
*"Avenkin closed unexpectedly at 9:45 pm. Send a report so we can fix it?"*. It opens the review
sheet with the day of the crash and the troubleshooting layer, as Settings' report does. One banner
per note; dismissing it is final for that note; a note older than 24 hours when it arrives is kept
for the report but not offered. Copy names no plan letters.

### 4 · The last screens survive

`LastScreens` (pure ring of 8 tokens + run id + times) written atomically on a utility queue on
every `screenAppeared` / `screenDisappeared`, with no coalescing delay; a few hundred bytes. The
export prints it for the crashed run when the ring's own tail stops short of it. The modifier stays
the only writer, so the vocabulary stays file names.

Coverage: P0 lists every `List {` / `Form {` body without `.ogFormStyle()` or `.diagnosticScreen()`;
P1 adds the modifier to each, or records why not.

### 5 · Repeated row ids, caught before the crash

- **Source guard (`RowIdentityGuardTests`).** Scrapes `OpenGlasses/Sources/App` for `ForEach` and
  `List(…, id:)` whose key is `\.self` or a field (not `\.id`, `\.offset`, `\.rawValue`) in a file
  that has a `List` or `Form`, and fails on any site missing from `RowIdentityRoster`, a
  compile-checked list where each entry says why its ids cannot repeat (*constant*, *de-duplicated at
  file:line*, *menu picker*, *not a list row*). The 2026-11-16 sweep's verdicts seed it. The same
  shape as `OutboundFrameConsumerTests`.
- **Run-time event.** `RowIdentity.repeats(in:)` (pure) counts repeated ids. A `.uniqueRowsCheck()`
  helper on the eleven sites fixed in that sweep, and on any rostered site whose data is not
  constant, logs `listRowsRepeated` with the screen token and the count — never the ids. It never
  changes what is shown.

## Decisions for Greig

1. **MetricKit, on by default.** *Recommended:* yes; it is an OS delivery to the app, nothing is
   transmitted, and the note leaves only inside a report the person sends. *Alternative:* a
   Developer switch, off by default — which misses exactly the testers who never open Developer.
2. **What of the exception message is kept.** *Recommended:* name, class, format string and numeric
   arguments only. *Alternative:* the composed message through `DiagnosticsRedactor`, which is more
   readable and occasionally carries text we cannot predict.
3. **The banner after a crash.** *Recommended:* once per crash, within 24 hours, in every channel.
   *Alternative:* TestFlight builds only.
4. **Disclosure.** *Recommended:* one sentence in the in-app privacy copy (*"If Avenkin closes
   unexpectedly, the phone keeps a short technical note of where. It is sent only in a report you
   choose to send."*) and no `PrivacyInfo.xcprivacy` change, since nothing is collected off the
   device.
5. **The source guard.** *Recommended:* yes, failing the build on a new unrostered site.
   *Alternative:* a warning only.
6. **A deliberate crash for the device pass.** *Recommended:* a *Crash the app now* row in the
   Developer panel, shown only in Debug builds and when `AppBuildIdentity.channel` is
   `.testFlight` (the store and TestFlight share one binary, so this is a run-time check, not a
   compile-time one), so P3 can check a real crash end to end.

## Phases

### P0 — the deterministic cores (headless)

- `CrashNote` from MetricKit JSON fixtures (a SIGABRT with an ObjC exception, a SIGSEGV, a watchdog
  termination, a payload with no crash), including the numeric-argument filter.
- `CrashNoteStore` (bounds, age, clear) + its `DataStoreRegistry` entry, kept green under
  `DataStoreRegistryTests`.
- `CrashRunMatcher` (match, no match, two candidates, build mismatch).
- `DiagnosticExportBuilder`'s crashed-run section, and `LastScreens`.
- `RowIdentity.repeats(in:)`, `RowIdentityRoster` seeded from the sweep, `RowIdentityGuardTests`.
- The list of `List`/`Form` bodies without a screen breadcrumb.
- ~25 tests.

### P1 — live

- The MetricKit subscriber at launch, `pastDiagnosticPayloads` on first subscribe.
- The crash banner through `SupportPrompt` and the review sheet.
- `LastScreens` written from `.diagnosticScreen`; the missing breadcrumbs added.
- `.uniqueRowsCheck()` on the fixed sites; the privacy copy sentence.

### P2 — symbolication on the Mac

`Scripts/symbolicate-crash-report.sh <report> <xcarchive>`: finds the crash section, matches the
app binary's UUID to the archive's dSYM, and runs `atos` on our frames. System frames stay as
offsets (the Mac rarely has the device's system symbols; see the Organizer note on mis-symbolication).

### P3 — device pass (owed)

On a phone: Xcode's *Debug › Simulate MetricKit Payloads*, then the Developer crash row on a
TestFlight build. Check the banner, the review sheet, the crashed-run section, the last screens, and
the symbolicated frames against the archive.

## Risks

- **MetricKit delivery is the OS's to time.** Payloads usually arrive on the next launch, sometimes
  later. The banner may come a launch late; the 24-hour cut keeps it from coming days late.
- **Run matching can be wrong across a quick relaunch.** The 5 s slack and the build check keep it
  conservative; an unmatched note is printed on its own rather than guessed.
- **The source guard can be noisy.** A roster entry is one line with a reason; the cost is meant to
  fall on a new text-keyed list in a `Form`, which is the case that crashes.
- **iOS 27.3's API change.** Both shapes decode to one `CrashNote`; fixtures cover both.

## Out of scope

- **Any crash-reporting SDK or server.** Nothing is uploaded on its own, as in Plan DC.
- **Apple's TestFlight and Organizer crash logs.** Unchanged; they cannot carry app breadcrumbs.
- **Hang, CPU and disk diagnostics** from the same payloads. Kept for a later plan if crashes prove
  the shape works.
- **Symbolicating on the phone.** Release builds carry no symbols; the Mac does it.
