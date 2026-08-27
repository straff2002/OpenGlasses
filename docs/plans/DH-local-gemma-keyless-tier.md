# Plan DH — Local Gemma as the Universal Keyless Tier

**Status:** 📝 Drafted 2026-08-25

## Why

The aim is for the app to work on as many phones as possible. The keyless first-run chain
(Plan DB) resolves: legacy key → Apple Intelligence *if the device has it* → downloaded local
model → unconfigured. Apple Intelligence is device-gated, which leaves a large slice of
perfectly capable iPhones with no on-device brain on the "Start without an API key" path. A
working local Gemma closes that gap: it is the peer **alternative to Apple Intelligence**, not
a curiosity — any device that runs MLX gets a real assistant with no account, no key, and no
cloud. It is also a VLM, which upgrades the assistive tier: continuous scene narration (CV) is
deliberately local-VLM-only, so a reliably-loading Gemma serves the blind wearer as directly as
the keyless newcomer.

An external contribution (PR #331) identified the right problems — the Gemma 4 VLM load
failure, chat-template/parsing fixes with tests, local vision capability — but bundles them
with photo-library/camera/recording refactors that now conflict with the shipped broadcast,
capture-audio, and recording-persistence work. This plan extracts the Gemma value with credit
and closes that PR gracefully, rather than letting it rot as conflicting.

The load failure itself is already fixed upstream (`mlx-swift-lm` — KV-shared layers must not
declare `k_proj`/`v_proj`; the k_norm keyNotFound we reproduced). We track that package on
`branch: main`, so the fix arrives by refreshing the pinned resolution, not by patching.

## P1 — Load + parse correctly

- Refresh `Package.resolved` and the committed `ci_scripts/Package.resolved` (via
  `Scripts/update-package-resolved.sh`) to pull the upstream fix; verify Gemma 4 VLM actually
  loads on-device paths headlessly where possible. Keep the standing constraints tested: the
  1-D token shape for text-factory models, and the Gemma chat-template facts (template lives in
  `chat_template.jinja`, system role merges into the first user turn — a role-flip hazard).
- Port the chat-template/parsing fixes and their tests from PR #331 (`Gemma4ChatPromptTests`
  and related), **crediting the contributor in the commit and PR**. Evaluate whether its
  swift-jinja dependency is genuinely needed for correct templating or whether the existing
  template path suffices — take the smallest dependency footprint that renders the template
  correctly.
- Out of this phase: everything else in #331 (photo album, camera, recording refactors) — close
  the PR with thanks, credit, and a pointer to what was taken; anything of residual value there
  gets re-evaluated against current main separately.

## P2 — First-run integration

- `FirstRunDefaults.resolve` already prefers a downloaded local model when Apple Intelligence
  is absent; make Gemma *offerable* at onboarding: the "Start without an API key" card gains an
  optional "Download offline model" step — size stated up front, progress + resume, storage
  check via the existing budget/headroom machinery, and honest copy: on an Apple Intelligence
  device the assistant works now and the download is an upgrade; on other devices the assistant
  is ready when the download completes.
- Device capability gate: a conservative RAM/chip heuristic decides whether Gemma is offered at
  all — a phone that would thrash gets the cloud-provider paths, stated plainly, not a broken
  local tier.

## P3 — Vision wiring

Route the local vision tier (scene narration, vision_assess consumers that accept a local
model) through Gemma's VLM where it beats the current local option — measured, not assumed:
decode latency and the Metal contention constraint (VLM decode vs on-device TTS synthesis) are
the deciders, per the CV plan's duty-cycle reasoning.

### P3 correction from the device (2026-08-27)

A photo turn to the loaded Gemma killed the app to the home screen. The Jetsam event: terminated
for **per-process-limit** while frontmost, at a 6.2 GB footprint, on a 12 GB iPhone.

Two decisions in P1/P3 were wrong together, and each was defensible alone:

1. **The tier was decided on marketing RAM.** `multimodalTurnPlan` gave anything ≥ 12 GB the full
   prompt, full history and no image cap. But device RAM is not the constraint — iOS's per-process
   allocation cap is, and it does not scale with the box on the shelf. With multi-gigabyte weights
   resident and the camera pipeline live, a 12 GB phone had a few hundred megabytes left to
   allocate and was still on the "roomy" tier. The plan now takes the headroom measured at *turn
   time* (`os_proc_available_memory()` via `MemoryHeadroom`), treats a roomy-but-full device as
   constrained, and refuses the image outright below a floor — spoken honestly
   (`LocalLLMError.insufficientMemoryForPhoto`) rather than as a process kill.
2. **The forced 896² pre-resize was removed** on the reasoning that Gemma's processor picks its own
   canvas and its own soft-token count. That is true of the *token* count and beside the point for
   memory: preprocessing a full-resolution frame materialises it as float pixels on top of an
   already-resident model. The cap is back, but computed aspect-preserving from the frame's own
   dimensions rather than passed as a square — so the crop the removal was defending survives, and
   the long edge follows the tier.

Both are pure decisions and are tested against injected headroom values, including the measured
crash scenario. The performance matrix in P4 should now record headroom alongside tok/s, since
headroom is what decides whether a photo turn happens at all.

## P4 — Deferred device work

The performance matrix this plan exists for: which phones run it acceptably (decode tok/s,
first-token latency, battery/thermal over a session), measured on hardware. P2's capability
gate gets its real thresholds from this.

## Non-goals

- Merging PR #331 wholesale, or its photo/camera/recording refactors.
- Background local inference (on-device MLX cannot run backgrounded — standing constraint;
  cloud remains the only background path).
- Replacing provider sign-in as the mainline onboarding: zero-paste sign-in stays the
  95% path; Gemma is the no-account/offline tier.
- New model formats or a model-management UI beyond the single offer + the existing local-model
  surface.
