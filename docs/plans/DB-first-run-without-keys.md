# Plan DB — First-Run Without Keys

**Status: ✅ Shipped 2026-08-24** — `FirstRunDefaults` + the migration fix, a keyless choice and a
Back button in onboarding, and actionable missing-credential copy. `FirstRunDefaultsTests` covers
the resolution (fresh install / legacy-with-key / legacy-without-key) and the error copy.

A fresh install has no API key. Off the App Store that is not an edge case — it is the **mainline
first-run path**, and until now it produced an app that could not answer a question.

## Why

Three things lined up to make "install, skip setup, ask something" fail:

1. **The migration invented a broken default.** `Config.migrateFromLegacy()` runs whenever the saved
   model list is empty, which on a fresh install means the first read. With no legacy key to carry
   over it appended `ModelConfig.defaultConfig(for: .anthropic)` — a config whose `apiKey` is `""` —
   and made it **active**. The first question then reached `LLMService.sendAnthropic`, which throws
   on the empty key. The app shipped with a default model that cannot work.
2. **Onboarding never offered the keyless option.** `LLMProvider.appleOnDevice` needs no key and
   `Config.appleIntelligenceDefault` already existed as a saved config, but the provider page listed
   only key-bearing providers (plus one subscription sign-in). There was no way to say *"just start"*.
3. **The flow was one-way.** The page index only ever incremented — seven pages, no Back button. A
   user who picked the wrong provider on page 2 had no way back to change it.

The failure is worst for exactly the user we most want to keep: someone who bought glasses, installed
the app, and has no idea what an API key is.

## Scope

**1. Never activate a config without a credential.** A new pure resolver decides what a first launch
activates, given three plain inputs:

```swift
FirstRunDefaults.resolve(hasLegacyKey:appleIntelligenceAvailable:localModelDownloaded:) -> FirstRunDefault
```

- `hasLegacyKey` → `.migratedLegacyKey`: an upgrading user keeps the model they were already using.
  This case is checked **first**, so existing installs migrate exactly as before.
- else on-device system model available → `.keyless(.appleOnDevice)`.
- else an on-device model already downloaded → `.keyless(.local)`.
- else → `.unconfigured`: leave the active model **unset** rather than fabricate a keyed one. The
  saved list still carries the on-device entry (the non-migration path adds it regardless), so the
  list is never empty and the send-path copy is what guides the user.

Availability is a real probe, not an assumption — `FirstRunDefaults.appleIntelligenceAvailable` asks
the system model for its availability and is false on every OS and device that can't run it. The
"is a local model downloaded" input is a filesystem look at the model cache, exposed as
`LocalLLMService.downloadedModelIdsOnDisk()` (the instance method now delegates to it) so the answer
is available before the service exists.

`migrateFromLegacy()` switches on the resolution instead of appending a blank Anthropic config. Its
unreachable "emergency default" branch goes with it.

**2. Onboarding.** Two small changes, same look:

- A **Back** chevron overlaid on the leading edge of the page indicator, on every page but the first.
- **"Start without an API key"** as the first card on the provider page — selects the on-device
  provider, and says keys can be added later in Settings. Hidden when the device can't run the
  on-device model, because offering it there is a dead end. The rest of the page is untouched; the
  existing key page already handles a provider that needs no key.

**3. Error copy.** `LLMProvider.missingCredentialMessage` is the single source for "this provider has
no credential", and it always names both ways out — add a key in Settings → AI Models, or switch to
on-device intelligence (Anthropic also offers the account sign-in). The Anthropic, Gemini, and
OpenAI-compatible send paths all use it. The on-device "device not eligible" message gained the same
pointer, since the keyless default can legitimately land there.

## Out of scope

- **Redesigning onboarding.** Seven pages, same visual language, same copy elsewhere. Two additions,
  nothing moved.
- **UI tests for the flow.** There are none today, and this plan does not add the harness for them —
  the Back button and the new card are verified by build and by reading, not by an automated pass.
  Worth having; a separate piece of work.
- **Provider feature parity.** The keyless default only has to answer questions. It has no tool
  channel, no vision, and no realtime mode, and that is fine — it is the floor, not the destination.
- **Choosing a keyless default for the realtime modes.** Gemini Live and the Realtime session still
  need their own keys and say so.

## Testing

`OpenGlassesTests/FirstRunDefaultsTests.swift` — pure, no Keychain, no filesystem, no model loading:

- fresh install with the on-device model available → `.keyless(.appleOnDevice)`;
- fresh install without it but with a downloaded local model → `.keyless(.local)`;
- on-device availability wins over a downloaded local model;
- fresh install with neither → `.unconfigured`;
- whatever provider is resolved as keyless never reports `requiresAPIKey`;
- a legacy key wins over both on-device options → `.migratedLegacyKey`;
- a legacy install whose fields are blank never reports `.migratedLegacyKey`, under every
  availability combination;
- every key-requiring provider's missing-credential copy names Settings and the on-device route, and
  Anthropic's also names the account sign-in.
