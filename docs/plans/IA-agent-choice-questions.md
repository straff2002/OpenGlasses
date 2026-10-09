# Plan IA: Agent Choice Questions (answer "the second one" from the glasses)

**Status:** 📝 Drafted 2026-10-10. Nothing built. P0 is the contract and a pure parser; P1 is the
phone wiring (card, HUD, voice); P2 is a live check against the desk bridge of Plan
[IC](IC-desk-coding-agent-bridge.md).
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 4 row
"Multiple-choice agent questions, ordinal voice answers"; section 5 on the bridge's phone half).
**Gate:** Agent Mode. Every surface in this plan exists only when `Config.agentModeEnabled` is on,
as the rest of the remote agent harness is (Plan [N](N-remote-agent-harness.md), BK P0).
**Priority:** Coding agents increasingly ask "which of these?" rather than "may I?". Today such a
question reaches the wearer as a confirmation they cannot meaningfully answer, or as free text they
have to phrase.
**Surfaces:** `AgentQuestion`, the custom-harness status mapping, the answer request, the consent
card, the HUD, the voice consent path, and `docs/agent-harness-wire-contract.md`.

Evidence under `OpenGlasses/Sources/` unless noted; line numbers as recorded by the review at
`7a0cc0e0`, re-read on `main` at `48bcae0c`.

---

## Why

- `AgentQuestion.Kind` has two cases, `freeText` and `approval(actionSummary:)`
  (`Services/AgentHarness/AgentQuestion.swift:22-28`).
- The wire contract has no options (`docs/agent-harness-wire-contract.md:124-151`), and it reads
  **every unrecognised kind as a confirmation**, deliberately, so a confirmation can never quietly
  become a conversation.
- The voice path accepts at most three words and only approve or deny
  (`RemoteActionVoiceConsent.interpret`, `Services/RemoteActionConsent.swift:131-147`).

So an agent that offers "1. keep the old API, 2. migrate callers, 3. stop here" can only be heard,
not answered, from the glasses.

## Scope

**In:** a `choice` question kind with two to six options; an answer decision carrying the chosen
index; a pure parser for spoken answers by ordinal, number or the option's own words; touch rows
on the consent card; a HUD rendering; "later" leaving the question pending.

**Non-goals:**
- **"Always" answers** (remember this choice for future questions). A standing rule needs the
  consent gate's terms and version model (what exactly was agreed, for which agent, until when),
  which does not exist for agent questions. Deferred, recorded in Open questions.
- Multi-select.
- Choice questions from the OpenClaw harness. Its gateway event shape is Plan EH's; this plan
  covers the custom endpoint contract, which the desk bridge speaks.
- Letting the model answer. As today, a model turn can raise a prompt, never answer it.

## Design

### 1 · Contract additions (`docs/agent-harness-wire-contract.md`)

Question, in the status `GET`:

```jsonc
"question": {
  "id": "q8", "revision": 0, "kind": "choice",
  "prompt": "How should I handle the old API?",
  "options": [
    { "id": "keep",    "label": "Keep the old API" },
    { "id": "migrate", "label": "Migrate the callers" },
    { "id": "stop",    "label": "Stop here" }
  ]
}
```

- A new mappable path, **Question options path**, for endpoints that put options elsewhere.
- Two to six options; a label is plain text, at most 80 characters after sanitising; option ids
  are unique. Anything else makes the question malformed: it is shown as free text with the
  options read out, never guessed into a choice.
- Answer, in the answer `POST`: `"decision": "choice"`, `"choiceIndex": 1`, `"choiceId": "migrate"`,
  with `questionId`, `questionRevision` and `replyId` as today. `choiceIndex` and `choiceId` become
  reserved key names.

**Compatibility, stated in the contract.** A phone that predates this plan reads `choice` as a
confirmation (the existing rule) and can send only `approve` or `deny`. The contract therefore
requires an endpoint that asked a choice question to treat `approve` and `deny` as **not an
answer**: the question stays pending and the endpoint may say so in its status. The desk bridge
(Plan IC) does this, and its compatibility test pins it.

### 2 · Model

