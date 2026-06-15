# Plan T — Offline Field Queue & Store-and-Forward Sync

**Source pattern:** The offline edge-runtime / store-and-forward idea from our idea-source repo `~/Code/qaeros` (`plans/369` edge runtime — boot manifest + local store + reconnect reconciliation). Concept only; clean-room Swift sized down to a single-user device.

**Strategic fit:** Unblocks real field deployment. Field Assist ([Plan F](F-field-assist.md)) is shipped through Phase 3, but its own open questions flag offline as unresolved ("queue with explicit *offline mode active* indicator; flush on reconnect" — [F open questions](F-field-assist.md)). Field work happens in plant rooms, basements, and rural sites with no signal. Today a session's vault is on-device but the LLM call, photo upload, and audit export assume connectivity, so a dropped connection mid-procedure loses or stalls work. This plan adds a durable local queue + a sync engine that flushes on reconnect, with conflict surfacing — turning Field Assist from a connected demo into something a technician can trust on site.

**Effort:** ~4–5 days.

---

## The gap (verified)

- `FieldSessionService` / `SessionLogger` ([Sources/Services/FieldAssist/](../../OpenGlasses/Sources/Services/FieldAssist/SessionLogger.swift)) log a session locally, and `SessionExporter`/`SessionExport` produce the audit JSON/PDF — but there is **no offline queue**: a step that needs the network (LLM grounding, photo durability, export upload) has no durable retry.
- `NativeToolRouter` returns a `.failure` when a remote call can't complete ([:61](../../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift)) — it does not enqueue for later.
- There is no reachability-driven flush, and no "you're offline" affordance for the technician.

---

## Files

```
Sources/Services/Offline/
├── OfflineQueue.swift          // durable FIFO of QueuedOp (sqlite-backed, append-only + tombstones)
├── QueuedOp.swift              // op model: kind, payload, sessionId, createdAt, attempts, state
├── SyncEngine.swift            // reachability-driven flush, backoff, conflict detection
├── Reachability.swift          // NWPathMonitor wrapper → @Published isOnline
└── ConflictResolver.swift      // last-writer + surfaced conflicts (vector-clock-lite)
```

- New: `Sources/App/Views/SyncStatusView.swift` — queue depth, last sync, per-op state, conflicts needing attention.
- Touch: [FieldSessionService.swift](../../OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift) — write step completions / photo refs / export requests through `OfflineQueue` instead of assuming immediate send.
- Touch: [SessionLogger.swift](../../OpenGlasses/Sources/Services/FieldAssist/SessionLogger.swift) — already append-only; mark each entry `synced: Bool`.
- Touch: `PhotoLogTool` — persist the photo to disk + enqueue an upload op; the caption/log entry is durable immediately, the upload is best-effort.
- Touch: `Sources/App/OpenGlassesApp.swift` — construct `SyncEngine`, subscribe to `Reachability`, flush on `isOnline` rising edge.

---

## Model

```swift
enum OpKind: String, Codable {
    case logEntry          // structured step/observation (durable, no remote needed — sync only)
    case photoUpload       // local file path → durable upload when online
    case llmGrounding      // a Q the tech asked offline; answer when back online (optional)
    case auditExport       // generate/upload the session export
}

enum OpState: String, Codable { case pending, inFlight, done, conflict, failed }

struct QueuedOp: Identifiable, Codable {
    let id: String
    let kind: OpKind
    let sessionId: String
    var payload: Data          // JSON; for photos, a file path + sidecar metadata
    let createdAt: Date        // device clock; used for ordering + conflict detection
    var attempts: Int
    var state: OpState
}
```

`OfflineQueue` is sqlite-backed (same storage family as `SemanticMemoryStore`), append-only with tombstones so it survives app kills. Everything the technician does on site lands in the queue **synchronously and locally first** — the network is always a background concern.

---

## Sync engine

```
Reachability.isOnline ──rising edge──▶ SyncEngine.flush()
                                          │ ordered by createdAt
                                          ▼
                          for each pending op: send → mark done
                              │ transient error → backoff (exp, capped), keep pending
                              │ server-side newer state → mark conflict
                              ▼
                      ConflictResolver: last-writer-wins by default;
                      surface "assigned 2 new tasks / version changed while offline"
```

