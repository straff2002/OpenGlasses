# Plan DM — Privacy-Safe Production Logging

**Status:** 🚧 P0 shipped (2026-09-01) — `PrivacyLog` + `SafeErrorSummary` landed, all named leak
sites emit metadata only, and the P1 scanner runs in report-only mode with a checked-in ledger
baseline ([`DM-ledger-baseline.txt`](DM-ledger-baseline.txt)). P1–P3 outstanding.
**Origin:** 2026-08-26 adversarial review finding 4 (High).
**Priority:** P0 for known content leaks; complete the source-wide migration before public release.

The goal is not “redact a few known token shapes.” The goal is a logging API whose default type
system makes user content and secrets impossible to persist accidentally, plus a build-time guard
that prevents raw logging from returning.

---

## Problem and verified path

The audited source tree contains 619 `NSLog` calls across 107 files, plus 264 `print()` calls across
26 files (73 in `OpenGlassesApp.swift` alone). Verified examples log full tool arguments and results
(`ToolCallRouter`), live user/assistant transcripts (`OpenAIRealtimeService`, `GeminiLiveService`),
QR payloads and fetched URLs (`QRContextTool`), Home Assistant entity names/replies/response bodies
(`HomeAssistantTool`), and incoming callback URLs with query params (`OpenGlassesApp` `onOpenURL`).
`LogRedaction` masks only two shapes — `token=` in query strings and `"token":` in JSON — and is
called from just four sites, all in the OpenClaw gateway path; none of the verified leak sites call
it. Most sensitive content is not a token, and prefix truncation limits volume, not sensitivity.
There is no `os.Logger`/`OSLog` facade anywhere today, so P0's `PrivacyLog` is a greenfield
introduction, not a migration of an existing wrapper.

First-priority seams:

- `OpenGlasses/Sources/Services/ToolCallRouter.swift`
- `OpenGlasses/Sources/Services/OpenAIRealtimeService.swift`
- `OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift`
- `OpenGlasses/Sources/Services/NativeTools/QRContextTool.swift`
- `OpenGlasses/Sources/Services/NativeTools/HomeAssistantTool.swift`
- `OpenGlasses/Sources/App/OpenGlassesApp.swift` callback handling
- `OpenGlasses/Sources/Utils/LogRedaction.swift`
- all `NSLog`, `print`, and raw `Logger` interpolation under `OpenGlasses/Sources`

## Data classification and non-negotiable rules

| Class | Examples | Production log treatment |
|---|---|---|
| Public operation | subsystem, static event name, success flag, bounded count | May persist |
| Private identifier | thread/tool/server/device/call id, host | Hash or OS-private mask only |
| User content | transcripts, prompts, tool args/results, OCR/QR text, URLs with path/query | Never persist |
| Secret | tokens, keys, cookies, auth headers, callback codes | Never construct a log field |
| Regulated/sensitive | medical data, faces, location, home commands/entities | Never persist; counts only |

Errors inherit the highest classification of their underlying request/response. `localizedDescription`
is not assumed safe because networking and decoding errors can embed URLs, server bodies, or values.

---

## P0 — Stop known leaks and add a safe facade ✅ (2026-09-01)

1. Introduce `PrivacyLog`, backed by `os.Logger`, with fixed categories and typed methods. Callers pass
   event names, enums, counts, durations, and explicitly wrapped private identifiers—not arbitrary
   format strings or dictionaries.
2. Provide no general `log(String)` production API. A debug-content method exists only inside
   `#if DEBUG && ENABLE_CONTENT_LOGGING`, defaults off, and adds a conspicuous prefix.
3. Replace the verified leak sites immediately:
   - tool calls: name, duration, outcome class; no arguments/result;
   - realtime: utterance counts/character counts and state transitions; no text;
   - QR: payload type and byte count; no value/URL;
   - Home Assistant: operation class and success; no command, entity, response;
   - callbacks: route kind and validation verdict; no URL/query/error payload.
4. Add `SafeErrorSummary` mapping known error enums/status codes to bounded public categories. Unknown
   errors become type name/domain+code, not `localizedDescription`.
5. Keep `LogRedaction` only as defense-in-depth for explicitly user-exported diagnostics. Rename or
   document it so developers do not treat it as authorization to log content.

**Tests.** Pure event encoders produce no supplied sentinel secret/transcript/URL; error summaries do
not echo malicious descriptions; source scans prove the named files contain no content-bearing log;
Release compilation excludes debug-content methods.

### What shipped

`OpenGlasses/Sources/Utils/PrivacyLog.swift` and `SafeErrorSummary.swift`. Categories are
`tools`/`realtime`/`capture`/`home`/`lifecycle`/`auth`/`network`; 26 typed methods, no `log(String)`.
A field value can only be a count, a duration, a flag, a `PrivacyToken` (bounded vocabulary word,
dropped rather than truncated if it does not fit the shape), a `PrivateIdentifier` (SHA-256/8
fingerprint), or a `SafeErrorSummary`. `emit` returns the event it logged, so `PrivacyEventEncoder`
is exercised through the real methods in tests rather than a parallel implementation.

