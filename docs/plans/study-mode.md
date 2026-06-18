# Plan — Study Mode (flashcards + quizzes from your documents)

**Status: 📋 Planned (not built).** Rides our **Document RAG** + OCR + on-device-LLM engines
(scan → summarize → decks of flashcards + quizzes).

**Strategic fit:** A consumer **active-recall study companion**. We already turn documents into
retrievable knowledge (Document RAG, [Plan O](O-document-rag.md)/[P](P-chunk-citations.md)) and read text
hands-free (OCR, A1); the net-new piece is the **learning loop** — generate **flashcards + quizzes** from
that content, organize into **decks**, and review **hands-free** (TTS reads the question, you answer by
voice). ~80% reuse; the only new logic is the deck/grade/spaced-repetition core. Works offline via the
Apple on-device provider.

**Effort:** ~3–4 days (the grader + spaced-repetition + content schema are the new pieces; everything
else is reuse).

---

## Concept

```
source: an existing Document RAG doc  ──┐
        OR a hands-free scan (glasses cam → OCR → text)  ──┘
   ▼
StudyContentBuilder: one structured LLM call → { summary, flashcards[], quiz[] }
   (multi-provider; Apple on-device for offline/private)
   ▼
StudyDeck (persisted) — flashcards (front/back) + quiz (MCQ) + deck-level summary
   ▼
review hands-free:
   • Flashcards — TTS reads the front; "flip" reveals the back; spaced-repetition orders the next card
   • Quiz — TTS reads the question + options; answer by voice ("option two"); score + review missed
   ▼
optional: PDF export (SessionExporter) · HUD shows the current card/question
```

- **Source** — reuse a chunked/embedded Document RAG document, **or** scan fresh material hands-free
  (glasses camera → `OCRService`).
- **Generate** — one structured call produces a summary (title + 1–3 sentences + 3–5 key points + doc
  type), **flashcards** (term/question → answer), and a **quiz** (N MCQs, one correct + distractors).
- **Organize** — content lives in **decks**; large decks get a **map-reduce deck summary**.
- **Review** — hands-free flashcards + quiz; **spaced repetition** resurfaces missed cards sooner.

---

## Files

```
Sources/Services/Study/
├── StudyModels.swift         // StudyDeck, Flashcard, QuizQuestion, ReviewRecord
├── StudyStore.swift          // persist decks/cards/scores + review history (injectable dir)
├── QuizGrader.swift          // PURE: answers → score / missed / percentage
├── SpacedRepetition.swift    // PURE: review history → next-review box/order (Leitner)
├── StudyContentBuilder.swift // prompt + response schema for {summary, flashcards, quiz}; parse + validate
├── StudyService.swift        // @MainActor: source (RAG/scan) → generate → store → review/quiz flow
└── NativeTools/StudyTool.swift // study: make_deck <doc> | quiz <deck> | review <deck> | scan
Sources/App/Views/
├── DeckListView.swift
├── FlashcardView.swift       // flip / swipe
└── QuizView.swift            // MCQ · score · review
```

Reuse (no new infrastructure):
- **Content source** — [SemanticMemoryStore](../../OpenGlasses/Sources/Services/SemanticMemoryStore.swift) / Document RAG (Plan O): the already-chunked document text.
- **Scanning** — `OCRService` (A1) + `CameraService` (glasses POV, iPhone fallback).
- **Generation** — [LLMService](../../OpenGlasses/Sources/Services/LLMService.swift) (multi-provider) incl. the **Apple on-device** provider for offline/private generation.
- **Hands-free review** — [TextToSpeechService](../../OpenGlasses/Sources/Services/TextToSpeechService.swift) reads cards/questions; voice answers via the wake-word/transcription path.
- **Export** — `SessionExporter` (flashcards/quiz → PDF, double-sided).
- **HUD** — [GlassesDisplayService](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift): current card/question on the lens.

---

## Deterministic core (the testable part)

```swift
/// PURE: grade a quiz attempt.
struct QuizGrader {
    func grade(_ quiz: [QuizQuestion], answers: [QuestionID: OptionID]) -> QuizResult
    // → score, percentage, missed: [QuizQuestion]
}

/// PURE: Leitner spaced repetition. A correct answer promotes the card a box (longer interval);
/// a miss demotes it to box 0 (resurfaces soonest). Ordering is by due-ness.
struct SpacedRepetition {
    func update(_ record: ReviewRecord, correct: Bool) -> ReviewRecord
    func dueOrder(_ cards: [Flashcard], now: TimeInterval) -> [Flashcard]   // clock injected
}
```

- **`QuizGrader`** — answers → score/percentage/missed. Pure.
- **`SpacedRepetition`** — Leitner box updates + due-ordering (clock injected) — the "active recall"
  value: misses resurface sooner, mastered cards space out. Pure, testable with synthetic histories.
- **`StudyContentBuilder`** — builds the prompt + **response schema** for `{summary, flashcards[],
  quiz[]}` and parses/validates (≥1 flashcard, each MCQ has **exactly one** correct option + ≥2 options,
  no empty fields). Parse/validate testable against fixture JSON; the LLM call is device/LLM-gated.
- **`StudyStore`** — persist/reload decks/cards/scores + history (injectable dir), testable.

---

## Tests (headless)

- **QuizGrader**: all-correct → 100 %; mixed → correct count + missed list; empty quiz handled.
- **SpacedRepetition**: a missed card lands in box 0 and sorts due-first; a correct card promotes a box
  and pushes its due time out; `dueOrder` is stable + clock-driven.
- **StudyContentBuilder parse**: fixture → `{summary, flashcards, quiz}`; rejects an MCQ with zero or
  multiple correct options or < 2 options; trims/validates fields.
- **StudyStore**: persist + reload decks/cards/scores; review history round-trips (temp dir).

---

## Deferred / risk

- **Generation quality** (good cards/distractors) is LLM-gated — validated on device, not headlessly.
- **Hands-free answer matching** — mapping spoken input to an option ("option two" / reading the answer)
  is a small heuristic (number + fuzzy text); the matcher is testable, but real STT accuracy is
  device-gated.
- **On-device generation** uses Apple Foundation Models, which are **foreground-only** (see
  [project_local_model_background]) — the offline path is foreground-only; cloud works backgrounded.
- **Scanner polish** — auto-capture / boundary-detection / perspective-correction is a nice
  OCR enhancement but largely device-gated; ship on the existing OCR path first, treat the scanner polish
  as a follow-up.

---

## Open questions / decisions

- **Spaced-repetition algorithm.** Leitner (boxes) vs SM-2. *Recommendation: Leitner — simple, fully
  deterministic, easy to test; SM-2 is a later refinement.*
- **Answer input.** Voice ("option two") vs tap. *Recommendation: number-based voice match + tap
  fallback; fuzzy text match is a stretch goal.*
- **Source.** Reuse a Document RAG doc vs always scan fresh. *Recommendation: both — `make_deck` from an
  existing RAG doc is the cheapest path; `scan` is the hands-free capture path.*

---

## Why this matters

It closes the loop on Document RAG: you already load a manual/textbook/PDF and *ask* about it — Study
Mode lets you *learn* it, hands-free, with flashcards + quizzes and real spaced repetition. A clean
consumer feature on engines already shipped (RAG, OCR, on-device LLM, TTS, PDF export), with a small,
well-tested core (grader + spaced-repetition + content schema) and the LLM/scan accuracy device-gated.
We already have ~80 % of the machinery.
