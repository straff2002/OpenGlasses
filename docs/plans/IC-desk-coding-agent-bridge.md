# Plan IC: Desk-Side Coding-Agent Bridge (the desk half of the agent harness)

**Status:** 📝 Drafted 2026-10-10. Nothing built. P0 is the bridge's pure core with recorded hook
fixtures; P1 its server, pairing and the phone's preset; P2 a live run. The bridge is a separate
program outside the iOS target.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 2, glasses
as a voice front end for desk coding agents; section 4 row "Desk-side coding-agent bridge"; section
5, "The Claude Code bridge phone half exists").
**Gate:** Agent Mode, unchanged. The phone side is the existing custom agent harness (Plan
[N](N-remote-agent-harness.md), Plan [FE](FE-agent-voice-reliability-and-feedback.md)), which is
already gated on `Config.agentModeEnabled`; this plan adds a preset to it and nothing outside it.
**Priority:** The phone half has been ready since FE shipped: questions with identity, typed
replies, approve and deny by voice or touch, cancel, replay, a spoken result. What is missing is
anything on the desk that turns a coding agent's own events into our
[wire contract](../agent-harness-wire-contract.md). Plan N already calls a self-hosted bridge "a
custom URL a power user can opt into" (`docs/plans/N-remote-agent-harness.md:138`); nobody has
written one.

---

## Why

A developer runs a coding agent in a terminal (Claude Code and the Codex CLI both expose hook
interfaces: a script runs before a tool call, when the agent needs permission, when it stops). They
step away from the desk. Today the agent waits at a permission prompt until they come back. With a
bridge, the glasses say "The agent wants to run the test suite. Allow?", the wearer says "yes", and
when the agent finishes the glasses say what it did in one sentence.

The phone already has every piece of that conversation. The desk has none.

## Scope

**In:** a small desk program that
- installs hooks **per run**, never in the user's global agent settings;
- turns permission requests into approval questions and multiple-choice prompts into choice
  questions (Plan [IA](IA-agent-choice-questions.md));
- answers the agent's hook with the wearer's decision;
- notices when a prompt was answered at the terminal instead and withdraws it from the phone;
- cancels by denying the next tool call;
- reports a terminal state with a one-sentence completion summary;
- pairs with the phone by QR code, with a pinned certificate, on private or tailnet addresses only.

On the phone: a "Desk agent" preset in the harness settings, a QR scan that fills it, and
certificate pinning for that preset's requests.

**Non-goals:**
- Starting new agent tasks from the glasses by default. The contract's start call exists; the
  bridge refuses it unless the developer has named a project directory and turned start on (open
  question 2). Answering, cancelling and hearing results need no start.
- Public reachability. Tunnels and public addresses are refused at bind time and at pairing.
- Any model call from the bridge. The summary is extracted, not generated (Design 5); the phone's
  narration (N) may rephrase it with the wearer's own model.
- Remote control of the desk beyond the agent run: no shell, no file access, no screen.
- A Windows build in the first cut.

## Design

### 1 · Shape

```
coding agent ──hooks (per run)──► bridge core ──► HTTP(S) server (wire contract) ◄── phone (custom harness preset)
                ◄─ hook replies ──┘     ▲
terminal answer ─────────────────────────┘ (settlement)
```

The developer starts the agent through the bridge (`agent-bridge run -- <agent command>`), which
writes a per-run hook configuration into a temporary directory, points the agent at it through the
agent's own per-invocation settings mechanism, and removes it when the run ends. If an agent offers
no per-run mechanism, the bridge says so and does not fall back to editing global settings.

### 2 · Core state (pure, P0)

`BridgeRun` holds the run id, status, the pending question (id, revision, kind, prompt, options),
the halt marker, and the summary. It is a reducer over two event streams:
- **Hook events** (recorded payloads in fixtures): `permissionRequested(tool, summary)`,
  `choiceRequested(prompt, options)`, `preToolUse(tool)`, `notification(text)`,
  `stopped(finalMessage)`, `sessionEnded`.
- **Phone and desk events:** `answerReceived(questionId, revision, decision, replyId)`,
  `cancelRequested`, `terminalAnswered(questionId)`, `phoneSeen(at:)`, `deskInput(at:)`.

Rules the tests state:
- **Routing to the glasses.** A permission or choice prompt is offered to the phone only when the
  desk has had no keyboard input for 90 s **and** the phone has polled in the last 15 s. Otherwise
  the terminal prompt stands alone and the phone sees nothing pending. (Open question 3 covers a
  manual "send to glasses" override.)
- **First answer wins.** A phone answer settles the hook; a terminal answer settles it too, bumps
  the question's state to resolved, and the next status `GET` reports the run running again, which
  FE's "the answer landed" reconciliation already understands. A phone answer arriving for a
  settled question gets the contract's stale refusal.
