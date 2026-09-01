# Plan DM — Privacy-Safe Production Logging

**Status:** 🚧 P0 ✅, **P1 ✅ — the ledger reads zero**, P2.1/P2.2/P2.4 ✅ (all 2026-09-01).
`PrivacyLog` + `SafeErrorSummary` landed at P0; five P1 batches took the source tree from
**872 direct `NSLog`/`print` sites across 127 files to 0 across 0 files**
(872 → 794 → 461 → 319 → 250 → 0), and the scanner is now a **blocking gate** rather than a
report. The ledger ([`DM-ledger-baseline.txt`](DM-ledger-baseline.txt)) stays checked in at zero
as the historical record. Outstanding: **P2.3** (adversarial canary fixtures driven through each
subsystem), **P2.5** (privacy-led review rule for any new value-bearing event), and **P3**
(consented diagnostics export).
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

`OpenGlasses/Sources/Utils/PrivacyLog.swift` and `SafeErrorSummary.swift`. Categories at P0 were
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

## P1 — Inventory and migrate the entire source tree ✅ (2026-09-01)

**Scanner shipped report-only at P0 (2026-09-01), flipped to blocking at P2 (2026-09-01):**
`Scripts/check-privacy-logging.sh` (+ `Scripts/privacy-logging-allowlist.txt`, empty throughout)
counts direct `NSLog`/`print` sites, flags log calls interpolating content/credential-named
identifiers, flags `localizedDescription` in log calls, and prints a `PRIVACY_LOG_*` summary for
CI to trend. It exited 0 for the whole of P1 so the number could be a ledger rather than a
verdict; it now exits nonzero on any finding. See P2 below.

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

### Batch 3 — vision/home/medical/location ✅ (2026-09-01)

Thirty files, 142 sites, all to zero. The strictest batch: every file in it holds a value the
classification table calls regulated at the moment it logs.

| Metric | After batch 2 | After batch 3 |
|---|---|---|
| Direct `NSLog`/`print` sites | 461 / 75 files | 319 / 45 files |
| Content/credential-named interpolations | 19 | 16 |
| `localizedDescription` in log calls | 59 | 37 |
| Allowlisted files / sites | 0 / 0 | 0 / 0 |

Migrated: `Camera/MetaCameraBackend` (46), `FaceRecognitionService` (9), `NativeTools/HomeKitTool`
(8), `HIPAAComplianceService` (7), `Accessibility/SceneNarrationService` (7),
`HomeAssistantEntityCache` (6, deferred here from batch 1), `ProactiveAlertService` (6),
`NativeTools/DocumentScanTool` (5), `GlassesPhotoAlbum` (5), `LocationService` (5),
`NativeTools/LookCloselyTool` (4), `Medical/FHIRConfigurationStore` (4),
`PhoneVideoSource` (3), and seventeen one- and two-site files: `CameraService`,
`PhoneCameraSource`, `VideoDecoder`, `App/Views/PhoneCameraView`, `PrivacyFilterService`,
`NativeTools/CapturePhotoTool`, `SignLanguage/FingerspellingSessionService`,
`Accessibility/OCRService`, `Accessibility/NavigationAssistService`,
`Accessibility/AssistiveModeService`, `LiveCoachService`, `MedicalExportService`,
`SafetyAssessment/SafetyAssessmentStore`, `HealthSafety/HealthSafetyAdvisor`,
`NativeTools/FitnessCoachingTool`, `NativeTools/GeofenceTool`, `Navigation/WalkingRouteService`.

Facade additions: categories `vision`, `medical`, `location`; events `camera`/`photoLibrary`
(capture), `vision`/`face`, `homeBridge`, `medical`, `location`, and `proactiveAlert` (lifecycle).
The Home Assistant fuzzy matcher reuses the existing `homeEntityResolved`, which was built in P0 to
drop exactly the entity it was logging. `PrivacyLog.FaceConfidence` is new and is the one place a
measurement is deliberately coarsened rather than dropped: a raw similarity is a number about one
person's face against one enrolment, so it is banded to low/medium/high at the boundary.

