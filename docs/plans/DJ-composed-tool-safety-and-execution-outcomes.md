# Plan DJ — Composed-Tool Safety and Uncertain Execution Outcomes

**Status:** 🚧 All phases built, in review as a stacked series (2026-08-28): P0 #358 → P1 #361 →
P2 #362 → P3 #363. Every exit criterion is test-covered by the stack except the release-log
criterion, which P3 met at the execution boundary only — app-wide logging remains
[[DM-privacy-safe-production-logging]]'s scope.
**Origin:** 2026-08-26 adversarial review findings 1 (Critical) and 9 (Medium).
**Priority:** Release blocker for skill-pack `.tool` bindings; the timeout work is the same execution
boundary and should land immediately after the safety fix.

House style applies: deterministic, headless-testable core first; one PR per phase. This plan owns
the rule that **every action reaches the same authorization boundary exactly once**, including an
action composed by a skill pack, and that a timeout never falsely claims a side effect did not occur.

---

## Problem and verified path

`NativeToolRouter.handleToolCall` applies the high-impact actuation floor (two build-mode halves:
`HighImpactToolPolicy` when Agent Mode is off, the `SafetySupervisor` when it is on — together they
cover both settings), confirmation, MCP egress checks, progress reporting, and timeout handling
before dispatch. A skill-pack action registered as `pack_*` passes those checks under the wrapper's
harmless name: `HighImpactToolPolicy` and `PromptInjectionPolicy.isHighImpact` match on the real tool
names and do not match `pack_*` strings. `SkillPackToolWrapper.execute`, however, resolves its `.tool`
target from the registry and calls `tool.execute(args:)` directly. The resolved target and bound
arguments therefore never pass through the router. `SkillPackValidator` constrains a `.tool` binding's
target only to "exists in the registry and is not itself a pack wrapper" — there is no high-impact
restriction, so a pack can wrap `smart_home`, `home_assistant`, `medical_export`, or another acting
tool and bypass the policy that would have applied to a direct call.

**The same bypass shape exists outside skill packs.** `NativeToolRegistry.executeTool(name:arguments:)`
is a raw lookup-and-execute with no safety checks, and it has callers that skip the router entirely:

- **Siri Actions (`.tool` binding) — same severity as the pack bypass.** `SiriActionDispatcher.run`
  lets a user-authored Siri Action bind **any** native tool name with arbitrary JSON args, executed
  via `IntentSupport.runTool` → `registry.executeTool`. The only admission gate,
  `SiriActionCatalog.isEligible`/`validate`, filters on `blockedToolNames`, which is populated solely
  from `Config.hipaaDisabledTools` — not the high-impact set. A Siri Action bound to `smart_home`
  with `{"action":"unlock"}` runs with no confirmation at all, while the identical call through the
  LLM path always confirms.
- **Tier-0 direct dispatch** in `OpenGlassesApp` also calls `registry.executeTool`, but is fed only by
  `ConversationClassifier`'s fixed read-mostly allowlist (datetime, weather, flashlight, …). Low risk
  today; it must still migrate to the router entry point so the allowlist is not the only defense.

The same router currently races execution against a timer. When the timer wins it returns a normal
failure while explicitly allowing non-cooperative work to finish later. A model or user can retry the
reported failure and duplicate a physical or external side effect.

Relevant seams:

- `OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift`
- `OpenGlasses/Sources/Services/NativeTools/SkillPackToolWrapper.swift`
- `OpenGlasses/Sources/Services/SkillPacks/SkillPackValidator.swift`
- `OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift` — `executeTool(name:arguments:)`
  is the unguarded direct-execute entry point every bypass reaches
- `OpenGlasses/Sources/App/Intents/IntentSupport.swift` + `SiriActionDispatcher`/`SiriActionCatalog`
  (the Siri Action `.tool` binding path) and the Tier-0 `registry.executeTool` call in `OpenGlassesApp`
- `OpenGlassesTests/SkillPackTests.swift`
- router, safety-gate, and tool-loop tests under `OpenGlassesTests/`

## Security invariants

