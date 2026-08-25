# Plan DC — Diagnostics & Bug Reporting

**Status: ✅ Shipped** — `DiagnosticsReportBuilder` + `DiagnosticsRedactor` (pure, 20 tests),
`SubsystemProbes` extracted so the six-probe self-test is shared rather than owned by the Developer
panel, and a top-level **Diagnostics & Support** settings category that survives Simple Mode.

## The problem, as observed

Two halves of the same gap.

**There is no way to report a problem.** The only support channel in the app is a Discord invite in
the About section. A wearer who hits a bug has nothing to press: no issue link, no report, and
nothing that carries any context with it. What comes back instead is "the glasses stopped working",
with no app version, no iOS version, no device model, and no log — which is roughly the amount of
information needed to close a bug as unreproducible.

**The diagnostics that would answer those questions are already built, and hidden.** The Developer
panel runs six probes against the *real* subsystems — glasses link, camera photo, HUD render, AI
round-trip, TTS, wake word — each with a failure message that names the actual cause ("Not
listening — check mic permission or silent mode"). It sits under Settings → Advanced → Developer,
and **Simple Mode hides Advanced entirely**. Simple Mode exists for handing the device to someone
who just needs it to work; those are precisely the wearers who cannot self-diagnose and most need
both the self-test and a way to send what it found. The good diagnostics and the people who need
them are on opposite sides of a gate.

## The shape

Surface what exists, and make a report out of it — nothing more inventive than that.

**A top-level category, not a page inside Advanced.** "Diagnostics & Support" sits alongside Voice
& Triggers and Look & Feel and stays visible in Simple Mode. The Developer panel keeps its own copy
of the checklist for the power-user flow; the probes themselves are now shared, so a probe added in
one place exists in both. A check that lives in only one surface is a check somebody won't run.

**The report is a deterministic function of a snapshot.** `DiagnosticsSnapshot` is the entire input:
app version and build, system name and version, hardware model, locale, glasses connection (name,
battery, display capability), active model, the debug-log tail, and the self-test outcomes if the
wearer ran them. `DiagnosticsReportBuilder` turns that into markdown plus a prefilled new-issue URL.
No `Bundle`, no `UIDevice`, no clock inside the builder — the live edge gathers the snapshot in the
view, which leaves every rule that matters unit-testable.

**Redaction is a property of the type, not a habit of the caller.** Nothing reaches a report except
through `DiagnosticsRedactor`, which runs three overlapping layers: the literal credential values
configured on this device (`Config.knownSecretValues` — an API key has no recognisable shape once
it's someone else's), then the shared `SecretPatterns` set the outbound egress screen already uses,
then a labelled `key: value` catch-all. Order is load-bearing: the blunt labelled sweep runs last,
because ahead of the shaped patterns it eats `Bearer` out of `Authorization: Bearer …` and leaves
the token in the clear. Tests plant lookalikes of each kind and assert none survives into either the
body or the URL.

**A URL cannot hold a log, so two paths exist.** The prefilled issue URL is capped at 7.5 KB; the
log tail is trimmed from the oldest end until it fits, and the report says how many lines it dropped
and where to get them. Copy and Share carry the complete text. A truncated report beats no report,
and the full one is one tap away.

**Nothing is sent automatically, and the wearer reads it first.** Every path is user-initiated, and
"Report a Problem" opens a review sheet showing the exact text before any of it leaves the device.
The sheet also names what was masked, so masking is something the wearer can see rather than a
promise. Conversations, contacts, location, and saved memories are never in the snapshot — the two
shape tests pin the section list and the device-table rows so a future field can't quietly join them.

## Scope

- `DiagnosticsSnapshot` / `DiagnosticsReport` / `DiagnosticsReportBuilder` / `DiagnosticsRedactor`
  (`Sources/Services/Diagnostics/DiagnosticsReportBuilder.swift`) — pure, injected, deterministic.
- `SubsystemProbes` (`Sources/Services/Diagnostics/SubsystemProbes.swift`) — the six live probes
  lifted out of `DeveloperPanelView` verbatim, plus `summary(of:)` for the report's self-test
  section. `DeveloperPanelView` now calls it; that file's only other change is the one init line.
- `DiagnosticsSupportView` (`Sources/App/Views/DiagnosticsSupportView.swift`) — the self-test,
  Report a Problem (review sheet → prefilled issue, copy, share), and a Discord row.
- `SettingsView` — one category row, outside the Simple Mode gate.
- `Config.knownSecretValues` — the scrub list, for redaction only.

## Out of scope

- **Crash reporting and analytics.** The app deliberately opts out of the glasses SDK's telemetry
  and blocks it at the network layer as a backstop. Adding a reporting SDK here would contradict
  that in the same release, so this plan ships none — a report exists only when a wearer makes one.
- **Email compose.** A mail path needs an address to maintain and a mailbox to answer; the issue
  tracker already is both.
- **A backend endpoint.** Nothing to deploy, nothing to keep up, nothing that receives a report
  without the wearer pressing something.
- **Restructuring the Developer panel.** It keeps its Turn Timeline and debug-event tail; only the
  probe list moved.
- **Log capture changes.** The report reads the existing in-memory ring and the existing persistent
  `Documents/debug-events.log` stays as it is.

## Testing

`DiagnosticsReportBuilderTests` (20), headless and fixture-driven:

- **Context** — version/build, system, hardware model, locale, connected and disconnected glasses,
  the self-test section appearing only when probes ran, an empty log still producing a valid URL.
- **Log tail** — newest-60 windowing, oldest-first order preserved.
- **Redaction** — planted lookalikes of a provider key, a repository token, a cloud API key, a
  bearer header, a labelled `api_key=`, a stream key, and an email address, each asserted absent
  from both body and URL; a shapeless configured secret scrubbed by literal match; short or unset
  configured values *not* used as masks; ordinary log lines untouched; the label kept so the reader
  sees what was masked; idempotence.
- **URL** — correct base and both query parameters, strict percent-encoding (`#`, `&`, `+`,
  newlines), truncation to fit with the oldest lines dropped first, an absurdly small limit still
  yielding a usable URL, and the full body staying untruncated.
- **Shape** — the section list and the device-table rows are exactly the declared ones.

Device-pending: nothing blocking. The self-test's own live behaviour is unchanged from the Developer
panel, and the six probes are the same objects.

## Open questions

- Should a failing self-test offer to start a report on the spot, rather than leaving the wearer to
  find the row below it? The outcomes are already in the snapshot; the prompt is the missing half.
- Does the persistent `debug-events.log` belong in a report as an attachment path, given a URL can't
  carry it and Share could? Deliberately not attempted here.
