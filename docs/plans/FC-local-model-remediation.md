# Plan FC — Local Model Remediation

**Status: 📝 Drafted 2026-09-13 — no fixes implemented under this plan.**

Fix a confirmed model-size discrepancy and close local-output failure paths surfaced by a
local-model review. Audit context diagnostics and loading feedback without adding providers,
databases, remote telemetry or a new inference runtime.

## Evidence and scope

| Finding | Evidence | Confidence |
|---|---|---|
| SmolVLM2 2.2B download size is understated | `LocalModelCatalog.swift` lists `mlx-community/SmolVLM2-2.2B-Instruct-mlx` as 1.5 GB. Hugging Face revision `844516024a1c4400d34489b89ee067d794e432ed` reports `model.safetensors` as 4,493,651,795 bytes and all listed files totalling 4,498,568,233 bytes | Confirmed metadata discrepancy; total selected download may differ from repository total |
| Incorrect size can affect progress | `LocalLLMService.expectedDownloadBytes` parses the catalog's display-size string; its polling progress caps at 99% | Confirmed implementation coupling; trace other admission consumers before claiming their behaviour |
| Local malformed output can survive cleanup | `LLMService.cleanedNonEmptyLocalAnswer` removes complete tool tags and speaker prefixes. The no-tool path accepts nonempty remaining text; streaming generation forwards previews before final parsing | Confirmed cleanup gap; exact spoken-output exposure and recurring model behaviour require regression fixtures/device reproduction |
| Excessive-disk-write terminations have been reported for this model on device and are not reproduced here | — | Unreproduced; not evidence of cause |
| Per-turn memory-context diagnostics (availability, record counts, rendered size, truncation) would explain missing recall | — | Candidate improvement; audit our existing coverage first |

