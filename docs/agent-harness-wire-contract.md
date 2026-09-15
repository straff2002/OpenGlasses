# Remote agent harness — wire contract (Custom endpoint)

What OpenGlasses sends to a **Custom endpoint** agent harness, what it expects back, and what it
does when the answer is missing, unreadable or slow. The generic adapter
(`CustomAgentHarness` + `CustomHarnessConfig`) is the subject; the presets for the hosted coding
backends are the same contract with the fields pre-filled.

Owning plans: [N](plans/N-remote-agent-harness.md) (the harness itself) and
[FE](plans/FE-agent-voice-reliability-and-feedback.md) P0 (result truthfulness, terminal state,
retry policy).

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
| awaiting input | `awaiting_input`, `waiting` |
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
