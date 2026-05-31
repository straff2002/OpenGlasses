# Plan Q — Vault & skills-library management (edit, export, import)

**Status:** ✅ Shipped. Slice 1 — `FieldAssistSettingsView` "Reference Files" section editing every unlocked vault via `VaultFilesEditorView`. Slice 2 — `VaultExporter` (overlay-merged folder export, round-trips through `VaultImporter`; paid bundled baselines refused for licensing), surfaced as a per-row swipe Export in `VaultManagerView`. Slice 3 — versioned `SkillsLibraryEnvelope` export/import for ClawHub (`InstalledSkillStore`, gated behind `agentModeEnabled`, imports arrive **disabled** with a confirm step + recomputed compatibility) and voice skills (`VoiceSkillStore` → new `VoiceSkillsManagerView`, local, ungated). Tests: `VaultExportTests`, `SkillsLibraryTests`.

**Builds on:** [`VaultStore`](../../OpenGlasses/Sources/Services/Vault/VaultStore.swift), [`VaultImporter`](../../OpenGlasses/Sources/Services/Vault/VaultImporter.swift), [`VaultFilesEditorView`](../../OpenGlasses/Sources/App/Views/VaultFilesEditorView.swift), [`VaultManagerView`](../../OpenGlasses/Sources/App/Views/VaultManagerView.swift) (Field Assist / Plan F + H), [`InstalledSkillStore`](../../OpenGlasses/Sources/Services/ClawHubService.swift) (ClawHub), and [`VoiceSkillStore`](../../OpenGlasses/Sources/Services/NativeTools/VoiceSkillsTool.swift). All the storage and round-trip machinery already exists; this surfaces and completes it.

**Strategic fit:** B2B + power-user. Field Assist agents are only as good as their grounded library — letting a tech edit references, and letting a team author a vault once and share it across devices, is the difference between a demo and a deployable pack. The same gap exists for the two skills libraries (ClawHub installed skills, voice-taught skills): both are already `Codable` JSON but neither can be moved between devices.

**Effort:** ~1–1.5 days for all three slices.

---

## The gaps (all three are "machinery exists, not surfaced")

1. **Field Assist references aren't editable in-app.** `FieldAssistSettingsView` shows each vault as *"v{version} — {N} reference files"* — a count only ([FieldAssistSettingsView.swift:37](../../OpenGlasses/Sources/App/Views/FieldAssistSettingsView.swift)). The generic editor `VaultFilesEditorView` (file list → `TextEditor` → Save to the Documents overlay) is wired in Settings for **only `vaultId: "notes"`** ([SettingsView.swift:268](../../OpenGlasses/Sources/App/Views/SettingsView.swift)); the domain vaults (refrigeration, IT, electrical, automotive) reach it from nowhere.

2. **Vaults can be imported but not exported.** `VaultImporter.install(from:)` consumes a folder (manifest.json + markdown + optional `procedures/`) ([VaultImporter.swift:35](../../OpenGlasses/Sources/Services/Vault/VaultImporter.swift)). There is **no inverse** — the only `export` in the app is `SessionExporter` (a per-session audit record, not the library). A tech's overlay edits, or an on-device-authored vault, can't be shared.

3. **Skills libraries can't move between devices.** `InstalledSkillStore` persists `[InstalledSkill]` to `Documents/clawhub_skills.json`; `VoiceSkillStore` persists `[VoiceSkill]`. Both are plain `Codable` arrays — trivially serialisable — but there's no export/import surface for either.

## Slices

### Slice 1 — Edit Field Assist references (smallest; no new logic)
`VaultFilesEditorView` is already generic on `vaultId`. Make each vault row in `FieldAssistSettingsView`'s "Default Vault" section a `NavigationLink` into:
```swift
VaultFilesEditorView(vaultId: manifest.id, title: manifest.name)
```
Writes already land in the Documents overlay via `VaultStore.write`, never mutating the bundled baseline. Gives file-list → tap → edit → Save for every Field Assist vault, reusing the Personal Notes path. (Optional: a separate "Edit files" row rather than overloading the default-vault selector tap, so selecting vs. editing stay distinct.)

### Slice 2 — Vault export (round-trips through the existing importer)
Add `VaultExporter.export(id:) -> URL` (folder):
- For each `manifest.files` entry, read via `VaultStore.read` — which **merges overlay-over-bundle** ([VaultStore.swift:6-10](../../OpenGlasses/Sources/Services/Vault/VaultStore.swift)), so the export captures the tech's edits, not just the shipped files.
- Copy the `proceduresDir` JSON if present.
- Write `manifest.json` + files (+ `procedures/`) into a temp folder; hand to a SwiftUI `fileExporter` / `ShareLink`.
- Output format == import format, so `VaultImporter.install` consumes it directly — full edit → share → import round-trip.
- **Surface:** an Export action per row in `VaultManagerView` (and optionally per-vault in `FieldAssistSettingsView`).
- **Decision — IAP/licensing:** exporting a *paid bundled* vault's content (refrigeration, etc.) would bypass the per-pack IAP gate. Restrict export to **user-imported/authored vaults and the user's own overlay edits**; do not export the bundled paid baseline. (Aligns with the agent-mode/gateway gating convention.)
- **Folder vs zip:** export a folder for symmetry — the importer expects an already-unzipped directory. A `.zip` variant is a follow-up needing an unzip step on import.

### Slice 3 — Skills-library export/import
Mirror the vault `fileImporter` pattern; skills are simpler (a single JSON array, not a folder).
- **ClawHub (`InstalledSkillStore`):**
  - *Export:* encode `[InstalledSkill]` (or a selected subset) to `skills-library.json` via `fileExporter` / `ShareLink`.
  - *Import:* `fileImporter(allowedContentTypes: [.json])` → decode → merge by `slug` (`install()` already dedupes removeAll-then-append) → `save()` → refresh prompt context.
  - *Surface:* Export / Import toolbar in `ClawHubBrowserView`.
- **Voice (`VoiceSkillStore`):** same shape over `[VoiceSkill]` — a clean "move my setup to a new phone" feature; local, so no gateway gate.
- **Three things to get right:**
  1. **Gating** — ClawHub/OpenClaw is a gateway feature → its export/import sits behind `agentModeEnabled`. Voice skills are local and don't need the gate.
  2. **Prompt-injection safety** — a skill's `content` is injected straight into the system prompt ([promptContext()](../../OpenGlasses/Sources/Services/ClawHubService.swift)). Import **disabled-by-default** with a review/confirm step; never silently enable an imported skill.
  3. **Re-validate compatibility on import** — recompute `SkillCompatibility` against this device's native tool set (`nativeToolNames`, as `ClawHubBrowserView` already does) rather than trusting the file.
- **Versioned envelope** for both: `{ schemaVersion, exportedAt, items: [...] }` so the format can evolve (same discipline as a vault manifest).

## Out of scope
- No `.zip` packaging in v1 (folder export only; importer expects unzipped).
- No cloud/gateway sync — these are local file export/import (AirDrop, Files, share sheet). Sync is a separate effort.
- No migration of bundled paid vaults to exportable form — deliberately excluded for licensing (Slice 2 decision).
- Procedure *authoring* UI stays out — this moves existing libraries around, it doesn't add an in-app procedure editor.
