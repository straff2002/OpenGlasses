# Local model qualification (device app)

This separate iOS app measures a downloaded model, or Apple's on-device model as the baseline,
against the committed local tool corpus (`Scripts/local-tool-eval/corpus/local-tool-corpus.v2.jsonl`)
on a real phone (Plan MQ P3). It does not replace the main app and has its own bundle identifier,
`com.openglasses.localmodelqualification`.

It compiles the production local path by path (`project.yml`): `LocalLLMService` and its MLX
runtime, the shipped tool loop, parser, argument coercion, output policy, schema conversion,
tool-result framing, catalog sampling and memory budget, and the eval core CI runs
(`OpenGlassesTests/LocalToolEval/`). Each case is assembled exactly as `LocalToolEvalCorpusTests`
assembles it; only the scripted model is swapped for real generation, so CI and the phone grade
identically. `Stubs.swift` adapts only telemetry, the per-turn diagnostics recorder, two type
names whose shipped lines live in their own files, and a photo-only prompt helper.

What the app cannot build without the whole app comes from `Fixture/qualification-fixture.json`:
each offered tool's description and parameters from the real registry, and the lean on-device
system prompt with the Lennox example vault's job open, fitted to each candidate model.
`LocalModelQualificationFixtureTests` rebuilds it from the app and fails (rewriting the file) when
it is stale: run that test, review the diff, commit it.

## Build and install

Run these from the repository root, with your signing team in `DEVELOPMENT_TEAM`. The app carries
the main app's increased-memory-limit entitlement, so the kill limit it measures is the app's.

```sh
export DEVELOPMENT_TEAM=XXXXXXXXXX
export AVENKIN_SOURCE_COMMIT=$(git rev-parse HEAD)
xcodegen generate --spec Scripts/local-model-qualification/project.yml
xcodebuild build -project Scripts/local-model-qualification/LocalModelQualification.xcodeproj \
  -scheme LocalModelQualification -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/local-model-qualification -allowProvisioningUpdates \
  SWIFT_EMIT_LOC_STRINGS=NO
xcrun devicectl list devices
xcrun devicectl device install app --device <device-id> \
  /private/tmp/local-model-qualification/Build/Products/Release-iphoneos/LocalModelQualification.app
```

## Run

Unlock the phone, put it on a charger, close other apps, and launch with arguments:

```sh
# A smoke run: the first 10 cases once, on battery allowed, no settle wait.
xcrun devicectl device process launch --device <device-id> --terminate-existing \
  com.openglasses.localmodelqualification --limit 10 --repeats 1 --settle 0 --allow-battery --cancel-probes 2

# The qualification run of Gemma 4 E2B (the default model): Field Assist with the restraint and
# not-in-the-manual categories, three repeats, behind the run gate.
xcrun devicectl device process launch --device <device-id> --terminate-existing \
  com.openglasses.localmodelqualification

# Another catalog model, or Apple's on-device model as the baseline.
xcrun devicectl device process launch --device <device-id> --terminate-existing \
  com.openglasses.localmodelqualification --model mlx-community/gemma-4-e4b-it-4bit
xcrun devicectl device process launch --device <device-id> --terminate-existing \
  com.openglasses.localmodelqualification --apple
```

Arguments: `--model <id>`, `--apple`, `--repeats <n>` (3), `--groups fieldAssist,everyday` or
`all`, `--limit <n>`, `--settle <s>` (120), `--cap <s>` (1200), `--allow-battery`,
`--cancel-probes <n>` (6), `--fresh`.

The app downloads the model itself on first use, through the production downloader (it cannot see
the main app's copy), so the first launch needs a network. Keep the app in the foreground: the
screen stays awake, and leaving the app stops generation at once. A relaunch with the same model,
settings and corpus carries on from the last finished case; `--fresh` starts over.

Before every case the run gate (`QualificationRunGate`) pauses only at `critical`, settles at the start
and after a `critical` spell, and measures through `serious`: heat changes the speed, not the answers,
so every answer counts and the timing comes only from cases that started `nominal` or `fair`. It refuses Low Power Mode and refuses a battery that is not on a charger. If heat
outlasts the cap, the case is measured and flagged (a flagged run can't grant a badge); if power is
still bad at the cap, the run stops. The near-miss twins in the corpus test the check, not a model,
so a phone run skips them and says how many.

## Results

`Documents/results.json` is rewritten after every case. It holds counts and hashes only: no
question, passage, tool argument or answer, and no case id (each run is keyed by a hash). It names
the device, OS build, app commit, runtime revision, model revision and quantisation, and the sampling
set used; per group and category it has pass counts with bootstrap intervals, decision 5's floors,
cut and zero-token replies; time to first token and decode rate; the kill limit, the fit before load
and the peak footprint against it; the thermal trace; the gate's waits and flags; and cancel latency.

```sh
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer --domain-identifier com.openglasses.localmodelqualification \
  --source Documents/results.json --destination ./results.json
```

Commit only a reviewed record, as dated JSON in `reports/`
(`reports/local-model-qualification-<date>-<model>.json`, decision 8), and only once it is
finished. Never commit the generated Xcode project, signing settings, downloaded weights or a
partial record. Delete the app afterwards to free the model's storage.