What this removed, beyond the raw call count: `FaceRecognitionService` logged **the name it had
just recognised**, and every name in an ambiguous tie — the most identifying string the app ever
holds, written to a sink that outlives the announcement it was made for. `HomeAssistantEntityCache`
logged the spoken query, the matched entity id, the score *and* the friendly name on every fuzzy
match, which is a running record of the rooms and devices in someone's house and what they asked
them to do. `LocationService` logged the reverse-geocoded place on every position update, so a
device log was a movement history. `ProactiveAlertService` logged the full text of every alert
before speaking it (calendar titles, who a meeting is with) and the event title behind any
auto-created playbook. `HIPAAComplianceService` mirrored **its own audit trail** — action and
detail — into the device log, where none of the audit store's file protection, retention or
purging applies; and its file-protection path logged the protected file's name, which for this app
is a date and a session. `HealthSafetyAdvisor` logged the withheld citation claims in full — text
the retrieve-or-silence gate had just decided was too unverifiable to say out loud.
`HomeKitTool` logged the accessory name on a failed read-before-write.

Judgement calls. `MetaCameraBackend`'s 46 sites are DAT plumbing and nearly all survive as typed
events rather than being deleted: stream and capability states, resolutions, frame rates, retry
attempts and stall-recovery tiers are public operation class, and this is the hardest subsystem in
the app to diagnose without a device in hand. Only the values were dropped — the bound device id
became a fingerprint (batch-2 precedent), and the two user-facing strings (`CameraErrorPolicy`'s
message and the compatibility notice) became a `SafeErrorSummary` and an event name, because both
are sentences composed for the wearer. Frame dimensions and rates are kept; nothing describes what
a frame showed. Scene narration's halt/silence reasons are `NarrationSessionPolicy.Interruption`
raw values — a fixed vocabulary — and are kept, while the camera-unavailable *reason* and the
power-refusal copy are prose and are not. `GlassesPhotoAlbum.report` now feeds only the on-screen
diagnostics panel, which is a different sink with a different audience; the device log gets the
typed event, and `GlassesPhotoAlbumPolicy.statusToken` sits beside `describe` so the log
vocabulary and the human copy cannot drift. HIPAA audit *actions* (`AUTO_PURGE`, `FHIR_EXPORT`)
survive as tokens because they are a fixed operation vocabulary; the details do not. Entity, room,
accessory and person names are omitted rather than fingerprinted, per the plan's low-entropy rule.
No `ENABLE_CONTENT_LOGGING` sites were added; the count across the three batches is still zero.

Deliberately deferred, with the batch they belong to: `Reading/ReadingSessionStore`,
`Study/StudyStore`, `Persistence/JSONStore`, `RAG/DocumentStore`, `AgentDocumentStore`,
`SemanticMemoryStore`, `Memory/*`, `NativeTools/OperationJournal` and the offline sync/queue pair
(persistence — batch 4); `CarPlaySceneDelegate`, `Models/HomeGridCatalog`,
`Triggers/MediaTriggerService`, `BroadcastService`, `VideoRecordingService`,
`GlassesConnectionService`, `WearablesBootstrap`, `GlassesDisplayService` and `OpenGlassesApp`
(operational UI/device — batch 5). `CarPlaySceneDelegate` is the one worth naming: its nine sites
are persona names, a thread id, a playbook name and **a tool result printed verbatim** — a real
content leak, but a conversation-path one, so it goes with the file rather than being pulled
forward. `HomeGridCatalog` is the app's home *screen* tile arrangement, not home automation.

### Batch 4 — persistence/import/export ✅ (2026-09-01)

Twenty-one files, 69 sites, all to zero.

| Metric | After batch 3 | After batch 4 |
|---|---|---|
| Direct `NSLog`/`print` sites | 319 / 45 files | 250 / 24 files |
| Content/credential-named interpolations | 16 | 13 |
| `localizedDescription` in log calls | 37 | 22 |
| Allowlisted files / sites | 0 / 0 | 0 / 0 |

