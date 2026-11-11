# Plan LL — Always-On: a Home Agent Beside the Phone (the tier JO left for later)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) are recommendations and
are still open.
**Track:** Everyday assistant. Agent Mode only.
**Builds on:** `OpenClawEventClient` (the gateway's `heartbeat`/`cron` events), Plan
[EH](EH-openclaw-2-0-wire-alignment.md) (the OpenClaw 2.0 wire; P1 built, P2 approvals planned), Plan
[BH](BH-gateway-remote-invoke.md) (`RemoteCommandParser`, `RemoteCommandPolicy`, `RemoteInvokeService`), Plan
[JP](JP-hermes-agent-api-server.md) (`HermesAgentAPIClient`, `HermesBridgeService`), Plan
[N](N-remote-agent-harness.md) (the harness), Plan [CR](CR-cloud-action-agent-gateway.md) (a provider-hosted
backend, drafted), Plan [BC](BC-unconditional-safety-gate.md) (`HighImpactToolPolicy`), Plan
[BN](BN-shared-consent-surface.md) (one consent surface), Plan [BZ](BZ-notification-digest.md),
`AgentNotificationQueue`.
**Serves:** Plan [JO](JO-watchers.md) §"Later: always-on", Plan [LJ](LJ-tell-me-when-its-for-sale.md) P3, Plan
[LK](LK-reading-mail-the-decision.md) options C and D, and the timed checks of
[LD](LD-home-cameras-through-home-assistant.md), [LE](LE-evening-check-in.md),
[LG](LG-reminders-on-a-rhythm.md) and [LH](LH-car-routines-with-home-assistant.md) where they need a fixed time.

---

## Trigger

An example list of routines a cloud personal agent runs, which the owner shared on 2026-11-11, is mostly things
that happen at a time, whatever the phone is doing: hourly camera checks, a nightly check at 9 p.m., a 7:30
departure, an alert every 30 minutes once a product lists, instant replies to buyers, mail sweeps. Plan JO says it
plainly: "an iOS app is not a server." Its §"Later: always-on" names the missing piece: "a process that is always
running and a way to wake the phone: the gateway or Avenkin Office running the same watcher kinds, and a push
sender (APNs entitlement + a server-held key)." This plan is that piece.

It is an **addition** to the phone tier, never a prerequisite. Every JO, LJ and LD watcher still works phone-only.

## Outcome

- Settings › Connections › Home Agent says which agent is connected (OpenClaw gateway, Hermes, or a hosted agent)
  and what it runs: "Checks the porch camera every hour. Watches for the luggage rack every 30 minutes."
- "Watch it at home" on any watcher hands its definition to the agent. The phone still lists it, and "stop
  watching" stops it in both places.
- A home finding arrives as a **typed result**, not free text. The phone checks it and delivers it under the same
  rules as its own findings (daily cap, quiet hours, digest, staleness). "Why did you tell me that?" names the
  watcher, the agent and the source.
- When the agent proposes something that would act on the phone, the glasses or the wearer's accounts through
  Avenkin, the phone asks, as it does now. A home agent never gets to unlock, send, call or buy on its own say-so
  through Avenkin.
- With the phone off or out of reach, results wait at the agent and arrive on reconnect, oldest dropped when
  stale. Whether a result can wake a locked phone is decision 2.

## What exists, and what doesn't (verified 2026-11-11 at main 2d936d2)

**Exists:**
- `OpenClawEventClient` (`Services/OpenClawEventClient.swift`): pairs and authenticates with the gateway,
  reconnects forever with jitter, and handles `heartbeat` (`status == "sent"`, `preview`, `silent`) and `cron`
  (`action == "finished"`, `summary` or `result`). Both are dropped before authentication. Both reach
  `onNotification` as a **string**.
- `triageOpenClawNotification(_:)` (`App/OpenGlassesApp.swift`): gated on `Config.isOpenClawAgentActive` (BK P0).
  It runs a **model turn** over the string (SUMMARY / CLARIFY / FIX / SKIP), and a summary is enqueued on
  `agentNotificationQueue`. Every gateway notification costs a model call and is free text the model rewrites.
- Remote invoke (BH, shipped): `type:"req"` frames on the same socket, `RemoteCommandParser` (total: command,
  unsupported, malformed), `RemoteCommandPolicy` (deny by default on `agentModeEnabled`, consent per class,
  capture off, rate limits), `RemoteCommandExecutor` (capture is confirm → announce → act through
  `ToolConfirmationCoordinator`), `RemoteInvokeService` with an audit ring.
- EH P1 aligned the client to OpenClaw 2.0. EH P2 (`exec.approval.requested` → the BN consent surface) is
  planned, not built.
- Hermes (JP, built): `HermesAgentAPIClient` (one `POST /v1/responses` per turn, chained) and
  `HermesBridgeService` over `HermesBridgeProtocol` (port 8765; `welcome`, `capturePhoto`, `response`,
  `audioStart`/`audioEnd`, `sessionReset`, `pong`, `error`). **Both are request-response. Hermes has no way to
  tell the phone something unprompted today.**
- Declared routes in `NetworkRouteRegistry`: `openClawGatewaySocket`, `openClawEventStream`,
  `openClawBridgeRequest`, `openClawSkillCatalog`, `hermesBridgeSession`, `hermesAgentAPI`.
- Delivery: `AgentNotificationQueue`, `NotificationDigestService`, `DigestSource` (`agent` among its cases),
  `NotificationPriority` (staleness: low 30 min, medium 2 h, high never).

**Doesn't exist:**
- Push. No `aps-environment` in `OpenGlasses.entitlements`, no `registerForRemoteNotifications`, no sender.
- Background refresh (no `BGTaskScheduler`). The gateway socket lives only while the process does.
- Any typed result from an agent, any watcher hand-off, and any record on the phone of what an agent runs.
- JO's watcher model itself (drafted, nothing built).
- A provider-hosted agent backend (CR drafted, nothing built).

**Avenkin Office is not this tier.** The public FX plan says the phone "retains queued work while Avenkin Office
is off, asleep, unreachable or behind a failed relay." Office is a desk app for jobs and manuals that can be asleep
at night. FX25's office assistant is drafted to read and draft, never to act.

## Design

### 1 · Who runs it

Three kinds of host, one contract:

| Host | Runs where | Holds | Phone channel today |
|---|---|---|---|
| OpenClaw gateway | the wearer's machine (LAN or tunnel) | the agent's own tools, schedules, credentials | event socket (`heartbeat`, `cron`, `req`) |
| Hermes Agent | the wearer's machine | the agent's own tools | request-response only |
| Provider-hosted agent | a model provider's managed-agents service, self-deployed (Plan CR) | a credential vault, MCP connections, scheduled runs | CR's reference backend speaks the OpenClaw event shapes |

**Self-hosted** costs the wearer a machine that stays on. **Provider-hosted** needs no home server, but the
provider holds whatever credentials the agent uses (a mail grant, for instance), bills the usage, and runs outside
the phone's safety gate.

**What the agent does at home is its own business.** A browser on the home network, mail access or a store
sign-in on the agent is the agent's capability and the wearer's risk. Avenkin's safety and privacy claims cover
what reaches the phone and what the phone does, and the Home Agent screen says so in one sentence.

### 2 · The contract: typed results (`avenkin.agent-result/1`)

A new payload the agent sends inside a `cron` event (`action: "finished"`) as an `avenkin` object beside
`summary`, so a gateway that knows nothing of it still delivers the summary:

```json
{
  "avenkin": {
    "format": "avenkin.agent-result/1",
    "watcherId": "uuid or null",
    "kind": "availability | deal | camera | mail | reminder | checkin | text",
    "fields": { "...": "typed per kind, bounded lengths" },
    "source": { "name": "Store A", "host": "store-a.example" },
    "observedAt": "2026-11-11T07:00:00Z",
    "ttlSeconds": 7200,
    "priority": "low | medium | high",
    "fingerprint": "string ≤ 128"
  }
}
```

- `AgentResultDecoder` (pure, strict): unknown `format` → falls back to today's text path; a known format with a
  bad field → **dropped and logged as malformed**, never repaired; strings length-capped; control characters
  refused; URLs must be `https`.
- `AgentResultMapper` (pure): a valid result becomes JO's `Finding` (for a watcher) or a digest item, worded by the
  kind's phraser from `fields`. **No model triage turn** for a typed result: the free-text `triageOpenClawNotification`
  path stays for untyped events only (decision 3).
- Kinds are added by the plans that need them: `availability`/`deal` (LJ), `camera` (LD), `mail` (LK C1),
  `checkin` (LE), `reminder` (LG). P0 ships `text` (one line, phrased as "From your home agent: …") and the
  framework.
- Typed results are untrusted output: phrased from fields, never instructions. A `fields` value that looks like
  an instruction is just text.

### 3 · Handing a watcher to the agent

- `AgentWatchHandoff`: the phone sends a watcher's definition (JO `Watcher` JSON plus a requested cadence) to the
  agent as an ordinary agent request (OpenClaw `sessions.send`, a Hermes turn) carrying a fixed instruction and the
  JSON. The agent sets up its own schedule however it does that. The phone records the hand-off with the agent's
  acknowledgement.
- The phone stays the owner: listing reads the phone's store; stopping sends a stop and marks it stopped
  locally whether or not the agent answered. A result for a stopped watcher is dropped.
- A reference skill for OpenClaw and a short script for Hermes ship under `docs/gateway/` as references, following
  CR P3's precedent. They are not app code.

### 4 · Waking the phone

Options, in order of cost:

1. **No wake.** Results queue at the agent and arrive when the app is next alive and connected. Delivery applies
   the TTL, so a stale finding is dropped. This costs nothing and is honest about the limit.
2. **The agent's own channel.** The agent already reaches the wearer some other way (a chat app, a text). The
   urgent alert goes there. Avenkin's copy of the result arrives later as option 1. Avenkin builds nothing.
3. **Push through APNs.** Needs the `aps-environment` entitlement, the phone sending its device token to the
   agent, and an APNs signing key. **That key belongs to the app's developer account.** It can't be handed to
   every wearer's home agent, so push would need a relay run by the developer, holding the key and accepting
   requests from agents. That is a hosted service, which FX's posture (no paid server) argues against. It is the
   only way to wake a locked phone from outside.

Recommendation: 1 and 2 in v1, 3 only by a later decision (decision 2).

### 5 · What the phone still decides

- Anything an agent asks the phone to do arrives as a BH remote command or an EH P2 approval, and goes through
  `RemoteCommandPolicy`, `HighImpactToolPolicy` and the BN consent surface. Nothing in this plan widens BH's
  command list.
- IX's rule holds: no standing grant for high-impact actions. A home agent can't earn the right to unlock,
  disarm, send, call or buy through Avenkin.
- Agent Mode gates the whole tier (BK P0). With Agent Mode off, no hand-off is sent and typed results are not
  delivered.
- Medical and Local Only: hand-off is refused in Local Only (a watcher definition would leave the phone), and
  `MedicalEgressCoordinator`'s rules apply to anything the hand-off would carry.

### 6 · Hermes needs a way to speak first

Hermes's two doors are request-response. Two options: the phone asks "anything new?" on connect and on each
foreground (`GET`-style poll as a Hermes turn with a fixed instruction, results as typed JSON in the reply); or
the bridge script gains a `result` message type pushed on the open socket. The first works with today's Hermes
and costs a model turn on the agent per poll. The second needs a bridge change outside this repository.
Decision 4.

## Phases (one PR each)

### P0 — the contract (headless)

- `AgentResult` and its kinds (`text` only, plus the extension point), `AgentResultDecoder` (strict),
  `AgentResultMapper`, the `text` phraser, the length and URL rules.
- **Exit tests:** fixtures for a valid result, an unknown format (falls back), a known format with a bad field
  (dropped), an over-long field, a non-HTTPS URL, a control character, a stale result (dropped on arrival), and a
  result whose `fields` reads like an instruction (phrased as text).

### P1 — typed results on the OpenClaw path (headless, wired)

- `OpenClawEventClient.handleCronEvent` passes the `avenkin` object through; typed results skip the triage turn
  and go to `agentNotificationQueue` / the digest under the mapped priority; the Home Agent screen lists recent
  results. Agent Mode gate unchanged.
- Tests: a typed `cron` frame reaches the digest without a model call; an untyped one still triages; pre-auth
  frames still dropped.

### P2 — watcher hand-off (headless, wired)

Depends on JO P0.
- `AgentWatchHandoff`, the "Watch it at home" action, stop in both places, dropping results for stopped
  watchers, the reference OpenClaw skill and Hermes script under `docs/gateway/`.

### P3 — Hermes

- Decision 4's route: poll on connect and foreground, or the bridge `result` message.

### P4 — provider-hosted

Depends on CR's reference backend.
- The same contract from CR's backend. The Home Agent screen names the provider and what it holds.

### P5 — device pass (owed)

- A real OpenClaw gateway on a home machine running one LJ watch every 30 minutes and one LD camera check hourly,
  for a week. Count results delivered, results dropped as stale, and time from finding to the wearer hearing it,
  with the phone in a pocket, at home and away.

## Decisions for Greig (open)

Recommendations first.

1. **OpenClaw first**, because its event socket already exists; Hermes second; provider-hosted after CR.
2. **No APNs in v1.** Results wait for the app, and urgent alerts use the agent's own channel. A developer-run
   push relay is a separate decision about running a service.
3. **Typed results skip the model triage**, phrased from fields. Untyped events keep today's path.
4. **Hermes polls on connect and foreground** until a bridge `result` message exists.
5. **Avenkin Office is not the always-on host.** It sleeps, and FX25 keeps it from acting.
6. **The phone owns every handed-off watcher.** Stopping on the phone wins, even if the agent never answers.

## Risks

- **A compromised agent can put words in the wearer's ear.** It already can through `heartbeat`. Typed results
  narrow that: authenticated socket, strict decoding, bounded fields, the daily cap, and no actions without the
  phone's confirmation.
- **Two schedulers disagree.** The phone's store is authoritative and results for unknown watchers are dropped.
- **Expectations.** A wearer may think "always-on" means the phone wakes. The Home Agent screen says when it
  does and doesn't.
- **Provider-hosted cost and custody.** The provider holds the credentials and bills the usage. The screen says
  so before the wearer connects one.

## Out of scope

A hosted multi-tenant service, running watchers on Avenkin Office, a push relay (decision 2), widening BH's
remote commands, and anything the agent does that doesn't come back through the contract.