1. The router is the only authority allowed to dispatch an acting native tool.
2. Safety is evaluated against the **resolved target name and final merged arguments**, never only
   against a wrapper, alias, or pre-substitution template.
3. Provenance is additive: a child call retains the model invocation, pack id/action, parent call id,
   and resolved target. No layer may replace its caller's identity.
4. One user approval authorizes one immutable resolved action. Any post-approval mutation forces a
   new evaluation and approval.
5. Pack-to-pack recursion remains forbidden; a hard maximum composition depth protects future
   aliases and procedures.
6. A timed-out side-effecting operation is `outcomeUnknown`, not `failed`, until an authoritative
   completion or reconciliation result exists.
7. Automatic retries reuse an idempotency key or do not occur. The model is never asked to infer
   whether retry is safe from prose.

---

## P0 — Fail closed before refactoring 🔴

Ship a small containment PR first.

1. Extend `SkillPackValidator` to reject new `.tool` bindings whose resolved target is classified as
   high-impact or side-effecting until P1 is present. Do not maintain a second handwritten tool list:
   query the same metadata/policy used by the router.
2. On launch and after pack refresh, quarantine already-installed actions that violate that rule.
   Keep the pack installed, disable only the affected actions, and show an explicit remediation
   reason in the pack UI.
3. Add a router assertion/diagnostic when a `SkillPackToolWrapper` is about to execute a `.tool`
   binding in a build without composed routing. The release behavior remains refusal, not warning.
4. Apply the same target classification to the **Siri Action `.tool` binding**: `SiriActionCatalog`
   must reject or refuse to execute a Siri Action bound to a high-impact/side-effecting target, using
   the same policy query as item 1, not the HIPAA-only `blockedToolNames` set it checks today. This is
   the same bypass as the pack wrapper — user-authored composition reaching `registry.executeTool`
   directly — and must fail closed in the same PR, or the containment is incomplete.

**Tests.** A pack wrapping `smart_home`, `home_assistant`, and `medical_export` is rejected or its
action is quarantined; a Siri Action bound to `smart_home`/`unlock` is refused execution; a prompt-only
pack and a read-only native binding remain usable; an installed legacy pack is deterministically
reclassified on launch.

**Rollback.** A remotely configurable kill switch may disable all `.tool` bindings while leaving
prompt bindings available. Do not roll back by re-enabling direct execution.

## P1 — Route child calls through one execution authority 🔴

Introduce a pure invocation model and make composition explicit.

```swift
struct ToolInvocationContext: Sendable, Equatable {
    let invocationID: String
    let rootInvocationID: String
    let origin: Origin          // model, user, skillPack, procedure, internal
    let parent: ParentCall?
    let depth: Int
}

struct ResolvedToolCall: Sendable {
    let name: String
    let arguments: ToolArguments
    let context: ToolInvocationContext
}
```

The exact types may follow existing `ToolInvocation`, but dictionaries crossing task boundaries must
be made `Sendable` rather than hidden behind unchecked annotations.

1. Add a context-taking router entry point. Preserve the current signature as a thin root-call
   adapter so provider integrations do not all change in one PR.
2. Replace `SkillPackToolWrapper.resolveNativeTool` with an injected child dispatcher. The wrapper
   performs only template substitution and type coercion, then asks the router to execute the target
   with a child context naming the pack and parent invocation.
3. Resolve the full child call before any safety decision. Run the high-impact floor and
   `SafetySupervisor` on `target + mergedArgs`; confirmation copy must name the real action and note
   the originating pack.
4. Split policy evaluation from dispatch into a pure `ToolAuthorizationPolicy` so tests can assert
   decisions without executing tools or touching global `Config`.
5. Refuse a child target beginning `pack_`, any parent cycle, and depth above 4. Record a content-free
   security event containing hashed invocation/pack ids and the policy verdict.
6. Ensure progress callbacks and `turnToolNames` record both the presented pack action and resolved
   native target without double-counting the user-visible turn.