Migrated: `SemanticMemoryStore` (17), `Persistence/JSONStore` (7), `AgentDocumentStore` (6),
`ClawHubService` (6, deferred here from batch 1), `RAG/DocumentStore` (5),
`Reading/ReadingSessionStore` (4), `Study/StudyStore` (3), `SkillPacks/SkillPackStore` (3), and
thirteen one- and two-site files: `NativeTools/OperationJournal`, `Offline/SyncEngine`,
`Offline/OfflineQueue`, `RecordingFiler`, `RecordedSessionStore`, `Memory/ConversationIndex`,
`Memory/ConversationRecallCoordinator`, `Brain/BrainStore`, `Skills/EvolvedSkillStore`,
`Usage/UsageStore`, `PlaybookStore`, `AgentDataExporter`, `Siri/SpotlightIndexService`.

Facade additions: categories `store` and `transfer`; events `store` (a `StoreName` role, a
`StoreEvent`, an optional slot/scope, counts) and `transfer` (a `TransferChannel`, a
`TransferEvent`, a fingerprinted item, a version, an op kind, a signed flag, counts).
`SafeErrorSummary` gains `.storage` and `sqlite(code:extended:)`, and its `DecodingError` branch
now carries the coding-path **depth**.

What this removed, beyond the raw call count: `SemanticMemoryStore` wrote **the memory key and its
value** to the device log on every single `remember` — the wearer's remembered facts, in the clear,
in the one sink that outlives everything else — plus each agent diary line (80 characters of it),
the key of every memory evicted for going over budget, and the persona id whose memories were
cleared. `AgentDocumentStore` logged the whole fact appended to the agent's memory document, which
is the same content by another route. `RAG/DocumentStore` logged the **title of every ingested
document** — of a scanned letter, a report, a prescription. `JSONStore` named the backup file it
had just written for a corrupt blob and passed the read failure's `localizedDescription` through;
it is the salvage path every JSON-backed store funnels into, so a decode error quoted there quotes
the records of all of them. `RecordedSessionStore` logged a recording's full sandbox path,
`RecordingFiler` the source and destination filenames, `AgentDataExporter` the export archive's
name, and six SQLite stores their database paths.

Judgement calls. **Filenames are user content when user-derived**, so no method in either new
category takes a path or a name: a document title becomes a filename, and an export archive's
entries are conversation titles with an extension on them. What survives instead is the store's
*role*, which is a fixed vocabulary of seventeen slots defined in `PrivacyLog` itself.
`JSONStore`'s `name` argument is the one place a role arrives as a `String`; every call site passes
a literal from a fixed set, and `testJSONStoreSlotNamesAreLiterals` pins that — a store named from
user input would be identifier-shaped and would survive `PrivacyToken`'s shape filter.

**Salvage errors** report which slot, how many records were salvaged and how many were in the file,
and never the decode error's payload: a `DecodingError`'s description quotes the JSON it choked on.
`SafeErrorSummary` reduces it to a case name plus the coding path's **depth** — never its keys,
because in a `[String: T]` blob (several of these stores are exactly that) the keys are the wearer's
own strings, while the depth still distinguishes "the whole file is not JSON" from "one field of
one record is the wrong type". **SQLite** faults report `sqlite3_errcode` and
`sqlite3_extended_errcode`, a fixed numeric vocabulary, and never `sqlite3_errmsg`, which on a
prepare failure quotes the offending statement — and this app's stores are where memory keys and
document chunks live. A test asserts no batch-4 file references `sqlite3_errmsg` at all.

A memory's **namespace** is a persona id, so the pool (`global`/`persona`) is logged and the
persona is not — the batch-2 precedent for persona ids over the general "namespaces as
fingerprints" habit, on the plan's own low-entropy rule. **Skill identity** goes the strict way: a
hub slug and a pack id are community-authored and describe what the wearer went looking for, so
they are fingerprinted, while a pack's *version* stays a readable token and its signed/unsigned
verdict stays a flag. Queue and sync events keep the op kind (`OfflineQueue.OpKind`, a fixed enum),
the retry tier and a fingerprinted op id; the sink's failure `reason` is prose composed by whatever
refused the operation, so it has no parameter. No `ENABLE_CONTENT_LOGGING` sites were added; the
count across four batches is still zero.