Migrated sites: `ToolCallRouter` (name + duration + outcome class), `OpenAIRealtimeService` and
`GeminiLiveService` (state transitions, utterance character counts, frame kilobytes, latency —
no text), `QRContextTool` (payload class + byte count; fetched host as a fingerprint),
`HomeAssistantTool` (operation class + success; no command, entity, or body), `OpenGlassesApp`
callback handling (route kind + verdict; no URL), plus the `ClaudeOAuthService` /
`ChatGPTOAuthService` / `GoogleOAuthService` refresh failures that were passing
`localizedDescription` (Google was not in the audit list but is the identical statement).

`LogRedaction` kept and re-documented as export-diagnostics defence-in-depth only, naming its four
remaining gateway callers as P1 migration targets.

**Stated limit.** `PrivacyToken` is a shape filter, not a secret detector: a short,
identifier-shaped value survives it. A test pins that behaviour rather than implying otherwise;
the compensating control is that no call site builds a token from a credential, and the scanner
flags the ones that could.

## P1 — Inventory and migrate the entire source tree 🔴

**Report-only scanner shipped (2026-09-01):** `Scripts/check-privacy-logging.sh` (+
`Scripts/privacy-logging-allowlist.txt`, empty at P0) counts direct `NSLog`/`print` sites, flags
log calls interpolating content/credential-named identifiers, flags `localizedDescription` in log
calls, and prints a `PRIVACY_LOG_*` summary for CI to trend. It always exits 0 until P2.

Baseline at P0 completion (`docs/plans/DM-ledger-baseline.txt`, `--ledger`):

| Metric | Count |
|---|---|
| Direct `NSLog`/`print` sites | 872 across 127 files |
| Log calls interpolating content/credential-named identifiers | 45 |
| Log calls reading `localizedDescription` | 120 |
| Allowlisted files / sites | 0 / 0 |

The largest single item is `OpenGlassesApp.swift` at 136 sites (only its callback handling was in
P0 scope), then `WakeWordService` and `MetaCameraBackend` at 46 each.


Generate and check in a classification ledger with one row per logging site/category, then migrate in
bounded PRs:

1. **Authentication/networking:** request URLs, OAuth, gateway, MCP, headers, WebSockets.
2. **Conversation/model/audio:** prompts, reasoning, histories, transcripts, TTS/STT, tool loops.
3. **Vision/home/medical/location:** OCR, QR, frames, faces, entities, clinical operations, geofences.
4. **Persistence/import/export:** filenames, salvage errors, document/memory content, share flows.
5. **Operational UI/device:** lifecycle, BLE/session state, counts and timing that are genuinely public.

For each site choose delete, convert to an approved event, or debug-only. The target is zero direct
`NSLog`/`print` calls under production Sources. If a small platform shim truly requires `NSLog`, put it
in one allowlisted adapter that accepts only preclassified static fields.

Do not mechanically hash low-entropy private data such as room names or medical conditions; hashing
does not anonymize a small dictionary. Omit it.

**Tests/verification.** A script fails on direct logging APIs, string interpolation of argument/result/
transcript/url/token/key/cookie fields, and use of `localizedDescription` in log calls. It also emits a
reviewable allowlist diff so developers cannot bypass it with a new wrapper.

## P2 — CI enforcement and privacy regression fixtures 🟠

1. Add a required CI job (`scripts/check-privacy-logging.sh` or a SwiftSyntax rule) over Sources. Prefer
   syntax analysis for call/member identity; use `rg` as an additional blunt guard, not the only test.
2. Mark `PrivacyLog` field wrappers with distinct types: `PublicMetric`, `PrivateIdentifier`, and
   internal `NeverLog`. Sensitive domain models should not conform to logging protocols or
   `CustomStringConvertible` merely for diagnostics.
3. Build adversarial fixtures containing recognizable canary tokens in prompts, QR values, callback
   URLs, medical fields, tool arguments/results, and server errors. Drive each subsystem and assert the
   structured event sink never receives a canary.
4. Add a Release-build symbol/string check proving content-logging labels and format strings are absent.
5. Require a privacy-led review for any new event carrying a value rather than a count/enum.

## P3 — User-controlled diagnostic export 🟡

1. Keep normal production logging minimal. For bug reports, create a separate in-memory diagnostic
   collector with a short ring buffer of approved structured events.
2. Export only after an explicit preview/consent step. Show categories and timestamps, run redaction as
   a final safety layer, and never include conversation content, tokens, QR values, medical content, or
   raw URLs.
3. Reuse the protected export-session pattern from Plan DC/[[DL-medical-secret-and-export-lifecycle]];
   delete the bundle on share completion/cancel and scavenge after crashes.
4. Document retention and OS log limitations honestly. Do not claim that `.private` fields make it safe
   to submit arbitrary content to the logging system.

---

## Rollout, rollback, and exit criteria

P0 ships first without waiting for the full inventory. P1 can land subsystem by subsystem, but the CI
rule from P2 first runs in report-only mode and becomes required once the ledger reaches zero raw sites.
A rollback may reduce or disable logging; it must not restore content-bearing statements.

Complete when:

- all verified leak sites emit metadata only;
- production Sources contain no unapproved `NSLog`, `print`, or free-form logging facade;
- canary fixtures cover tool, realtime, QR, callback, home, medical, and network errors;
- a Release build contains no debug content-logging implementation;
- diagnostics export is explicit, previewable, protected, and short-lived; and
- privacy CI and the full unit suite are green.
