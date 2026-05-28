# Plan A — Accessibility Tier (new IAP)

**Source repos:** [brain](https://github.com/christineortiz1125-cell/brain), [neurobridge](https://github.com/AspectParadox-dev/neurobridge)

**Strategic fit:** A coherent paid track parallel to Medical Compliance. Audience: dyslexia, ADHD, low-vision, language learners, neurodivergent users. Three composable features.

**Effort:** ~3-5 days total

---

## A1. Reading Accessibility Tool (from brain)

**Files:**
- New: `Sources/Services/NativeTools/ReadingAccessibilityTool.swift`
- New: `Sources/Services/Accessibility/OCRService.swift` — Apple Vision wrapper, returns cleaned text + bounding boxes
- New: `Sources/Services/Accessibility/ReadingProfile.swift` — level 1-5 + preferred language (UserDefaults-backed)
- Touch: `Sources/Services/LLMService.swift` — four mode-specific prompts
- Touch: `Sources/Utils/Config.swift` — `accessibilityModeEnabled` gate
- Touch: `NativeToolRegistry.init()` — register tool; add description to both LLMService and GeminiLiveSessionManager system prompts
- Touch: `project.pbxproj` — PBXBuildFile + PBXFileReference + group entry + Sources build phase

**Tool args:**
```
{
  "mode": "read" | "simplify" | "translate" | "define",
  "reading_level": 1-5,           // optional; default from ReadingProfile
  "target_language": "es"|"fr"|... // optional; default from ReadingProfile
}
```

**Mode prompts (adapted from brain):**
- `read` — clean OCR noise, preserve meaning, remove artifacts, output for audio. No markdown.
- `simplify` — rewrite at reading level N (1=child 6-10yo, 2=youth 11-14, 3=adult, 4=expert, 5=professional). Preserve meaning, vary vocabulary + sentence length.
- `translate` — convert to `target_language`. Preserve tone. Output target text only.
- `define` — plain-language definition + one usage example. <40 words total.

**Flow:**
1. OCR runs locally via Apple Vision (privacy-first; image never leaves device)
2. Clean text → LLMService with mode prompt
3. Response streams into TextToSpeechService
4. Reading level + language defaults come from `ReadingProfile`

---

## A2. Urgency-graded TTS (from neurobridge) — universal, not gated

**Files:**
- Touch only: `Sources/Services/TextToSpeechService.swift` — add `SpeechUrgency` enum alongside existing `SpeechEmotion`

**Urgency mapping (verbatim from neurobridge):**
| Urgency | Rate multiplier | Prefix |
|---|---|---|
| `.low` | 1.0 | (none) |
| `.medium` | 1.15 | (none) |
| `.high` | 1.3 | `"Important: "` |

**Call sites to update:**
- `Sources/Services/ProactiveAlertService.swift` — pass urgency based on alert severity
- `Sources/Services/NativeTools/GeofenceTool.swift` — `.medium` on enter/exit, `.high` on errors
- Other tools that already speak critical info — opt-in via optional urgency param

---

## A3. Scene/Social Assistive Modes (from neurobridge)

**Files:**
- New: `Sources/Services/Accessibility/AssistiveModeService.swift` — pipeline orchestrator
- New: `Sources/Services/Accessibility/AssistiveRouter.swift` — keyword-based router → 60-token Claude fallback
- New: `Sources/Views/AssistiveModeToggleView.swift` — UI toggle in main bottom bar
- Touch: `Sources/App/OpenGlassesApp.swift` — gate normal LLM pipeline when assistive mode active

**Output schema (strict JSON, 150-token cap):**
```
{
  "advice": "string, <15 words, one sentence",
  "urgency": "low" | "medium" | "high",
  "followup": "string, <10 words, optional question"
}
```

**Scene mode prompt:** "You are an assistive AI for neurodivergent users. Provide calm, clear, grounded real-time support based on what the user sees. Respond only in valid JSON. One sentence under 15 words. Identify the most useful info proactively. Assign urgency."

**Social mode prompt:** "You are an assistive AI for neurodivergent users. Help the user understand the emotional state of the person they are looking at — calmly, concisely, in real time. Same JSON schema. Urgency: low=calm/positive, medium=unease, high=distress. If no person visible, suggest repositioning."

**Hooks:**
- A3 output `urgency` field drives A2 TTS rate/prefix automatically
- Router picks scene vs social: keywords (`person`, `face`, `emotion`, `conversation` → social; else scene). Real-mode fallback to 60-token Claude classify call.
- Default-to-proactive when no user transcription

---

## Build order

1. **A2** first — smallest, broadly useful even before IAP ships
2. **A1** second — most user-visible utility, clear value prop
3. **A3** third — most novel, gates behind IAP completion

## Open questions

- Bundle all three into one IAP, or sell A1 separately and A3 in a higher tier?
- Does A2 (urgency TTS) ship universally, or also gate behind IAP? *Recommendation: universal — it's a quality improvement, not an accessibility feature per se.*
- IAP product ID convention — match Medical Compliance per-region pricing pattern?
- Reading level UI — slider in Settings? Per-query override via voice ("simplify for a 10-year-old")?

## Dependencies / prereqs

- None for A2
- A1 needs Apple Vision OCR wired up (currently used in PrivacyFilterService for face detection — reuse pattern)
- A3 depends on A2 for urgency-rate behavior