Deliberately deferred to batch 5, with reasons. `AgentNotificationQueue` (7) is a persisted queue,
but it is the delivery half of `AgentScheduler` (13, already deferred) and belongs with it.
`ShortcutCallbackManager` (4) is worth naming: it prints **200 characters of the shortcut's output
verbatim**, which becomes tool output the model reads — a real content leak, but a
callback/lifecycle one, so it goes with the deep-link tier the way batch 3 left `CarPlaySceneDelegate`
where it was. `App/Views/PersonaPickerSheet` (4) is UI (persona names) but carries the app's only
**Field Assist vault id** log line, and a vault id names a customer — flagged here so batch 5 does
not treat that file as four cosmetic persona prints. The four remaining tool-path strays
(`YieldToHumanTool`, `ShazamTool`, `PlaybookTool`, `AgentHarness/AgentSessionService`, one site
each) are batch-2 domain leftovers; `YieldToHumanTool` and `PlaybookTool` log a model-authored
reason string. Everything else on the ledger is now operational UI/device.

### Batch 5 — operational UI/device ✅ (2026-09-01) — **the ledger reaches zero**

Twenty-four files, 250 sites, all to zero. Nothing was allowlisted.

| Metric | After batch 4 | After batch 5 |
|---|---|---|
| Direct `NSLog`/`print` sites | 250 / 24 files | **0 / 0 files** |
| Content/credential-named interpolations | 13 | **0** |
| `localizedDescription` in log calls | 22 | **0** |
| Allowlisted files / sites | 0 / 0 | **0 / 0** |

Migrated: `App/OpenGlassesApp` (136), `BroadcastService` (17), `VideoRecordingService` (15),
`AgentScheduler` (13), `WatchConnectivityManager` (10), `App/CarPlaySceneDelegate` (9),
`LiveActivityManager` (8), `StoreKitService` (7), `AgentNotificationQueue` (7),
`ShortcutCallbackManager` (4), `GlassesConnectionService` (4), `App/Views/PersonaPickerSheet` (4),
`Triggers/MediaTriggerService` (3), `WearablesBootstrap` (2), `Models/HomeGridCatalog` (2), and
nine one-site files: `NativeTools/YieldToHumanTool`, `NativeTools/PlaybookTool`,
`NativeTools/ShazamTool`, `AgentHarness/AgentSessionService`, `GlassesDisplayService`,
`Device/MetaTelemetryBlock`, `App/Views/OnboardingView`, `App/Views/BottomControlBar`,
`App/Views/AgenticFeaturesView`.

Facade additions: categories `device`, `agent`, `commerce`; events `device` (a `DeviceSurface`, a
`DeviceEvent`, a state, a classified command, a fingerprinted activity id, counts, minutes),
`agent` (a channel, an event, a model, a priority band, a fixed reason, counts), `purchase`,
`recording` (in `capture`), and `app` (in `lifecycle`). `StreamChannel` gains `rtmpBroadcast` and
`stream()` gains the encoder's geometry, frame rate, bitrate, measured bitrate and queue depth.
`TransferChannel` gains `backgroundDownload`; `StoreName` gains `homeGrid`; `CameraEvent` gains
`frameRejected`/`framePinned`/`framePinReleased`; `GatewayNotificationKind` gains `triage`.