- **Ordering:** strict FIFO by `createdAt` within a session, so a photo can't sync before the step it belongs to.
- **Backoff:** exponential with jitter, capped; `attempts` persisted so it survives restarts.
- **Conflict-lite:** keep a per-session version counter; if the server's counter advanced while offline, mark the op `conflict` and surface it rather than silently overwriting (the vector-clock idea, reduced to a single-user counter).
- **Idempotency:** each op carries its `id`; the receiving end dedups so a retry after a flaky ack is safe.

---

## UX (hands-free + glanceable)

- Reachability drop → one spoken line + persistent HUD chip: *"Offline — work is being saved and will sync when you're back online."* via `GlassesDisplayService.showNavigation` ([:128](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift)).
- Reconnect → spoken *"Back online. Syncing 6 items."* then *"Synced. 2 new tasks were assigned while you were offline."* if conflicts.
- `SyncStatusView` on the phone for the detail (queue depth, retries, conflicts).
- Procedures keep running fully offline (vault + `ProcedureRunner` are on-device); only the *grounding* answer for a free-form question may defer.

---

## Build order

1. `Reachability` (NWPathMonitor) + `@Published isOnline` + tests via injected path.
2. `QueuedOp` + `OfflineQueue` (sqlite, enqueue/peek/mark, restart-survival) + tests.
3. Route `SessionLogger` entries + `PhotoLogTool` photos through the queue (durable-first).
4. `SyncEngine.flush` with backoff + idempotency; wire to reachability rising edge.
5. `ConflictResolver` (version counter, last-writer, surfaced conflicts) + tests.
6. HUD/TTS offline+reconnect affordances; `SyncStatusView`.

---

## Tests
- `OfflineQueue` — enqueue/flush ordering, survives a simulated app kill (reopen from sqlite), tombstones.
- `SyncEngine` — flushes on rising edge only; transient error → retained + backoff; idempotent re-send.
- `ConflictResolver` — advanced server counter → `conflict` (not silent overwrite); no advance → done.
- Field integration — full procedure run offline → queued log + photos → reconnect → all `done`, audit export intact.

---

## Open questions / decisions needed
- **Offline LLM grounding:** queue the *question* for an online answer, or attempt on-device MLX immediately (no connectivity needed)? *Recommendation: try MLX first when present (instant, offline), queue for a stronger cloud answer only if the tech opts in — and note per the Local Model Background memory MLX can't run backgrounded, so foreground-only.*
- **Photo durability vs storage:** keep all captured photos until synced (disk pressure) or cap? *Recommendation: keep until `done`, then move to a capped cache; warn at a disk threshold.*
- **Sync target:** flush to the OpenClaw gateway, a customer endpoint, or just local export until a backend exists? *Recommendation: pluggable sink — local export is the v1 sink, gateway/customer endpoint slot in behind the same interface.*
- **Multi-device:** one technician, one phone in v1 — defer true multi-writer reconciliation. *Recommendation: single-writer assumption; document it.*

---

## Dependencies / prereqs
- [FieldSessionService.swift](../../OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift) + [SessionLogger.swift](../../OpenGlasses/Sources/Services/FieldAssist/SessionLogger.swift) + `SessionExporter` (existing) — the session + audit pipeline this makes durable.
- `PhotoLogTool` (existing) — the highest-value op to make offline-safe (evidence capture).
- `SemanticMemoryStore` sqlite pattern (existing) — storage prior art.
- [GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift) (existing) — offline/reconnect HUD affordances.
- Pairs with **[Plan U](U-structured-capture-flows.md)**: structured capture steps are exactly what the queue persists; build T's queue under U's schema.

---

## Why this matters specifically for you
Field Assist is the highest-revenue line in the plan set, and "works without signal" is table stakes for a technician in a basement plant room — the absence of an offline queue is the single biggest gap between the current build and something a contractor will deploy. This is mostly plumbing over services you already have (`FieldSessionService`, `SessionLogger`, `PhotoLogTool`), so it's high-leverage: it makes the existing Field Assist resilient rather than adding a new surface.
