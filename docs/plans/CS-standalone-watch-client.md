# Plan CS — Standalone Watch Client (the watch works with the phone out of range)

**Status:** 📝 Drafted (not scheduled), 2026-08-09
**Depends on:** Plan CR (a reachable endpoint for the direct path) — P1/P3 are independent of it
**Shape:** pure routing core first (P1), credential + transport (P2), UI (P3), device edge deferred (P4)

---

## The defect

Every control on the watch is a remote for the phone, and the remote has no batteries of its own.
[`WatchConnectivityService.sendCommand`](../../OpenGlassesWatch/WatchConnectivityService.swift)
opens with `guard WCSession.default.isReachable else { … }`, so the instant the phone is in another
room, in a bag on the far side of a workshop, or simply asleep past the WCSession timeout, all six
buttons in [`WatchMainView`](../../OpenGlassesWatch/WatchMainView.swift) stop working at once. There
is no local state, no transcript, and no answer path: the watch holds nothing but a reachability flag
and a set of command names.

For most of those commands that is *correct and unavoidable*. `photo`, `describe`, `capturePhoto`,
`toggleVideo` and `connect` all drive glasses hardware through the DAT SDK, which lives on the phone
and cannot be anywhere else — the phone is the only device paired to the glasses. Routing them
anywhere would be a lie.

But `ask` is not hardware. It is a question. A question needs a network and a model, both of which a
cellular or Wi-Fi-connected watch has independently of the phone. Today it fails identically to the
camera commands, and the user is given the same blank unreachable state for a request that could
plainly have been served.

The failure is also badly presented: reachability is a single boolean driving the whole screen, so the
user learns "the watch app is broken" rather than "your phone isn't nearby, and here's what still
works." Plan CQ P0 made exactly this distinction for glasses — *not connected* stays distinct from
*connected but limited* — and the same reasoning applies one device out.

## Non-goals

- **Glasses control without the phone.** Impossible, not deferred. Say so in the UI.
- **Realtime audio from the watch.** Tapping PCM and pushing it up a socket is a battery, thermal and
  latency dead end on a watch-sized power budget, and it duplicates a voice stack we have twice
  already. Dictation in, text and speech out.
- **A second conversation store.** The watch keeps a small local transcript for what *it* asked; it is
  not a mirror of the phone's `ConversationStore`, and it does not sync history back.
- **Independent glasses pairing, or a watch-side model.** Both are separate products.

---

## P1 — Pure core (headless, no wiring)

### `WatchCommandRoute`

A pure decision function, table-tested, and the whole point of the plan:

```
route(command:, phoneReachable:, directEndpointConfigured:, agentModeEnabled:)
    -> .viaPhone | .direct | .unavailable(Reason)
```

Rules, each with a reason it exists:

| Rule | Behaviour |
|---|---|
| Command needs glasses hardware (`photo`, `describe`, `capturePhoto`, `toggleVideo`, `connect`, `sleep`) | `.viaPhone` when reachable, else `.unavailable(.needsPhone)` — **never** `.direct`; there is no camera on the wrist and a fallback that pretends otherwise is worse than a disabled button |
| `ask`, phone reachable | `.viaPhone` — the phone has the personas, the vault, the tools, the frame; prefer it whenever it exists |
| `ask`, phone unreachable, endpoint configured | `.direct` |
| `ask`, phone unreachable, no endpoint | `.unavailable(.notConfigured)` — actionable, and the action is on the phone |
| Direct route, Agent Mode off | `.unavailable(.agentModeOff)` — the gate travels with the capability, per [`agentic_toggle`](../../CLAUDE.md) |

`Reason` is required, not optional. Following CQ P0: a greyed-out control with no stated cause is the
thing that reads as a broken app. Every `.unavailable` carries a one-line user-facing string.

### `WatchTranscript`

A bounded, persisted, `Codable` list of turns (role, text, timestamp, route). Bounded by count *and*
byte budget — watch storage is small and a runaway transcript is a support ticket nobody can diagnose.
Pure store, injected clock, no UI types. This is also the first local state the watch app has ever had,
so it is where "what did I ask it while I was away from my phone?" becomes answerable.

### `WatchEndpointConfig`

Endpoint URL + token identity, decoded from what the phone pushes down (below). Validation is pure:
reject non-HTTPS except on a LAN host, reject an empty token, and report *which* field is wrong —
because the user cannot see this screen while it is failing.

---

## P2 — Credential provisioning + direct transport

**Nobody types a token on a watch.** The phone already holds `openClawGatewayToken` in the Keychain
and already has an application-context channel to the watch. Provisioning is therefore: the phone
pushes endpoint + token to the watch over `updateApplicationContext` when a gateway is configured or
changes; the watch writes it to its own Keychain (never `UserDefaults`) and reports back a
non-sensitive fingerprint so the phone's settings screen can show "Watch: configured".

That path has a pleasant property — the watch can only ever be configured by a phone that was itself
configured, so there is no new trust decision and no new UI on the phone beyond a status line.

Transport is a small HTTPS client against the Plan CR cloud kind: send text, receive text. No socket,
no push channel, no remote invoke — the watch is a client, never a target. Deferred results are simply
not supported on the watch in v1: a task that does not answer inline reports "your phone will have
this when you're back in range", which is true, because the phone's ledger (CR P1) is the thing
holding it.

---

## P3 — UI

- The action grid gains an honest empty state: hardware controls disabled *with their reason*, `ask`
  still live when the direct route is available.
- A transcript view — the watch's first — showing the local turns with a small marker for which route
  served each. That marker is not decoration: "this answer didn't come from my phone" explains why it
  didn't know about the thing on the workbench.
- Input via the standard dictation/scribble text-input controller. Output as text, with speech through
  `AVSpeechSynthesizer` on the watch, respecting silent mode.
- The complication/widget entry point ([`WatchComplicationIntents`](../../OpenGlassesWatchWidget/WatchComplicationIntents.swift))
  re-routes through the same decision function, so a complication tap cannot bypass the rules.

---

## P4 — Deferred (device)

- The actual verification, which needs hardware and separation: a cellular watch, out of Bluetooth
  range, asking a question and getting an answer. Everything above is buildable and testable headless;
  this is the only part that is not.
- Battery cost of a direct round trip, measured rather than assumed.
- Behaviour on the reachability boundary — walking back into range mid-request should not double-send,
  and the route is decided once per request, not re-evaluated underneath it.

---

## Open questions

- **Should a direct answer be reconciled into the phone's conversation history on reconnect?** Cheap
  to do (the transcript is already `Codable` and the application-context channel is already there) and
  it would keep the phone's memory honest about what the wearer asked. The argument against is that it
  is a second write path into `ConversationStore` for a small number of turns. Leaning yes, as an
  append-only merge, but not in v1.
- **Does the direct path get a persona, or the default?** The phone's personas live in `Config` and are
  not on the watch. Simplest correct answer for v1 is the default persona and say so; pushing the
  active persona down the same application-context channel is a small follow-up.
- **Does HIPAA mode need to reach the watch?** If the phone is in a compliance mode that restricts
  egress, a watch talking directly to a cloud agent is a hole in exactly that boundary. The mode
  should ride the same push as the endpoint, and a restricted phone should push a *revocation*, not
  merely stop pushing — leaning that this is a P2 requirement, not an open question, and it is called
  out here so it is not discovered at review.