What this removed, beyond the raw call count. `OpenGlassesApp.swift` printed **the SDK's
Info.plist credentials on every launch** — the client token's presence, the team id, the Meta app
id, the bundle id and the universal-link scheme. A client token is a secret and the rest name the
developer account and the app's own inbound callback door; none of them was ever the diagnostic,
which is `MWDATConfigCheck`'s verdict, and that is what survives. The same file printed the
wearer's **transcription** on receipt, the assistant's **answer** on three paths, a **direct tool
call's result**, the utterances the turn-admission policy held or rejected, the photo prompt, the
saved photo's filename, the connected **device ids**, and — on the OpenClaw triage path — the
inbound notification, the model's clarification question, its fix instruction, and both replies at
200 characters each. `BroadcastService` logged the RTMP destination **and the first eight
characters of the stream key**: a stream key is a bearer credential that lets whoever holds it
publish as the wearer to the wearer's own channel until it is rotated, and it was also embedded in
the stall-policy sentence the same file logged. `ShortcutCallbackManager` printed 200 characters
of a shortcut's output verbatim — output that then becomes tool text the model reads.
`PersonaPickerSheet` printed the Field Assist **vault id**, the one identifier in this app that
names someone other than the wearer. `CarPlaySceneDelegate` printed a persona name, a thread id, a
playbook name and a tool result. `AgentScheduler` printed each scheduled task's name (the wearer's
own instruction to their agent) and 100 characters of what it found; `AgentNotificationQueue`
printed the queue source and the persona it was waiting on. `VideoRecordingService` printed the
recording's filename, its transcript sidecar's name and the transcript path.
`WearablesBootstrap`/`OnboardingView` passed the SDK failure's `localizedDescription` through, once
directly and once laundered through a `statusDescription` that embeds it.

