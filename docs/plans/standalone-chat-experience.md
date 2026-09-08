# Plan AK — Standalone Chat Experience (use OpenGlasses without the glasses)

**Status: ✅ Phases 1–3 shipped on main (`b7bdacf`), hardened by BM P9.** First-class **Chat tab**
(replaces History) with a live `ChatThreadView` + docked `ChatComposer` (extracted from the
Voice-tab bar); **rich rendering** via the pure `MarkdownBlockParser` (8 unit tests) +
`MessageContentView` (markdown + fenced code with copy) + coral-tinted shared `MessageBubble`;
and **token streaming** for the on-device provider (`AppState.streamingTurn` →
`LLMService.sendMessage(onToken:)` → `LocalLLMService.generate(onToken:)` → live `StreamingBubble`).
Debug build green; full suite passing. **Phase 2 also built:** per-message **Copy / Edit &
resend / Regenerate** (`ConversationStore.truncate(from:in:)` + bubble context menu); **document
attach** in the composer (`.fileImporter` → PDFKit/text extraction → `DocumentStore.ingest`,
grounded by the existing RAG tool); **inline model / persona switch** from the thread's overflow
menu (with history reload on dismiss). **Phase 3 (cloud streaming) built:** real SSE token
streaming for Anthropic + OpenAI-compatible, gated behind `onToken` (non-chat callers keep the
buffered path byte-for-byte) — the streaming helpers reconstruct the same `message`/`content`
shape so the existing tool loop is reused. ⚠️ Compile-verified only.