`AgentQuestion.Kind` gains `case choice(options: [AgentChoiceOption])`, with
`AgentChoiceOption { id: String; label: String }`. `isApproval` stays false for it. The custom
harness status mapping (`CustomHarnessConfig`'s `JSONPath` extraction) reads the options path and
validates as above. Identity rules are unchanged: a revision bump re-asks.

### 3 · `AgentChoiceParser` (pure)

```swift
enum AgentChoiceParser {
    enum Result: Equatable { case chosen(index: Int), later, cancel, askAgain, notAnAnswer }
    static func parse(_ utterance: String, options: [AgentChoiceOption]) -> Result
}
```

- **Ordinals and numbers:** "the first", "second one", "number three", "option 2", "two", "the
  last one". Out of range is `askAgain`.
- **Labels:** the utterance matches an option when it contains that option's distinctive words
  (words not shared with any other option, stop words removed) and no other option's. Two matches
  is `askAgain`, never the first.
- **Later:** "later", "not now", "skip", "remind me" leave the question pending and say "I'll leave
  that for now".
- **Cancel:** "cancel", "never mind" close the prompt without answering (the question stays
  pending at the endpoint, exactly as a dismissed approval does today).
- **"Yes" and "no" are not answers to a choice.** They return `askAgain` with the options read
  again; a yes must never pick the first option.
- Anything longer than about eight words that matches nothing is `notAnAnswer` and flows to the
  normal turn, as `RemoteActionVoiceConsent` does for long utterances.

### 4 · Surfaces

- **Consent card:** the existing `RemoteActionConsentView` shows the prompt and one touch row per
  option, plus Later. Touch needs no speech recognition.
- **Spoken ask:** "The agent asks: how should I handle the old API? One, keep the old API. Two,
  migrate the callers. Three, stop here." Read once; "repeat" reads it again.
- **HUD:** the decision-card pattern with numbered rows (Plan X's band card, `HUDRouter`), so the
  Neural Band selects a row and the Even backend's numbered items (AH) show the same list. A list
  longer than the HUD's rows pages with Plan [IB](IB-paged-hud-answers.md)'s pager once it exists;
  until then options beyond four are on the phone card only and the HUD says "more on phone".
- **Read-back before sending:** "Sending: migrate the callers." Then the answer goes out through
  FE's typed-reply transport (same retry, reconcile-by-polling and stale-question rules).

## Phases

- **P0 (one PR):** contract text and fixtures; `AgentChoiceOption`, the `choice` kind and its
  validation; `AgentChoiceParser`; the answer request shape. **Tests:** `AgentChoiceParserTests`
  (ordinals, numbers, labels, shared-word ambiguity, yes/no refused, later, cancel, long
  utterance); `AgentQuestionChoiceDecodingTests` (valid, too few, too many, duplicate ids, long
  label, missing options path falls back to free text with options read out);
  `AgentQuestionReplyTests` gains the `choice` request body and the reserved keys.
- **P1 (one PR):** card rows, spoken ask, HUD rendering, voice routing ahead of the normal turn
  while a choice prompt is pending, Agent Mode gate. **Tests:** `RemoteActionConsentTests` for the
  routing (a pending choice consumes "the second one"; with Agent Mode off nothing is shown);
  `HUDInteractionTests` for the numbered rows; a copy test that no string carries plan letters.
- **P2 (with IC P1):** a live run against the desk bridge: a coding agent's real multiple-choice
  question answered by voice from the glasses, and an old-build phone's `approve` refused by the
  bridge.

**Gates:** full suite and Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`; index row and this
Status line updated in each PR.

## Open questions

1. **"Always."** Deferred. When it comes, it needs a rule record (agent, question family, chosen
   option, terms version, expiry) and a place to revoke it, which is the consent gate's job, not
   this parser's.
2. Six options as the ceiling, or four (what fits the Ray-Ban Display without paging)?
   Recommended: six on the wire, four on the HUD with "more on phone".
3. Should labels be matched in the wearer's language when the agent asks in English? Out of scope
   until the agent harness is localised.

## Dependencies

- **N** (🚧 Phases 1 to 3 shipped per the index; the plan file's own Status line still says "Phase
  1 core shipped" and lags, the code at `Services/AgentHarness/Adapters/AgentHarnessPreset.swift`
  and commit `fc73476d` agree with the index).
- **FE** (✅): question identity, typed replies, the reply transport.
- **IC**: the desk bridge that asks choice questions; IC P1 depends on this plan's P0 contract.
- **X** and **AH**: the HUD card and the Even numbered list.
