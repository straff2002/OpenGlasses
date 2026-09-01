# Plan DM — Privacy-Safe Production Logging

**Status:** 🚧 P0 shipped (2026-09-01) — `PrivacyLog` + `SafeErrorSummary` landed, all named leak
sites emit metadata only, and the P1 scanner runs in report-only mode with a checked-in ledger
([`DM-ledger-baseline.txt`](DM-ledger-baseline.txt)). **P1 batch 1 (authentication/networking)
migrated (2026-09-01): 872 → 794 sites, 127 → 113 files. P1 batch 2 (conversation/model/audio)
migrated (2026-09-01): 794 → 461 sites, 113 → 75 files.** P1 batches 3–5, P2 and P3 outstanding.
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

### Batch 1 — authentication/networking ✅ (2026-09-01)

Fourteen files, 78 sites, all to zero; the ledger is regenerated from the same script.

| Metric | P0 baseline | After batch 1 |
|---|---|---|
| Direct `NSLog`/`print` sites | 872 / 127 files | 794 / 113 files |
| Content/credential-named interpolations | 45 | 31 |
| `localizedDescription` in log calls | 120 | 101 |
| Allowlisted files / sites | 0 / 0 | 0 / 0 |

Migrated: `OpenClawBridge` (25), `OpenClawEventClient` (17), `WebRTCStreamingService` (7),
`MCPClient` (6), `MCPGlassesServer` (6), `Config` secret/gateway migrations (3),
`WebHUDMirrorServer` (3), `WebRTCPeerTransport` (3), `KeychainService` (2), `ModelFetcher` (2),
`MCPTransport` (1), `ExpertStreamTransport` (1), `ExpertBridge` (1), `EscalationCoordinator` (1).
The three OAuth services were already at zero after P0 and were re-swept.

Facade additions: categories `gateway`, `mcp`, `stream`; events `gatewayConnection`/`gatewayHealth`/
`gatewayOperation`/`gatewayNotification`/`gatewayFailed`, `mcpDiscovery`/`mcpToolScreened`/
`mcpEgress`/`mcpFailed`/`mcpServer`, `stream`, `keychainFailed`, `configMigration`, and a
`modelCatalog` network subsystem. Gateway and MCP server identity is a `PrivateIdentifier`;
protocol method names and tool names are public operation class.

What this removed, beyond the raw call count: the gateway health probe logged its endpoint **and
the response body**, the connect path logged the handshake frame (bearer token and signed device
identity, through a redactor that masks two token shapes), `sessions.send` logged the agent's reply
to the wearer, the heartbeat and cron paths logged the text about to be spoken, the viewer-broadcast
and expert-bridge paths logged **room URLs** — bearer capabilities to a live camera — and the MCP
local server logged unauthenticated request paths verbatim. `LogRedaction` now has no production
caller; its four gateway callers were the last, and its doc no longer points at them.

Deliberately deferred, with the batch they belong to: `ClawHubService` and the offline
sync/queue pair (persistence/import — batch 4), `WebSearchTool` and the broadcast-chat clients
(query and message content — batch 2), `HomeAssistantEntityCache` (home — batch 3),
`DeepgramSTTService` (audio — batch 2), `BroadcastService` (media/device — batch 5).

Keychain finding: the two sites logged key *names* and `OSStatus`, never values. The names are now
omitted rather than fingerprinted — they come from a small fixed dictionary of provider names, so a
hash would not anonymise them while still saying which credentials the wearer holds.


### Batch 2 — conversation/model/audio ✅ (2026-09-01)

Thirty-five files, 333 sites, all to zero.

| Metric | After batch 1 | After batch 2 |
|---|---|---|
| Direct `NSLog`/`print` sites | 794 / 113 files | 461 / 75 files |
| Content/credential-named interpolations | 31 | 19 |
| `localizedDescription` in log calls | 101 | 59 |
| Allowlisted files / sites | 0 / 0 | 0 / 0 |