Model artifact: [SmolVLM2 2.2B revision 8445160](https://huggingface.co/mlx-community/SmolVLM2-2.2B-Instruct-mlx/tree/844516024a1c4400d34489b89ee067d794e432ed).
Implement independently. A keyword filter that rejects valid English is not an acceptable fix.

## P0 / PR1 — Correct and verify model metadata

1. Recheck the selected SmolVLM2 revision, actual downloaded file set and configuration. Correct the
   size label immediately from verified evidence; do not substitute a rounded size as a RAM estimate.
2. Audit all bundled MLX/GGUF catalog entries for artifact revision, selected file sizes,
   quantization evidence and runtime compatibility. Record unknowns explicitly. Reuse DZ's existing
   catalog/manifest structures, adding fields only where absent.
3. Separate numeric expected download bytes from display formatting. Trace every use of the old
   estimate: download progress, free-space checks, model selection and memory admission. Preserve
   a fallback for unknown/custom installations without representing guessed sizes as exact.
4. Separate weight/download size, peak runtime memory and device qualification. Inspect existing
   `MemoryHeadroom` and model-budget guards; correct demonstrated gaps without replacing them.
5. Audit the claim that models are tested on iPhone and model-specific recommendation copy. Record
   qualified hardware/context/image settings; remove unsupported assurances where evidence is missing.
6. Keep installed-model IDs and user selections stable. Do not silently swap or delete a model.
   Any load restriction must explain the reason and offer an explicit alternative.

**Acceptance:** deterministic fixtures cover exact/unknown byte counts, decimal formatting,
selected-file totals, insufficient disk space and preservation of existing selections. Tests must
not depend on live Hugging Face responses. Record the provenance of the verified catalog snapshot.

**Device evidence:** separately test cold load, repeated image turns, realistic history, cancellation,
thermal/memory pressure and coexistence with audio/camera on supported phone tiers. Record peak
process memory, relevant termination reports and settings. Do not equate allocator counters with
total memory or infer the cause of a watchdog termination from an unreproduced report. Decide retain,
restrict or remove from recommendations based on OpenGlasses evidence; metadata correction need
not wait for that pass.

## P1 / PR2 — Contain malformed local tool output

Trace `sendLocal`, parsing, preview delivery, TTS consumers, corrective generation, tool-result
generation and history insertion for both direct MLX and the runtime-coordinator/GGUF path. Use
one shared output policy at those boundaries, preserving the existing bounded tool protocol.

- Recognize valid calls, incomplete protocol frames, malformed calls and ordinary prose. Buffer
  ambiguous protocol prefixes until classification is possible; release ordinary text promptly.
- Never execute malformed calls or repair their arguments into an action by guessing. Unknown or
  disallowed tools continue through existing authorization rules and cannot gain access here.
- Do not speak or persist raw malformed protocol text as a successful assistant answer. Return a
  concise failure when no valid answer remains, without claiming an action happened.
- Apply cleanup before durable conversation insertion as well as streaming speech. Audit bounded
  recent-history sanitation for older malformed assistant turns without rewriting genuine user
  messages or deleting saved conversations.
- Handle partial tags split across chunks, unterminated/multiline blocks, mixed prose/protocol,
  malformed JSON, bare protocol-like output and a second tool attempt after a tool result.
- Do not use prefix or substring bans such as `startsWith("face")`, `startsWith("tool")` or a bare
  `web_search` match. Legitimate explanations of tools/code, quotations and multilingual text must survive. If an ambiguous bare
  fragment cannot be distinguished safely, document the limitation instead of claiming full coverage.
- Preserve cancellation, bounded generation and runtime selection. Any correction or final-answer
  regeneration must use the selected runtime and stop on cancellation; no unbounded retries or
  unintended cloud fallback.

**Acceptance:** drive the real `sendLocal` path with fake generation chunks and a recording tool/TTS
sink. Verify no unintended action, no raw protocol speech, no polluted history, and a normal next
turn after a failure. Include positive controls for valid tools and ordinary sentences such as
“Face the window” and “The web_search tool accepts a query,” plus quoted JSON. Cover direct MLX,
coordinator MLX and GGUF, including cancellation during correction and final generation. Demonstrate
that baseline malformed fixtures fail before the fix; do not merely test a helper in isolation.

## P2 / PR3 — Honest download and model-preparation feedback

Audit both legacy MLX screens and the newer model manager/acquisition path. Existing download and
load operations may already be separate: preserve their semantics and fix only missing status.

- Drive phases from actual operation boundaries: downloading, verifying where verification exists,
  loading/preparing, ready, cancelled or failed. Do not infer a phase from reaching estimated bytes.
- Show byte progress only where measurable; use an indeterminate preparation indicator after
  download completion. Never display invented preparation percentages or a successful verification
  phase that did not occur.
- Keep cancel effective where supported. If a lower-level preparation call cannot cancel promptly,
  invalidate its result, explain the pending stop and prevent late completion from activating it.
- Reset status across retry/model changes and expose phase names to VoiceOver without repeated
  percentage announcements. Do not log paths, prompts or model-server secrets.

**Acceptance:** fake slow preparation, multi-file progress, unknown total, failed verification,
cancel/retry and late completion. A completed download cannot appear indefinitely as “Downloading
99%” while a distinct load is running. Device-check a cold preparation and cancellation without
introducing new loading work solely to animate progress.

## P3 — Audit memory-context diagnostics; implement only missing pieces

Coordinate with [FA](FA-reading-source-and-memory-continuity.md), DX/EN and the existing prompt
budget owners. No second memory database or lexical scoring layer.

Inventory per-turn context assembly across Direct/local and live backends. Where absent, add a
compact diagnostic snapshot: memory availability, records retrieved versus included, actual
rendered character/token estimate, truncation and omission reason. Distinguish disabled, empty,
unavailable and omitted-for-budget. Live session context assembled at connect time must be labelled
with its actual snapshot time, not presented as fresh per-turn retrieval.

Expose counts/reasons through existing local diagnostics; omit memory text, person names and
queries. Measure after filtering/rendering so counters describe the prompt actually sent. Preserve
privacy/local-only policies and make no changes to retrieval ranking solely for diagnostics.

**Acceptance:** fixture contexts cover no memories, unavailable storage, stale live snapshot,
budget truncation, deterministic inclusion and Unicode. Reported lengths/counts match rendered
context and remain privacy-safe. If current diagnostics already satisfy this, close with evidence
and no new code.

## Dependencies, exclusions and order

Reuse DZ for model metadata/runtime, BK/BG for local generation, CU for turn timing, and DM for
diagnostics privacy. Ship P0 first, then P1; P2 can follow the verified metadata/phase audit. P3 is a
small follow-up audit, not a prerequisite for those correctness fixes.

Excluded: wholesale imports, agent orchestration or patch-dispatch CI, additional regional
providers, locale-specific defaults, speaker-similarity authorization, remote metrics telemetry
and a second memory database. No new dependency is required by the planned fixes.

## Completion evidence

| Gate | Status |
|---|---|
| Verified artifact metadata and corrected consumers | Pending |
| Malformed-output regression fixtures through actual service boundaries | Pending |
| Direct/coordinator runtime and cancellation checks | Pending |
| Download/preparation status checks | Pending |
| Supported-device model qualification | Pending — separate from metadata fix |
| Memory diagnostics audit and gap disposition | Pending |

Record build/commit, fixture or model revision, hardware/OS where applicable, result and remaining
gap as each phase lands. Automated checks cannot close device qualification. Final disposition
must distinguish implemented safeguards from externally reported or still-unreproduced failures.