- **Choice compatibility.** For a choice question, `approve` and `deny` are not answers: the
  question stays pending (IA's contract rule). A test pins it.
- **Replies are idempotent** by `replyId`, as the contract requires.
- **Cancel.** `cancelRequested` sets the halt marker; the next `preToolUse` hook is answered with
  a denial and a message telling the agent to stop; the run reports `cancelled` once the agent
  stops. A tool already running is not killed: the contract's cancel is "no further actions", and
  the spoken copy says "I've asked it to stop after the current step."

### 3 · Wire contract conformance

The server implements the existing contract and nothing new beyond IA's choice additions: status
`GET` with question and result paths at their default names, answer `POST`, ack `POST`, cancel
`POST`, and start `POST` only when enabled. Payload limits, terminal semantics and the "endpoint's
words are untrusted data" rule apply unchanged; the bridge sanitises agent text to the contract's
plain-text limits before serving it. A conformance test replays the contract's own examples against
the server.

### 4 · Pairing and transport

- On first run the bridge creates a self-signed certificate and a random pairing token, stored in
  the user's config directory with owner-only permissions.
- It binds only to addresses in private ranges (10/8, 172.16/12, 192.168/16), the tailnet range
  100.64/10, IPv6 unique-local, or loopback for testing. A public address, or a configured name
  that resolves to one, is refused with a clear message. Tunnelling services are refused by the
  same rule: their addresses are public.
- `agent-bridge pair` prints a QR code carrying the URL, the certificate's SHA-256 fingerprint and
  the token. The phone's preset scan reads it, checks the host against the same private-range
  classification `URLFetchGuard` already applies (`Services/URLFetchGuard.swift`, including
  100.64/10), and stores token and fingerprint in the Keychain.
- **Pinning on the phone.** Requests for this preset go through a `URLSession` whose delegate
  accepts the server only if the leaf certificate's SHA-256 matches the stored fingerprint
  (pure `PinnedCertificatePolicy`, delegate as a thin edge). The review suggested reusing
  `Services/OfficeSync/OfficeCommissionTransport.swift`; on reading it, that pinned connection
  lives in Go in the opt-in office transport build only, so it is the pattern to follow, not code
  the standard build can call.

### 5 · Completion summary

On `stopped`, the bridge extracts one sentence: the first sentence of the agent's final message
that is not a greeting or a heading, at most 25 words, with code spans and paths reduced to their
last component. If none qualifies: "The agent has finished." The phone speaks it through FE's
result path, which already frames endpoint text as untrusted and bounds it.

### 6 · Phone half (small)

- `AgentHarnessPreset.deskBridge(url:token:)` beside `codexCloud` and `claudeRemote`
  (`Services/AgentHarness/Adapters/AgentHarnessPreset.swift`), mapping the bridge's default paths.
- A "Pair a desk agent" row in the agent harness settings that scans the QR code.
- `PinnedCertificatePolicy` and the session delegate.
- Nothing else changes: questions, replies, cancel, replay and narration are FE's.

## Phases

- **P0 (one PR): bridge core.** `BridgeRun` reducer, routing, settlement, halt marker, summary
  extraction, contract payload builders. **Tests:** fixture-driven (recorded hook payloads for each
  event), idle and phone-seen routing table, terminal-first settlement, stale phone answer, choice
  `approve` refused, duplicate `replyId`, halt marker denies exactly the next tool call, summary
  extraction cases.
- **P1 (one PR): server, pairing, phone preset.** HTTPS server, bind-address refusal, QR pairing,
  per-run hook installation and clean-up; on the phone the preset, QR scan and pinning.
  **Tests:** bridge server conformance against the contract examples; bind refusal for public
  addresses and public-resolving names; hook files removed after a run (including a killed run);
  phone `PinnedCertificatePolicyTests` (match, mismatch, missing fingerprint), preset mapping test,
  QR parsing test rejecting a public host. Phone gates: full suite and Release build green.
- **P2 (owed): live run.** A real coding-agent session at a desk, the developer away: a permission
  answered by voice, a choice answered by ordinal (with IA P1), a terminal answer withdrawing the
  phone's prompt, a cancel, and the completion sentence heard on the glasses; once over a home LAN
  and once over a tailnet.

## Open questions

1. **Where the bridge lives.** Options: a `tools/agent-bridge/` directory in this repository, or the
   private Avenkin Office repository. **Recommended: this repository.** The contract it implements
   is documented here, its conformance tests can run against the same fixtures as the phone's, it
   is developer tooling rather than a Field Assist product, and keeping it beside the phone half
   stops the two from drifting. The office repository would make sense only if the bridge were to
   ship inside the desktop office app's installer.
2. **Start from the glasses.** Off by default, and when on, limited to one named project directory
   and to the agent command the developer configured? Recommended yes to both.
3. **Manual "send to glasses now"** at the terminal before the 90 s idle elapses? Recommended: a
   bridge command, not a default.
4. **Language.** Go (a single binary for macOS and Linux desks; `Transport/` already uses Go for a
   pinned-TLS exchange) or Swift (macOS only, shares nothing with the app at runtime anyway).
   Recommended: Go.
5. **CI cost.** The repository is public partly for CI minutes; the bridge's tests are fast and
   should run only when `tools/agent-bridge/` changes.

## Dependencies

- **N** (🚧 Phases 1 to 3 shipped per the index; the plan file's Status line lags at "Phase 1 core
  shipped"): the harness and the custom adapter this preset fills.
- **FE** (✅): question identity, typed replies, the reply transport, terminal outcomes.
- **IA**: choice questions; IC P1's choice handling needs IA P0's contract.
- **BK** P0 and **BN** P1 (shipped): the Agent Mode gate and the consent surface, unchanged.
