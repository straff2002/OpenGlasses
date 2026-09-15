# Remote agent harness — wire contract (Custom endpoint)

What OpenGlasses sends to a **Custom endpoint** agent harness, what it expects back, and what it
does when the answer is missing, unreadable or slow. The generic adapter
(`CustomAgentHarness` + `CustomHarnessConfig`) is the subject; the presets for the hosted coding
backends are the same contract with the fields pre-filled.

Owning plans: [N](plans/N-remote-agent-harness.md) (the harness itself) and
[FE](plans/FE-agent-voice-reliability-and-feedback.md) — P0 (result truthfulness, terminal state,
retry policy) and P1 (question identity, typed replies, explicit agent selection).

Every URL, field name and dot-path below is configured by the wearer in
**Settings → Agentic Features → Remote Agents**. Nothing is guessed: a path that is not set is a
field the endpoint does not report, and an unreported field is **unknown**, never "none".

## Transport rules

- `https` everywhere. `http` is accepted only to loopback (`localhost`, `127.0.0.1`, `::1`,
  `*.localhost`), because the auth header rides every request.
- One optional auth header (name + value), applied to start, status and cancel alike.
- The run id is substituted into the URL templates **percent-encoded**, so an id the endpoint
  chose cannot rewrite the request path.
- Timeouts: 30 s to start (90 s when a camera still is attached), 15 s for status and cancel.

## Start — `POST` to the start URL

```jsonc
// body, with the configured field names (defaults shown)
{ "prompt": "add a dark-mode toggle", "project": "my-app" }
```

`project` is omitted when there isn't one. A base64 JPEG of the wearer's view is added **only**
when an image field name has been configured (empty by default — an unnamed field never attaches).

The response must carry a run id at `idPath` (default `id`); a run status at `statusPath`
(default `status`) is read if present. No id ⇒ the dispatch fails and says so.

## Status + result — `GET` the status URL

One request per tick returns **both** the lifecycle status and everything reported about the
outcome. Richer reporting therefore costs no extra traffic.

```jsonc
{
  "status": "completed",
  "result": {
    "summary": "Added the toggle and a test.",
    "filesCreated":  ["Sources/Toggle.swift"],
    "filesModified": ["Sources/Settings.swift"],
    "commands":      ["swift test"],
    "pushed":        true,
    "pullRequest":   "https://example.test/pr/1",
    "error":         null
  }
}
```

Nothing above is hard-coded. Each value is found by a dot-path setting:

| Setting | Reads | Shape |
|---|---|---|
| Status path | lifecycle status | string |
| Summary / final text path | the agent's closing words | string |
| Files created path | paths created | array of strings |
| Files modified path | paths modified | array of strings |
| Commands run path | commands executed | array of strings |
| Pushed path | whether it pushed | bool, `0`/`1`, or `"true"`/`"false"`/`"yes"`/`"no"` |
| Pull-request URL path | PR opened | string; must parse as `http(s)` with a host |
| Error message path | why it failed | string |

**Defaults are empty for every result path.** An unset path, or a path the response does not
answer, leaves the field out of the record, and the spoken summary then says the run finished
without saying what it did — rather than asserting that nothing changed.

### Recognised status values

| Meaning | Accepted spellings |
|---|---|
| queued | `queued`, `pending` |
| running | `running`, `in_progress` |
| awaiting input | `awaiting_input`, `waiting` (see **Questions**) |
| completed | `completed`, `done`, `success` |
| failed | `failed`, `error` |
| cancelled | `cancelled`, `canceled` |

Matching is case-insensitive. Anything else is **unknown**: it is not treated as "running".

### Terminal semantics

Three distinct outcomes, never collapsed:

- **completed** — the spoken summary reports what was reported, and ends with "Done."
- **failed** — the summary says the run failed, with the mapped error message if there is one.
- **cancelled** — spoken as cancelled. A run stopped at the far end is never narrated as success,
  and never as something the wearer asked for.

### Which agent (optional)

An endpoint fronting more than one coding agent can be told which one to run. Name a body key and
the value to send in it — **Settings → Which agent** — and both ride the start body:

```jsonc
{ "prompt": "add a dark-mode toggle", "project": "my-app", "agent": "reviewer" }
```

Both halves blank (the default) means the endpoint decides. This is a **configured request value**:
it is not chosen by what the wearer says, by which voice persona is active, or by a wake phrase.

The body keys must not collide. Prompt, project, image and agent fields are checked against each
other, and a duplicate is a configuration error named in Settings — the request is refused rather
than sent with one value quietly written over another.

**The endpoint a run was dispatched to is bound to that run.** Editing the URL, the token or the
agent value afterwards changes where the *next* run goes; the run in flight keeps answering, and
being cancelled, at the backend that started it.

## Questions — reported by the same status `GET`

A run that pauses for the wearer reports `awaiting_input` (or `waiting`), and — where the paths are
mapped — what it is asking:

```jsonc
{
  "status": "awaiting_input",
  "question": {
    "id":       "q7",
    "revision": 0,
    "kind":     "text",
    "prompt":   "Which files should I touch?"
  }
}
```

