# FC P3 — Memory-context inventory

Where wearer memory is retrieved, rendered, budgeted and sent on every route that can carry it;
what each route measured before this audit; and what it measures now. Line numbers are as of the
commit that added this file.

Nothing here changes retrieval: no ranking, no cap, no section, no query. The one behavioural
change is that the four ways a prompt can carry *no* memory are now distinguishable.

## The shared path

| Step | Where |
|---|---|
| Retrieve + render | `SemanticMemoryStore.render(query:)` — `OpenGlasses/Sources/Services/SemanticMemoryStore.swift:300`. Three sections (global, persona, gateway), each capped at `maxMemoryLines` = 8 entries, each value clamped to `maxValueChars` = 300. Global uses semantic search when a query is given *and* the embedder is available, otherwise the alphabetically sorted store. |
| Measure | `SemanticMemoryStore.renderedContext(query:enabled:now:)` — `…/SemanticMemoryStore.swift:274`. Returns the same text `systemPromptContext(query:)` returns, plus the `MemoryContextSnapshot` describing it. |
| Storage health | `SemanticMemoryStore.isStorageAvailable` — `…/SemanticMemoryStore.swift:76`, set at `…:595` when `sqlite3_open` fails. |
| Assemble per call | `AppState.memoryContextForPrompt(query:)` — `OpenGlasses/Sources/App/OpenGlassesApp.swift:906`. Applies the wearer's two switches (`userMemoryEnabled`, `userMemoryRetrievalEnabled`), records the snapshot, returns the text. |
| Record | `MemoryContextRecorder` — `OpenGlasses/Sources/Services/Diagnostics/MemoryContextRecorder.swift:25` (turn), `:37` (prompt clip), `:59` (live connect). |
| Carry | `TurnTimeline.memoryContext` — `OpenGlasses/Sources/Services/Diagnostics/TurnTimeline.swift:141`. |
| Show | `TurnLedger.debugExport(now:liveMemory:)` — `…/Diagnostics/TurnLedger.swift:188`, reached from Settings → Developer → Copy Diagnostics (`OpenGlasses/Sources/App/Views/TurnTimelineDebugView.swift:362`). And `PrivacyLog.memoryContext` — `OpenGlasses/Sources/Utils/PrivacyLog.swift:1463` — which the wearer's diagnostics export already carries, because that export is built from the `PrivacyLog` ring. |

## Routes

| Route | Retrieved at | Rendered into the prompt at | Budget / truncation on this route | Measured before | Measured now |
|---|---|---|---|---|---|
| Direct, full cloud prompt | `OpenGlassesApp.swift:3163, 3208, 3356, 3442, 4202, 4709, 4900` | `LLMService.memoryPromptBlock` — `LLMService.swift:388`, appended by `buildSystemPrompt` at `:546` | None. The block is appended verbatim; `compressContextWindowIfNeeded` (`LLMService.swift:1020`) compacts *history*, never the system prompt | Nothing. The prompt's own length was not recorded either | Availability, stored/retrieved/included, rendered characters, token estimate, entry cap, value clamps, `perTurn` |
| Direct, lean cloud tier (small-context providers) | same sites | `LLMService.leanCloudPrompt` — `LLMService.swift:328`, clip at `:371` | **Yes** — the block is clipped to `leanMemoryClipLimit` = 400 characters (`LLMService.swift:364`). The only budget-driven memory loss in the app | Nothing; the clip was an inline expression with no name and no record | The clip is measured at the clip and rewritten onto the turn's snapshot as `clippedForPromptBudget(droppedCharacters:)`, so the turn reports what the backend received |
| On-device (direct MLX and the runtime coordinator / GGUF) | same sites, plus the fast-tier agent path | `LLMService.leanOnDevicePrompt` — `LLMService.swift:315` → `buildSystemPrompt` → `memoryPromptBlock`; call sites `LLMService.swift:727, 3427, 3471` | None on the memory block. `LocalModelBudget` bounds the context window and the generation reserve; neither trims the assembled system prompt | Nothing | As the full prompt above |
| Gemini Live | — | — | — | Instruction length only (`PrivacyLog.realtimeSession(.gemini, .systemInstructionBuilt, characters:)`) | **`notInjected`**, stamped with the connect time and read back as `connectSnapshot(age:)` — `GeminiLiveSessionManager.swift:633`, dropped on stop at `:465` |
| OpenAI Realtime | — | — | — | Nothing | As Gemini Live — `OpenAIRealtimeSessionManager.swift:381`, dropped at `:325` |
| Agent scheduler (off-turn) | `AgentScheduler.swift:255` | full prompt, as Direct | None | Nothing | Same snapshot, emitted with `source=background`; `TurnRecorder.offTurn` keeps it off the wearer's turn |
| Notification digest (off-turn) | `AgentNotificationQueue.swift:229` | full prompt, as Direct | None | Nothing | As above |
| Prompt Inspector (preview, sends nothing) | `PromptInspectorView.swift:99` | rendered for display only | None | Character count of the section, on screen | Unchanged on screen; deliberately records no turn snapshot — a preview that recorded one would put a block on the ledger that no backend received |

## What the audit found

1. **The live backends carry no wearer memory at all.** Neither `GeminiLiveSessionManager.buildSystemInstruction`
   nor its OpenAI twin calls the memory store; their instructions carry the mode prefix, vision
   copy, tools, location, vault, visual state, project and reading contexts, and the injection
   policy. A comment at the Gemini connect site asserted the opposite ("the instruction embeds
   location, personas and memory context") and has been corrected. This is the likeliest source of
   a "it doesn't remember me" report, and it is a product gap for the memory owners
   (DX/EN/FA) to decide on — not something to fix inside a diagnostics pass.
2. **Four different absences shared one `nil`.** Disabled, empty, unreadable storage and
   clipped-for-budget were indistinguishable at every call site. They now differ at the source.
3. **Only one route can lose the block to a budget**, and it was unnamed: the lean cloud tier's
   400-character clip. Named, measured and recorded.
4. **The Direct and on-device tiers never drop or trim the memory block.** History compaction is a
   separate mechanism operating on `conversationHistory`.

## Follow-ups recorded, not fixed here

- **Alphabetical fallback selection.** When no query is passed (retrieval switched off, or an
  off-turn assembly) or the embedder is unavailable, the global section is `memories.sorted { $0.key < $1.key }.prefix(8)`
  (`SemanticMemoryStore.swift:332`). A wearer with more than eight saved facts then gets the same
  eight, keyed alphabetically, on every turn regardless of subject — and the embedder is
  unavailable more often than it looks. The new counters make this visible for the first time
  (`stored` far exceeding `included`, with `truncation=cappedEntries`), which is why it is recorded
  here rather than guessed at. Ranking is the memory owners' plan to change, not a diagnostics fix.
- **Persona memory is never semantically filtered** — it takes the alphabetical first eight even
  when a query is present (`SemanticMemoryStore.swift:342`). Same owners, same reason.