**Re-scoped 2026-07-10 (review; fixes shipped as Plan BM P9, `83507f2`, [#202](https://github.com/straff2002/OpenGlasses/pull/202)):** "needs real keys + device" was
too pessimistic — both SSE helpers hardcode `URLSession.shared` (`LLMService.swift:1556/:1615`);
with an injected session (the `MockURLProtocol` pattern from `MCPTransportTests.swift:66-91`) the
verification became **headless fixture tests** (`LLMStreamingTests`); only a live-credential smoke
stays device-bound. The review also found two real defects the "unverified" label was hiding:
**mid-stream `error` events returning partial content as a successful turn**, and **every
tool-loop iteration streaming** with an accumulator that never reset, so bubbles could concatenate
intermediate+final text. Chat SSE also had none of the retry/classification voice got from
`RealtimeReconnect` (Plan BD) — a transient 429 threw straight to `errorMessage`. All three fixed in
BM P9, with headless regression coverage.

**Builds on:** the existing [`ChatInputBar`](../../OpenGlasses/Sources/App/Views/VoiceTab.swift) (text + photo attach, vision-gated), [`ConversationStore`](../../OpenGlasses/Sources/Services/ConversationStore.swift) (threads + messages, active-thread tracking, resume/replay), [`ConversationHistoryView`](../../OpenGlasses/Sources/App/Views/ConversationHistoryView.swift) (`MessageBubble` + thread list), [`MainView`](../../OpenGlasses/Sources/App/Views/MainView.swift) tab bar, and [`LLMService.sendMessage`](../../OpenGlasses/Sources/Services/LLMService.swift).

**Strategic goal:** make the **phone app stand on its own**. Today OpenGlasses is glasses-/voice-first; typing is a second-class affordance. We want people reaching for OpenGlasses as a daily-driver AI chat app even when the glasses are in a drawer — chat is the front door, glasses are the enhancement. This is a UI/UX play on top of an LLM/RAG/persona/tool backend that is already more capable than the front-end exposes.

**Effort:** ~4–6 days (Phase 1 MVP ~3 days; Phase 2 fast-follow ~2–3 days).

---

## What already exists (reuse, do not rebuild)

- **Composer:** `ChatInputBar` (VoiceTab.swift) already does text input, photo attach via `PhotosPicker` (gated on `Config.activeModel?.visionEnabled`), and dispatches through `appState.sendTextMessage(_:imageData:)`. Extract it into a shared component rather than rebuilding.
- **Persistence:** `ConversationStore` already models `ConversationMessage {id, role, content, imageAttached, timestamp}` and `ConversationThread {id, title, summary, messages, createdAt, updatedAt, mode, compressedSummary}`, with `@Published var activeThreadId`, `startThread(mode:)`, `appendMessage(role:content:imageAttached:)`, `endThread()`, `resumeThread(_:)`, `replayMessages(for:)`, `deleteThread(_:)`, biometric `isLocked`/`unlock()`.
- **Thread UI:** `ConversationDetailView` + `MessageBubble` already render a thread in a `ScrollView`/`LazyVStack`. We upgrade these in place rather than starting over.
- **Send path:** `AppState.sendTextMessage(_ text:imageData:speakResponse:)` already (1) starts a thread if none active, (2) appends the user message, (3) calls `llmService.sendMessage(...)`, (4) sets `appState.lastResponse`, (5) appends the assistant message, (6) optionally speaks. The `speakResponse:` parameter already exists (used by Siri intents) — typed chat will pass `false` by default.
- **Brand:** `AppAccent.aiCoral` and the `.glassEffect` capsule language are established; reuse them.

## The gap

1. **No chat home.** Root tabs are Voice / Modes / History / Settings. Typing on the Voice tab is a toggle (`showChatInput`) that pops up the composer, sends one message, then collapses back to the hero capsule. The live transcript is an ephemeral overlay (`TranscriptOverlay`), not a thread you live in.
2. **History is read-back, not chat.** `MessageBubble` renders `Text(message.content)` — **plain text, no markdown, no code blocks**. To continue a conversation you tap **Resume**, which bounces you back to the Voice tab. The user bubble uses `Color.blue` — off the coral brand accent.
3. **No streaming into the thread.** Direct mode is request/response: `LLMService.sendMessage(...) async throws -> String` returns a single string only after the whole tool loop completes, and `appState.lastResponse` updates once at the end. There is no token-by-token partial for typed chat (only the Gemini/OpenAI *realtime* sessions stream, via `session.aiTranscript`).

## New work — Phase 1 (MVP: tab + rich rendering + streaming)

**1. Promote chat to a first-class tab.**
In `MainView`, make **Chat** a top-level destination. Recommended: replace the **History** tab with **Chat**, where Chat *is* the thread list (the current `ConversationHistoryView`) → tapping a thread opens a live `ChatThreadView` you can type into; "＋" starts a new thread. This keeps four tabs (Voice / Chat / Modes / Settings) and folds history into the same surface it belongs to. (Alternative: keep History and add a 5th tab — see open questions.)

**2. `ChatThreadView` — a live, docked thread.**
`Sources/App/Views/Chat/ChatThreadView.swift`:
- `ScrollView` + `ScrollViewReader` over the selected thread's `messages` (observe `ConversationStore`), auto-scroll to bottom on new content and on keyboard show.
- Docked composer at the bottom = the extracted `ChatComposer` (from `ChatInputBar`).
- On send: set the thread active (`resumeThread` / `startThread`) and call `appState.sendTextMessage(text, imageData:, speakResponse: false)` — typed chat is silent by default, with a per-thread "speak replies" toggle in the nav bar for hands-free read-aloud.
- Empty state: a friendly first-run prompt + a few example chips (mirrors `ContentUnavailableView` already used in History).

**3. Rich message rendering (`MessageContentView`).**
Replace the plain `Text` in `MessageBubble` with a renderer that handles markdown + fenced code:
- A **pure** `MarkdownBlockParser` (`Sources/Utils/MarkdownBlockParser.swift`) that splits a message into ordered segments — `.prose(String)` and `.code(language:String?, body:String)` — by scanning for ```` ``` ```` fences. No I/O → table-driven unit tests (like `VaultValidator`/`DocumentChunker`).
- Prose segments render via `AttributedString(markdown:)` (inline bold/italic/links/inline-code).
- Code segments render in a monospaced, horizontally-scrollable card with a **copy** button and an optional language label.
- Switch user-bubble tint from `Color.blue` to `AppAccent.aiCoral.opacity(...)` for brand consistency; keep assistant on `secondarySystemGroupedBackground`.
- Keep the existing accessibility-label combine behaviour.

**4. Streaming into the bubble.**
Add an opt-in streaming path so the assistant bubble fills token-by-token:
- New `@Published var streamingTurn: StreamingTurn?` on `AppState`, where `StreamingTurn { threadId: String; text: String }`. `ChatThreadView` renders an in-flight assistant bubble from `streamingTurn` when its `threadId` matches; on completion the bubble is replaced by the persisted `ConversationMessage` (no duplication).
- Add an optional `onToken: ((String) -> Void)? = nil` parameter to `LLMService.sendMessage(...)` and thread it into the provider send functions. Implement incrementally by provider:
  - **OpenAI-compatible** (`sendOpenAICompatible`) and **Anthropic** (`sendAnthropic`): add `stream: true` + SSE delta parsing (the codebase already does SSE parsing for MCP — reuse `SSEEventParser` patterns).
  - **Local MLX** (`sendLocal`): mlx-swift-lm exposes a per-token generation callback — wire it straight through.
  - **Gemini / others**: if streaming isn't wired yet, fall back to the current single-shot return plus a brief reveal animation so the UX is consistent. **Foreground-only** for the local path (see [[project_local_model_background]] — Metal can't run backgrounded; guard it).
- Tool-call iterations: stream only the final assistant turn; during tool execution show the existing "thinking"/tool affordance, not partial tokens.

Phase 1 acceptance: a Chat tab where you can hold a typed, multi-turn conversation with markdown + code rendering and live streaming, fully usable with no glasses connected.

## New work — Phase 2 (fast-follow)

**5. Per-message actions.** Long-press / trailing menu on a bubble: **Copy** (`UIPasteboard`), **Regenerate** (drop last assistant message, re-send the last user message), **Edit & resend** (edit last user message, truncate the thread after it, resend). Needs small `ConversationStore` mutators: `removeLastAssistant(in:)`, `truncate(after messageId:in:)`.

**6. Document attachments → chat-over-docs.** Add a "📎 attach file" control to the composer → Files picker → extract text (PDFKit for text PDFs, `OCRService` for scans) → `DocumentStore.ingest(name:text:namespace:)` → the answer is grounded via the existing Document-RAG tool. Strong glasses-off use case ("summarize this PDF on the train"). Reuses Plan [O](O-document-rag.md); ties into Projects scoping ([projects-scoped-contexts.md](projects-scoped-contexts.md)).

**7. Inline model / persona switch.** Surface the existing `ModelPickerSheet` and `PersonaPickerSheet` from the `ChatThreadView` nav bar so switching model/persona never requires leaving the thread.

## Build order

1. Extract `ChatComposer` from `ChatInputBar` (no behaviour change) + tests that `sendTextMessage` still fires.
2. `MarkdownBlockParser` (pure) + unit tests; `MessageContentView` rendering; reskin `MessageBubble` to coral.
3. `ChatThreadView` (live thread + docked composer, non-streaming) wired into a new **Chat** tab in `MainView`.
4. Streaming substrate: `AppState.streamingTurn` + `onToken` on `LLMService.sendMessage` → OpenAI-compatible + local MLX first, then Anthropic; reveal-animation fallback elsewhere.
5. Phase 2: per-message actions → doc attachments → inline switchers.
6. Full suite + **Release** build green before PR (see [[feedback_build_release]], [[feedback_plan_delivery_rhythm]]).

## Open questions

- **Replace History, or add a 5th tab?** *Recommendation: replace History with Chat* (Chat = list + live thread); History's read-back role is subsumed. Keep a 5th tab only if user testing wants the separation.
- **Default TTS in typed chat?** *Recommendation: silent by default* (`speakResponse: false`), with a per-thread "speak replies" toggle for hands-free. Voice-tab behaviour is unchanged.
- **Streaming + ConversationStore reconciliation.** The in-flight `streamingTurn` is render-only; the persisted assistant message is still appended once by `sendTextMessage` on completion. Ensure the bubble swaps cleanly (key by message id) with no flash/duplicate.
- **Provider streaming coverage.** Ship Phase 1 with OpenAI-compatible + local MLX streaming (highest-traffic paths) and a graceful reveal fallback for the rest; backfill per provider.
- **Voice tab vs Chat tab composer.** Keep both? *Recommendation: leave the Voice tab as-is (the `showChatInput` toggle stays for quick one-offs); the Chat tab is the place you live.*

## Dependencies

- `ConversationStore`, `ChatInputBar`, `LLMService`, `MainView`, `AppAccent` — all shipped. No new SPM packages. Streaming reuses existing SSE-parsing patterns; local streaming reuses mlx-swift-lm's token callback. Pairs with [projects-scoped-contexts.md](projects-scoped-contexts.md) (per-project threads) and [O-document-rag.md](O-document-rag.md) (doc attachments).