7. Route the other direct-execute callers through the same authority so no acting path skips it:
   `IntentSupport.runTool` (Siri Actions) supplies a `user`/`siriAction` origin context, and the
   Tier-0 `registry.executeTool` fast path either routes through the authority or is provably confined
   to its read-only classifier allowlist by a test that fails if a non-read-only tool reaches it.
   After this, `NativeToolRegistry.executeTool` should have no acting caller that bypasses policy.

**Tests.** A high-impact wrapped tool requests the same confirmation as a direct call with the final
bound arguments; decline means its fake executor is never invoked; approval invokes it once; Agent
Mode rules still block/confirm; missing confirmation UI fails closed; read-only wrappers work;
pack-to-pack, cycle, and depth-limit cases fail; provenance survives nested dispatch.

## P2 — Classify tool effects and results 🟠

Add explicit execution semantics to every registered tool:

- `effect`: `.readOnly`, `.localMutation`, `.externalMutation`, `.physicalActuation`.
- `cancellation`: `.cooperative`, `.bestEffort`, `.notCancellable`.
- `idempotency`: `.intrinsic`, `.keyed`, `.none`.
- `timeoutPolicy`: finite for reads; operation-specific for side effects, never a generic claim of
  non-execution.

Replace the success/failure-only path at the router boundary with a typed outcome:

- `completed(value)` — authoritative success.
- `rejected(reason)` — policy prevented execution; safe not to retry automatically.
- `failedBeforeExecution(reason)` — authoritative no side effect.
- `outcomeUnknown(operationID, message)` — execution began and may still land.

Provider wire adapters can still serialize these to tool-result text, but the tool-loop driver must
also receive the machine-readable retry disposition. For `outcomeUnknown`, tell the model not to
retry and surface a concise “status unknown; checking” state to the user.

**Migration rule.** An unclassified tool defaults to the most conservative combination:
`externalMutation + notCancellable + no idempotency`. CI fails when a newly registered tool relies on
that default so the debt cannot silently grow.

## P3 — Operation journal and idempotency 🟠

1. Create an `OperationJournal` protocol with a protected on-device implementation. Persist
   operation id, tool name, provenance hashes, effect class, start time, idempotency key, and state;
   never persist raw arguments or results.
2. Derive a stable key from the root invocation id plus the resolved child path. A repeated provider
   delivery of the same tool call returns the existing outcome instead of executing twice.
3. Pass idempotency keys to adapters that support them. For adapters without support, serialize by
   logical resource where possible and require an explicit reconciliation query before offering a
   manual retry.
4. When a timeout wins, mark `outcomeUnknown`, request cooperative cancellation, and let a late
   completion atomically update the journal. Do not append a second conversational success after the
   turn has moved on; update operation status UI/diagnostics instead.
5. Recover `started` records after process death as `outcomeUnknown` and reconcile tools that expose a
   status API. Never silently convert them to failed.
6. Retain only the minimum content-free audit window and protect it with
   `NSFileProtectionCompleteUntilFirstUserAuthentication` or stronger.

**Tests.** Timer-wins/late-success, timer-wins/late-failure, duplicate invocation id, app-relaunch
recovery, keyed adapter replay, non-idempotent no-retry, cancellation before dispatch, and journal
retention. Use a controllable clock and continuations; no wall-clock sleeps.

---

## Delivery, verification, and exit criteria

Recommended order: P0 immediately → P1 → P2 → P3. P1 is the condition for lifting P0's quarantine;
P2/P3 can then roll out per tool family, with physical-actuation tools last.

The plan is complete when:

- no skill-pack code, Siri Action, or other composition can obtain and directly execute an acting
  native tool instance without passing the router's authorization boundary;
- every composed high-impact action is blocked or confirmed using its resolved arguments;
- safety tests cover direct, wrapped, and Siri-Action-bound calls with identical verdicts;
- a timed-out side-effecting call produces `outcomeUnknown` and cannot be automatically retried;
- duplicate invocation ids execute at most once across a process restart;
- release logs contain no raw arguments, results, pack templates, or operation payloads; and
- the full unit suite and a Release build are green.

Dependencies: coordinate P3's protected journal with [[DK-protected-conversation-recall-index]] and
use [[DM-privacy-safe-production-logging]] for security events. No dependency is allowed to delay P0.
