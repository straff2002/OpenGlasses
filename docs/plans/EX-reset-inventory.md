# EX — Conversation Reset Inventory

Who owns the context a "new topic" has to retire, what the supported reset is, and what — if
anything — says it worked. Recorded before the coordinator was designed, because the shape of the
outcome enum falls straight out of the last column: two of the six owners cannot confirm anything,
and one of those cannot even be reached from a headless test.

| Mode | Context owner | Where it lives | Reset API | Completion signal | Outcome it can report |
|---|---|---|---|---|---|
| Direct / cloud | `LLMService.conversationHistory` | Phone | `requestHistoryClear()` → `clearHistory()` | The array is empty; every request body is built from it | `completed` |
| Local / offline | `LLMService.conversationHistory` (same array) | Phone | as above | as above | `completed` |
| Gemini Live | The live session, plus `GeminiLiveService.resumptionHandle` | Server-side, for the life of the session | `GeminiLiveSessionManager.stopSession()` → `startSession()`; the teardown nils the handle and advances the connection generation | `isActive` back up, `hasResumptionHandle == false` | `completed` / `failed` |
| OpenAI Realtime | Conversation items in the session | Server-side | `stopSession()` → `startSession()` (see note) | `isActive` back up | `completed` / `failed` |
| Gateway agent | The session addressed by `sessionKey` | Gateway | `OpenClawBridge.resetSession()` — persisted, monotonic key rotation | The key changed; every later request carries the new one | `completed` / `failed` |
| Agent bridge | The bridge's own conversation memory | The wearer's network | `sendSessionReset()` → `{"type":"new_session"}` | **None.** The protocol has a `session_reset` message but nothing correlates it to a request, and a bridge is free never to send one | `issuedUnverified` / `failed` |

## Notes

**OpenAI Realtime — why a fresh session and not a clear.** The Realtime API deletes conversation
items one id at a time; there is no bulk clear. Deleting them all would mean retaining the id of
every item the session has ever created, which this client does not do — so "delete them all" is
not a reset that could be carried out here, let alone verified. Reconnecting is: a new session
starts with an empty server-side conversation, and this transport has no session resumption, so
nothing survives the teardown. That is the choice, and it is why the adapter for both realtime
backends is one type.

**Why `issuedUnverified` exists.** Collapsing the bridge into `completed` would report a guess as a
fact; collapsing it into `failed` would refuse to reset a backend that is simply quiet, and strand
the wearer in a conversation they asked to leave. It is its own outcome, it crosses the boundary,
and it downgrades the spoken confirmation — the wearer is told the bridge was asked and does not
confirm resets.

**What is deliberately not reset.** Persistent notes, memories, settings and historical saved
threads are untouched: this retires the *current* context. Explicit long-term recall can still
retrieve a saved memory afterwards, which is the point of saving it. The remote agent session
(`AgentSessionService`) is a task runner, not conversation context, and is left alone.

**Ordering.** The gateway's key rotation has to come after any tool result the current turn still
owes the model — rotating mid-run would post the tool's answer to a session that no longer exists.
The same barrier protects the phone's history: the on-device turn appends its exchange at the end
of the turn, so a clear that landed mid-turn would leave the "reset" conversation holding the very
turn it was meant to discard.