| Setting | Reads | Shape |
|---|---|---|
| Question prompt path | what to ask the wearer | string |
| Question id path | the question's identity | string |
| Question revision path | re-ask counter for the same id | integer ≥ 0 |
| Question kind path | what sort of answer is wanted | string |

**Identity is `(id, revision)`, and it decides what the wearer hears.** A question is surfaced once
per identity: polling the same pending question every four seconds is not the agent asking again. A
**revision** bump re-asks it. A **new id** is a new question even when it is worded exactly like the
last one — which is why text equality was never a safe test.

**No id path, or no id in the answer?** The identity is derived deterministically from
`(run id, wording, arrival order)`. Arrival order advances when the run leaves and re-enters the
waiting state, or when the wording changes. The limit is stated rather than hidden: from such an
endpoint, **two questions with identical wording are told apart only by the order they arrive in.**

**Kind.** `text` / `free_text` / `question` / `input` / `clarification` mean the agent wants words.
**Everything else — including nothing at all — is read as a confirmation**, which goes through the
wearer's own approve/deny prompt. Guessing "free text" for an unlabelled question is how a
confirmation would quietly become a conversation.

## Answers — `POST` to the answer URL (optional)

Configured separately (`{id}` is the run id, percent-encoded as everywhere else). Without it, a
question this endpoint asks can be heard but not answered, and the wearer is told exactly that —
rather than a reply being silently dropped and success announced.

```jsonc
{
  "reply":            "only change the tests",   // the configured answer field; free text only
  "decision":         "text",                     // "approve" | "deny" | "text"
  "questionId":       "q7",
  "questionRevision": 0,
  "replyId":          "5C1F…"
}
```

`decision`, `questionId`, `questionRevision` and `replyId` are **reserved** key names; the answer
field may not be one of them. An approval or a decline carries no answer field at all — the whole
point of the typed reply is that a boolean cannot say "only change the tests", and words cannot say
"yes".

**`replyId` is stable across retries of the same answer.** A re-send after an unconfirmed delivery
carries the id the first attempt carried, so an endpoint that already applied the answer can treat
the repeat as a no-op. Nothing else makes re-delivery safe.

### Where an answer comes from

Both kinds go through the wearer's own prompt — the card and the spoken ask — never straight from a
model turn. A `code_agent confirm` call can *raise* the approve/deny prompt but can never answer it;
a `code_agent answer` call shows the wearer the words about to be sent, and only what comes back
from that prompt is forwarded, edits included. The card offers both by touch, so neither needs
voice recognition to be working.

### What happens to an answer

| Outcome | What is said, and what is claimed |
|---|---|
| Accepted | "Okay, proceeding." / "Sent your answer to the agent." — the run moves on |
| Accepted decline | "I've told the agent not to proceed." **Not** "cancelled": what the run does next is the endpoint's to report, and status afterwards says so until it does |
| No answer address | "This agent can't take a typed answer" / "…no way to relay a decline" — nothing is sent, the question stays pending, and the run's status is left exactly as the endpoint reported it |
| Transport or HTTP failure | The question stays pending, the reply is held, and a retry re-sends **the same** `replyId`. Nothing is announced as success |
| Timeout after sending | Reconciled by **re-polling the status**, never by posting again. If the run has left `awaiting_input` the answer landed; if it is still waiting, the answer is still pending and a retry is offered |
| Stale (the question was replaced, cancelled or expired) | Refused and never forwarded — approving a question that has been replaced approves whatever took its place |

## Cancel — `POST` to the cancel URL (optional)

Configured separately; without it, cancel is reported as unsupported rather than silently ignored.

## Retry and contact policy

Polling is bounded. The defaults (`AgentPollingPolicy`):

| Knob | Default |
|---|---|
| Poll interval | 4 s |
| Retries after a failed poll | 4 |
| Backoff | 2 s, doubling, capped at 32 s |
| Unknown-status ticks tolerated | 5 |

- **Transport failure** — retried with backoff, up to the bound (so a dead endpoint receives five
  requests, not an endless stream). Then polling stops and one line says contact was lost. The run
  keeps its last known status: a lost connection is a fact about us, never a verdict that the run
  failed or was cancelled. "Agent status" afterwards reports when contact was lost and what was
  last known.
- **401 / 403** — the credential is wrong. Polling stops immediately with no retry.
- **408 / 429 / 5xx** — retryable, as above.
- **Other 4xx** — the endpoint says this request will never work. Polling stops.
- **Unrecognised status** — tolerated for a bounded number of ticks, then reported with the raw
  label the endpoint sent (sanitised and shortened).
- **No status URL configured** — reported once, immediately, instead of following a run forever.

## What the endpoint's words can and cannot do

Everything the endpoint returns is a **report of what something else did**, with the authority of a
web page:

- Strings are stripped of control characters, whitespace-collapsed and capped (200 characters per
  path/command/error, 600 for the summary, 40 for a status label echoed back).
- Lists are capped at 100 entries — only the count is ever spoken.
- A pull-request URL is kept only if it parses as `http(s)` with a host.
- HTTP error bodies are **never** quoted into anything spoken; only the status code is surfaced,
  and the body's size is recorded in the privacy log.
- `code_agent` output is framed as untrusted tool output before it reaches the model, so an
  endpoint narrative cannot issue instructions, call tools or claim authority.
