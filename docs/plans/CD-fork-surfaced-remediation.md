# Plan CD — Fork-Surfaced Correctness Remediation

**Status:** 🚧 P1–P3 implemented in one PR (2026-07-30) — `WearablesBootstrap` + `Config.isPastOnboarding`
gates on every reachable SDK path; `PhraseMatcher` + demotion rules in `VoiceCommandParser`, barge-in
path unified onto it; both 0.x deps pinned exact; tracked `tests.yml` workflow added. Owed: device
smoke of the Connect flow from the desync state, and enabling tests in the Xcode Cloud workflow
(App Store Connect config, not code).

## Where this came from

A sweep of downstream forks. Most carry only signing, branding, or CI changes, but a handful
contain real engineering, and the signal worth acting on is **convergence**: three independent
forks, working separately, each landed on the same fix to the same startup defect. One of them hit
it as a hard crash the first time a CI run actually executed our test suite. Two more classes of
defect surfaced alongside it. Every item below was re-verified against current `main` — several of
the fork-reported bugs are already fixed here and are *excluded*.

## P1 — The launch/Connect crash, and why it was invisible

### The defect

`Wearables.configure()` is called only when `Config.hasCompletedOnboarding`
([OpenGlassesApp.swift:141](../../OpenGlasses/Sources/App/OpenGlassesApp.swift#L141)), and
`GlassesConnectionService.init()` gates `observeDevices()` on the same flag
([GlassesConnectionService.swift:20](../../OpenGlasses/Sources/Services/GlassesConnectionService.swift#L20)).
But onboarding is only *shown* when:

```swift
// Config.swift:100
static var needsOnboarding: Bool {
    !hasCompletedOnboarding && savedModels.allSatisfy { $0.apiKey.isEmpty }
}
```

**Save an API key before finishing onboarding and neither condition holds.** `needsOnboarding`
goes false because a key exists, so onboarding never appears again and `hasCompletedOnboarding` is
never set — so nothing ever calls `configure()`, and there is no in-app route back to onboarding to
recover. The app is now permanently in a state where the SDK is unconfigured.

That state is fatal by design. MWDAT answers *any* unconfigured `Wearables.shared` access with
`fatalError` — not a throw:

```
MWDATCore/Wearables.swift:259: Fatal error: Call `configure()` before attempting to access Wearables!
```

There are **45 unguarded `Wearables.shared` sites** in `Sources`. Tapping Connect kills the app
outright. And even a registration that somehow completed would never surface as connected, because
the devices listener is behind the same dead flag.

The bug is a **two-flag desync**: `hasCompletedOnboarding` is being used as a proxy for "the SDK is
configured", and the two can diverge in both directions — configure-failed-but-onboarded (crash),
and configured-but-not-onboarded (glasses silently dead).

### The fix

`WearablesBootstrap`: configure on demand at the point of use, at most once, returning whether the
SDK is usable. Both existing `configure()` call sites funnel through it so double configuration is
impossible; `connect()` and `startObserving()` configure on demand rather than trusting a caller to
have done it, and bail with a readable status instead of dying.

This preserves the reason the deferral existed in the first place — the Bluetooth prompt still
waits until the user reaches for the glasses — without making that depend on two flags staying in
sync.

Then a published `isConfigured` gate on the reachable `Wearables.shared` paths, so an unconfigured
build degrades to "Meta SDK not registered" in the UI, which is the honest state:

- URL callback handling — **Meta AI can deliver a callback at any time**, including when configure
  failed at launch, so `handleUrl` would trap rather than throw.
- `scenePhase == .active` resume registration check.
- The devices / registration-state listeners and the launch state check.
- `startRegistration()` / `startUnregistration()` entry points.
- `CameraService` — already better off here than the forks' base (`deviceSelector` is `lazy`, so it
  only traps if something touches it), but every entry point should throw the existing
  `CameraError.sdkNotRegistered` rather than relying on nobody touching it.

**Not a test-only artifact.** Any environment where configure fails — a missing `DEVELOPMENT_TEAM`,
revoked MWDAT config, a simulator — turns a logged warning into a hard crash at launch.

### Why we never saw it: no tracked CI runs the tests

The repo's CI picture, verified rather than assumed: `.github/` is **gitignored** (`.gitignore:41`),
so the `build-ios.yml` / `app-store-upload.yml` workflows that exist locally were never on GitHub at
all — the only tracked workflow is `pages.yml` (force-added), and GitHub confirms only the Pages
workflows exist. Real CI is **Xcode Cloud** (`ci_scripts/`), whose workflow definition lives in App
Store Connect and is invisible from the repo — and nothing in the repo asserts that it runs this
suite. **224 test files in `OpenGlassesTests/` with no tracked workflow that executes any of them.**
Downstream, the very first CI run that actually executed the suite crashed the test host on this
defect and nothing else.

Wiring the suite into a *tracked* workflow belongs in this phase, not a later one — it is the
control that would have caught the crash, and every subsequent item in this plan is only as durable
as the thing that runs its tests. A GitHub Actions test job is force-added the same way `pages.yml`
was (needs `git add -f` past the `.github/` ignore; needs a `macos-26` runner for the iOS 26 SDK,
xcodegen from a GitHub release, and `SWIFT_EMIT_LOC_STRINGS=NO` so CI does not churn the
localization catalog). Separately worth doing in App Store Connect: turn tests on in the Xcode
Cloud workflow — that half is config, not code, and cannot land in this PR.

### Tests
- `WearablesBootstrap` configures at most once across concurrent callers; reports unusable without
  trapping.
- The desync itself is pinned: key-saved-but-not-onboarded resolves to a usable SDK (or an honest
  refusal), never to an unguarded access.
- The unconfigured fail-soft contract — every gated entry point returns/throws rather than trapping.

## P2 — Voice commands fire on utterances that only *mention* them

Three defects, one root cause: substring matching on command phrases.

### Two divergent stop matchers

`VoiceCommandParser.isStop` (Plan BG P2) is already careful — whole-token equality or a
leading/trailing token, so `"nonstop music"` correctly does not fire. But the **barge-in path does
not use it.** [WakeWordService.swift:750](../../OpenGlasses/Sources/Services/WakeWordService.swift#L750)
has a second, naive matcher over `stopPhrases = ["stop", "stop stop"]`:

```swift
for phrase in allStopPhrases {
    if transcript.contains(phrase) { return true }
}
```

So `"it stopped working yesterday"`, `"nonstop"`, `"stops"`, and `"unstoppable"` all cut the
assistant off mid-sentence. Nobody chose that — it is `String.contains` doing exactly what
`String.contains` does. Unify on one matcher; the hardened rule already exists and simply is not
reached from the path that matters most.

**Tightening `.stop` is the dangerous direction, and this is the constraint to respect.** Moving
risk from false-positive to false-negative here costs the user the ability to interrupt — they say
"stop" and the assistant talks over them. So a bare word-boundary test is not sufficient on its own:
ASR emits `"stop."` and `"stop,"` (handle by tokenising on non-alphanumerics — note our `normalize`
only lowercases and trims, so punctuation currently survives), and sometimes runs the next word on
with no space. The latter needs a **closed list** of words people actually say after "stop"
(`"stop it"` → `"stopit"`), and that list must never admit an inflection — `stopped`/`stopping`/
`stops` are the original bug — so it gets its own pinning test.

### Two false positives that survive word boundaries

For these the command phrase genuinely *is* present as whole tokens, so tokenising does not help:

| Utterance | Current behaviour |
|---|---|
| `"how do i take a photo with these glasses"` | **Fires the camera and writes a JPEG** |
| `"that's all i wanted to ask about the weather"` | Ends the conversation |

`VoiceCommandParser.isPhoto` and `isGoodbye` both use `lower.contains($0)`, and `"that's all"` is in
the goodbye list.

The first is the one this product genuinely cannot ship with: the camera is on someone's face, the
person in front of it never agreed to be photographed, and the user was asking how the glasses work.

Neither is fixable by adding strings to a blocklist. A phrase match becomes a **candidate**, demoted
to ordinary speech by two rules stated in terms of utterance shape:

- **Rule A — interrogative frame.** The utterance opens with a question lead-in about method or
  cause, and the command phrase begins at or after the end of that lead-in. Applies to `.photo` and
  `.goodbye`. `"can you"` / `"could you"` / `"please"` are deliberately **not** lead-ins — they are
  polite imperatives, and listing them would turn the politest phrasing of a real command into a
  no-op.
- **Rule B — non-final close.** A sign-off must *end* the utterance: every token after the match
  must come from a closed trailer set. `.goodbye` only — `.photo` takes legitimate objects
  (`"take a picture of the sunset"`), and `.stop` stays greedy per the asymmetry above.

Every demotion logs the rule that fired, so a field demotion is traceable to its clause. Counts
only, never the words — the transcript-privacy rule stands.

### Test methodology worth adopting wholesale

Two techniques from the fork work, applicable well beyond this plan:

1. **A false-positive corpus carries a positive control.** The test asserts the *old* predicate
   really did fire on those strings. A corpus that cannot produce the bug proves nothing by not
   producing it.
2. **Recall is compared case-by-case against the old predicate**, so a tightening that silently
   loses a real catch fails the suite rather than passing quietly.

Also: assert on the **absence of a written JPEG**, not on the routing enum. A test that only checks
the enum still passes if some other path fires the shutter. And drive the production gate from the
test rather than a restatement of it.

## P3 — Pin the SDK versions that break on minor bumps

```yaml
meta-wearables-dat-ios:
  from: "0.8.0"     # → >= 0.8.0, < 1.0.0
```

For a 0.x dependency, `from:` admits any later 0.y — and our own
`.claude/rules/dat-conventions.md` is the proof this is unsafe: 0.8.0 *removed* the `Capability`
protocol and `addCapability`, made `Stream.start()/stop()` synchronous, and 0.7.0 removed
`DeviceStateSession` entirely. A published 0.9.0 would be auto-adopted on the next resolve and break
the build with no change on our side. Pin exact — `mlx-swift-lm` already is (`version: "3.31.3"`,
pinned for a known breakage), so the precedent and the reasoning are both established.

`swift-huggingface: from: "0.1.0"` has the same 0.x exposure and should be pinned with it. The
committed `ci_scripts/Package.resolved` masks this until something re-resolves, which makes the
failure arrive at the worst time rather than never.

## Explicitly excluded after checking `main`

Fork-reported issues that are **already fixed here** — recorded so the sweep is not repeated:

- **`CameraService` eager SDK construction at init** — ours is `lazy var deviceSelector`.
- **Leaking `ConfigTests`** — ours has proper `setUp`/`tearDown` with explicit key removal.
- **Unsigned-IPA CI for sideloading** — `build-ios.yml` already does this.
- **`VoiceCommandParser.isStop` word-boundary matching** — already correct; the defect is that
  `WakeWordService` doesn't use it (P2).
- **Malformed-response parse hardening / assistant renaming / brand assets / Codemagic and ASC
  build-number automation** — either fork-specific product forks (a different server endpoint, a
  different assistant identity) or downstream distribution plumbing with no upstream claim.

## Sequencing

P1 stands alone and should go out as a straightforward bug-fix PR — it is a reproducible crash, and
the CI wiring in the same PR is what keeps it fixed. P2 and P3 are independent and can follow in
either order. P2 is the larger piece of work and the one with a genuine product judgement in it (the
`.stop` asymmetry); P3 is a two-line spec change plus a resolve.