Judgement calls. **Most of the 136 were deleted, not converted** — progress narration ("App became
active", "Auto-starting wake word listener…", "Wake word restarted") tells a reader nothing a state
transition does not. What was kept is the handful of facts that make "why did it not listen / why
did it pick that model / why did nothing happen" answerable: the listening master switch and each
*reason* the wake-word listener declined to restart, the routing tier and the model id it chose,
the glasses link's state machine, and the auto-sleep timer. **A peer-supplied command name is
classified, not quoted**: `WatchConnectivityManager.commandToken` checks the incoming string
against the watch protocol's fixed vocabulary and returns `nil` otherwise, the same treatment the
local MCP server gives an unknown request path — a `PrivacyToken` would have kept an
identifier-shaped string from the paired device. **A StoreKit product id stays a readable token**:
it is this app's own published catalogue, and which product failed to unlock is the entire content
of a purchase bug report; nothing else from a transaction (receipt, transaction id, account, price)
appears. A **Live Activity id** is system-generated and high-entropy, so it is fingerprinted, while
a **persona name** is omitted on the batch-2 precedent. `HomeGridCatalog`'s dropped tile ids come
out of a stored blob rather than this build's catalogue, so they are decoded data and only the
count survives. No `ENABLE_CONTENT_LOGGING` sites were added; the count across five batches is
still **zero**.

### The migration, end to end

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

## P2 — CI enforcement and privacy regression fixtures 🚧

1. **✅ (2026-09-01)** Add a required CI job (`Scripts/check-privacy-logging.sh` or a SwiftSyntax rule)
   over Sources. Prefer syntax analysis for call/member identity; use `rg` as an additional blunt
   guard, not the only test.
2. **✅ (2026-09-01)** Mark `PrivacyLog` field wrappers with distinct types: `PublicMetric`,
   `PrivateIdentifier`, and internal `NeverLog`. Sensitive domain models should not conform to logging
   protocols or `CustomStringConvertible` merely for diagnostics.
3. 🟠 Build adversarial fixtures containing recognizable canary tokens in prompts, QR values, callback
   URLs, medical fields, tool arguments/results, and server errors. Drive each subsystem and assert the
   structured event sink never receives a canary.
4. **✅ (2026-09-01), with a stated gap.** Add a Release-build symbol/string check proving
   content-logging labels and format strings are absent.
5. 🟠 Require a privacy-led review for any new event carrying a value rather than a count/enum.

### What shipped at P2

**P2.1 — the gate is blocking.** `Scripts/check-privacy-logging.sh` now defaults to a gate: it exits
nonzero on any direct `NSLog`/`print` site, any log call interpolating a content- or
credential-named identifier, any log call reading `localizedDescription`, or any allowlist entry
without a reason. `--report` keeps the report-only output for trending and `--ledger` keeps the
per-file table; an unknown flag exits 2 rather than silently passing. The allowlist format gained a
required `# reason` per line — an unexplained exemption is the one thing the allowlist exists to
prevent — and the script filters allowlisted files out of all three checks rather than only the
headline count.

The gate was verified by probe rather than by inspection: a temporary source file containing
`NSLog("probe %@ %@", url, error.localizedDescription)` made all three checks fail (exit 1);
allowlisting it without a reason still failed (exit 1, on the reason rule); allowlisting it with a
reason passed (exit 0) while still reporting it as an exempt site. The probe was then deleted.

**P2.2 — the unit suite carries the same gate.** `PrivacyLogTests` gains a tree-wide scan
(`testNoProductionSourceLogsDirectly`, `testNoLogCallCarriesContentOrLocalizedDescription`,
`testEveryAllowlistEntryCarriesAReason`) that walks every `.swift` under `OpenGlasses/Sources` and
reads the same allowlist file, so a new file that logs directly fails on the day it is written —
no list to update, no CI configuration change, and the batch lists become a historical record
rather than the mechanism.

**Stated limit, deliberately.** The test re-implements the script's checks in-process rather than
shelling out to it: `Foundation.Process` is unavailable on iOS and the suite runs in the simulator,
so "a unit test invokes the script" is not literally possible here. The two halves are kept honest
by `testTheGateScriptIsBlockingByDefault`, which pins the script's default mode, its failure exit
and the continued existence of `--report`, and would fail if the script quietly reverted to
report-only while CI stayed green. `testTheCheckedInLedgerReadsZero` pins the ledger's end state.

**P2.2's second half — typed field wrappers.** This was already true at P0 and is now pinned:
`PrivacyEvent.Value` has exactly seven cases and **no `case text(String)`**, so `PublicMetric`
(count/milliseconds/seconds/flag) and `PrivateIdentifier` are the only shapes a value can take, and
"`NeverLog`" is expressed as the absence of a parameter rather than as a marker type — a value that
must never be logged has nowhere to arrive. `PrivacyToken.caseName` refuses to describe a
`CustomStringConvertible` enum precisely so that a type conforming for diagnostics cannot leak
through it.

**P2.4 — the debug hatch cannot reach a Release build.**
`testContentLoggingHatchIsConfinedToItsCompilationRegion` asserts that the `debugContent` method
and its `⚠️ CONTENT-LOG` label appear only inside `#if DEBUG && ENABLE_CONTENT_LOGGING`, and that no
file outside `PrivacyLog.swift` references `debugContent` at all. With the existing
`testContentLoggingIsEnabledInNoBuildConfiguration` (the flag is defined in none of the four
checked-in XcodeGen specs), that is a structural proof: the compiler cannot emit a string it never
parses. **The gap, named:** this reasons about source, not about a linked binary. A
`strings`/`nm` check over a Release archive would be the stronger statement and needs a Release
build the unit suite does not have. P2.4 is recorded as shipped in this form, not as the binary
check the line originally described.

**Still open.** P2.3 (canary fixtures driven end-to-end through each subsystem, as opposed to
through the facade — the current sentinel tests prove the *encoder* never emits supplied content,
not that a live QR scan cannot reach it by another route) and P2.5 (the review rule, which is
process rather than code).

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

That sequencing held: the scanner exited 0 through all five P1 batches, and the gate was flipped in
the same change that took the ledger to zero — so the gate has never been red on `main`, and
nothing had to be allowlisted to make it green.

Complete when:

- ✅ all verified leak sites emit metadata only;
- ✅ production Sources contain no unapproved `NSLog`, `print`, or free-form logging facade
  (0 sites / 0 files, 0 allowlisted, enforced by a blocking script and by the unit suite);
- 🟠 canary fixtures cover tool, realtime, QR, callback, home, medical, and network errors
  (facade-level sentinels ship; end-to-end subsystem fixtures are P2.3);
- ✅ a Release build contains no debug content-logging implementation (structurally proven; a
  binary `strings` check remains);
- 🟠 diagnostics export is explicit, previewable, protected, and short-lived (P3);
- ✅ privacy CI and the full unit suite are green.