Migrated: `WakeWordService` (46), `LLMService` (35), `TextToSpeechService` (26),
`Audio/RealtimeAudioEngine` (25), `GeminiLive/GeminiLiveSessionManager` (24),
`LocalLLMService` (19), `ConversationStore` (19), `NativeTools/NativeToolRouter` (17),
`TranscriptionService` (14), `AmbientCaptionService` (12),
`OpenAIRealtime/OpenAIRealtimeSessionManager` (10), `BackgroundVoiceService` (10),
`LiveTranslationService` (9), `Audio/AudioSessionCoordinator` (8),
`NativeTools/WebSearchTool` (6), `AudioCapture/StandaloneMicTapService` (6),
`MeetingAssistantService` (5), `AudioRecordingService` (4), `IntentClassifier` (4),
`ConversationEncryptionService` (3), `AudioCapture/CaptureAudioRouter` (3),
`MemoryRewindService` (3), and fifteen one- and two-site files:
`Teleprompter/TeleprompterScriptStore`, `OpenAIRealtime/OpenAIRealtimeService`,
`GeminiLive/GeminiLiveService`, `GeminiLive/GeminiLiveModelCatalog`, `GeminiLive/FrameThrottler`,
`BroadcastChat/TwitchChatClient`, `BroadcastChat/BroadcastChatReadbackService`,
`Audio/AudioSessionActivator`, `ASR/OnDeviceASREngine`,
`Translation/OnDeviceTranslationProvider`, `Translation/GeminiTranslationProvider`,
`AudioCapture/CaptureAudioNormalizer`, `LLM/ToolLoopDriver`,
`Diarization/DeepgramSTTService`, `NativeTools/ToolAuthorizationEventLog`,
`Live/TurnAdmissionPolicy` (a doc comment quoting a deleted `print`).

Beyond the named ledger files, the batch added the ones that are plainly this domain and were
sitting in the same call paths: `NativeToolRouter` and `ToolLoopDriver` (the tool loop named in the
batch's own scope line), `BackgroundVoiceService`, `LiveTranslationService`, `IntentClassifier`,
`MeetingAssistantService`, `MemoryRewindService`, `OnDeviceASREngine`, both translation providers,
`AudioSessionActivator`, `CaptureAudioNormalizer`, `FrameThrottler`, `TurnAdmissionPolicy` and
`ToolAuthorizationEventLog`.

Facade additions: categories `speech`, `audio`, `model`, `conversation`; events
`wakeWord`/`speech`/`tts`, `audio`, `model`/`modelCompaction`/`localModel`, `conversation`,
`toolGate`/`toolDispatch`/`toolRun`/`toolAuthorizationRefused`/`webSearch`, a `broadcastChat`
stream channel, and a widened `realtimeSession` covering the session managers' camera, audio-mode
and tool-pause plumbing. Model *ids* are public catalog tokens; model *configuration names* are
fingerprinted. Audio port *types* are tokens, port *names* are fingerprints. Language tags are
public.

What this removed, beyond the raw call count: the always-on wake-word listener logged the
**recognised transcript** on five separate paths — stop command, wake-phrase barge-in,
voice-activity barge-in, detection, fuzzy match — plus the persona names and the entire
contextual-boost list of configured wake phrases, which is to say it wrote down what the wearer said
whether or not they were addressing the app. `LLMService` logged the model's reasoning trace, the
custom endpoint's `baseURL`, provider error bodies (which quote the prompt back, and on a moderation
refusal quote the exact phrase objected to) and the on-device tool call with its arguments.
`TextToSpeechService` logged the sentence it was about to speak, and the iOS voice by name.
`LiveTranslationService` logged both halves — the utterance and its translation.
`AmbientCaptionService` and `OnDeviceASREngine` logged the transcripts their artifact filters
rejected (failing a quality check does not make a transcript less private). `NativeToolRouter`
logged the confirmation summary, the gateway task description and 200 characters of every tool
result. `ConversationStore` logged thread ids and persona ids in the clear.

`ToolLogContent.redacted` is deleted. It returned the text unchanged in DEBUG and a character count
in Release — the same "a redactor is not authorisation to log content" trap `LogRedaction` was, and
its three callers in `NativeToolRouter` were the ones logging the tool result and the confirmation
copy. A test asserts no batch-2 file references it.

Judgement calls: `PrivacyToken(String(describing: reason))` is used for OS enum cases
(`AVAudioSession.RouteChangeReason`) — a fixed Apple vocabulary, not app data. MLX prompt tensor
shapes are kept, rendered `1x842`, because the text-vs-vision factory shape mismatch is a fatal
Metal crash diagnosed from exactly that number. The client-VAD RMS is dropped: it measures how
loudly the wearer was speaking, and the interrupt firing is the diagnosable fact. No
`ENABLE_CONTENT_LOGGING` sites were added — every audio-plumbing site that looked like it needed
one turned out to be describable as a route, a format, a count or a lease owner.

Deliberately deferred, with the batch they belong to: `SemanticMemoryStore`, `Memory/*`,
`AgentDocumentStore`, `RAG/DocumentStore` and the offline sync/queue pair (persistence — batch 4);
`Accessibility/*`, `FaceRecognitionService`, `LookCloselyTool`, `DocumentScanTool` (vision — batch
3); `AgentScheduler`, `BroadcastService`, `VideoRecordingService`, `MetaCameraBackend`,
`OpenGlassesApp` (device/lifecycle — batch 5).

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
