# Plan DH — Local Gemma as the Universal Keyless Tier

**Status:** 🚧 P1 shipped 2026-08-25 · P2 shipped 2026-08-27 · P3/P4 remain

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

## P2 — First-run integration ✅ (2026-08-27)

- `FirstRunDefaults.resolve` already prefers a downloaded local model when Apple Intelligence
  is absent; make Gemma *offerable* at onboarding: the "Start without an API key" card gains an
  optional "Download offline model" step — size stated up front, progress + resume, storage
  check via the existing budget/headroom machinery, and honest copy: on an Apple Intelligence
  device the assistant works now and the download is an upgrade; on other devices the assistant
  is ready when the download completes.
- Device capability gate: a conservative RAM/chip heuristic decides whether Gemma is offered at
  all — a phone that would thrash gets the cloud-provider paths, stated plainly, not a broken
  local tier.

**As built.** `OfflineModelOffer` is the pure decision — RAM, free disk and what is already on
disk in, one of four verdicts out (offer with its size, already downloaded, no room, device too
small) — plus the copy each verdict carries, so the wording is asserted headlessly rather than
only read in a running UI. Ordering is deliberate: a model already downloaded beats every other
answer, then the capability gate, then storage. The gate's threshold is the offered model's own
catalog `minimumRAMGB` and a test pins the two together, so the model list stays the single place
a tier line is drawn; an unreadable volume is never a reason to refuse.

The offer sits on the keyless provider's page, and that page is now reachable on **two** kinds of
device. Where Apple Intelligence exists the card is unchanged and the download is framed as an
upgrade ("the assistant already works on this iPhone…"). Where it does not, the "Start without an
API key" card is shown for the first time — gated on the offer being real — and the download is
framed as what makes that path work. A phone below the bar sees no keyless card and, if it
reaches the page another way, is told plainly that the cloud providers are its path.

The download reuses the local-model screen's service call and its `DownloadProgressRow`, so there
is one download path in the app with one cancel, one resume and one progress reading. Leaving
mid-download is stated in the footer rather than left to faith, and both ends of the wait are
spoken for VoiceOver.

**Also in this change (not from this plan):** the delete-and-reinstall welcome-back page. The
Keychain outlives an app delete and `UserDefaults` does not, so the onboarding gate read surviving
credentials as "already set up" and skipped silently. `Config.isReinstall` is the pure verdict —
credentials on file, no completion flag, and no corroborating long-lived default — captured once
at launch before any migration writes. In that state onboarding *shows*, with the first page in a
welcome-back variant offering "Restore my setup" (the old silent path, chosen) or "Set up fresh".
Both exits set the completion flag and run the `Wearables.configure()` path; a true fresh install
is unchanged.

## P3 — Vision wiring

Route the local vision tier (scene narration, vision_assess consumers that accept a local
model) through Gemma's VLM where it beats the current local option — measured, not assumed:
decode latency and the Metal contention constraint (VLM decode vs on-device TTS synthesis) are
the deciders, per the CV plan's duty-cycle reasoning.

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
