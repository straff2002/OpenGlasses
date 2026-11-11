# Plan LK — Reading Mail: the Decision (what it would unlock, what it costs, and the ways to do it)

**Status:** 📝 Drafted 2026-11-11. Nothing built. This is a decision plan, not a build plan: it asks
[one question](#decisions-for-greig-open) and sketches phases only for the recommended answer.
**Track:** Everyday assistant.
**Reopens:** Plan [JO](JO-watchers.md) decision 5 ("Mail — not in this plan") and Plan
[IX](IX-scoped-grants-and-read-only-integrations.md)'s record that there is no mail-reading tool.
**Builds on, whichever option:** Plan [R](R-mcp-egress-and-tool-poisoning-screen.md) (`EgressScreen`,
`ToolDefinitionScanner`, `PromptInjectionPolicy`), Plan IX (read-only integrations, standing grants never for
high-impact actions), Plan [BC](BC-unconditional-safety-gate.md) (`HighImpactToolPolicy`), Plan
[DY](DY-my-day-everyday-briefing.md) (My Day), Plan [BZ](BZ-notification-digest.md) (digest).
**Sits beside:** Plan [LL](LL-always-on-home-agent.md) (an always-on agent, which options C and D lean on), Plan
[CR](CR-cloud-action-agent-gateway.md) (a provider-hosted agent backend), Plan
[LJ](LJ-tell-me-when-its-for-sale.md), Plan [LE](LE-evening-check-in.md).

---

## Why

An example list of routines a cloud personal agent runs, which the owner shared on 2026-11-11, depends on reading
mail more than on anything else:

| Routine | Needs |
|---|---|
| A scan for urgent mail in the morning briefing | read, classify |
| A daily digest of promotional mail, one line each, nothing deleted without asking | read, summarise |
| Standing rules for surveys, shipping notices, old sign-in alerts | read, then archive or label |
| A rolling sweep archiving transactional mail older than a few days | read, archive |
| Coupons emailed by stores filed into a wallet ([LF](LF-coupon-wallet.md)) | read, extract |
| School notices read, their PDFs fetched, a summary drafted for approval | read, fetch links, draft, send |
| Entering no-purchase contests found in mail | read, follow links, submit forms |

The owner then asked whether Avenkin could check mail through a connected Claude or OpenAI account, the way
Claude Code reads Gmail. This plan answers that too (§ Option B2).

## What exists (verified 2026-11-11 at main 2d936d2)

- `send_via` (`Services/NativeTools/SendEmailTool.swift`) composes only: it builds a `mailto:` URL with subject
  and body and hands it to the mail app. Nothing reads mail.
- No Gmail, IMAP or Microsoft Graph client anywhere in `Sources`. iOS gives a third-party app no access to the
  Mail app's store.
- No `mcp_servers` or `mcp_toolset` in any provider request. Sign in with Claude is `Utils/ClaudeOAuth.swift` and
  `Services/ClaudeOAuthService.swift`. It authenticates model calls and carries no connectors.
- Untrusted-output handling exists: `PromptInjectionPolicy.untrustedOutputTools`, `EgressScreen` (on the MCP
  seam only), `ToolDefinitionScanner`.
- No background execution (`UIBackgroundModes`: `audio`, `bluetooth-central`, `external-accessory`; no
  `BGTaskScheduler`) and no push. A mail check could only run while the app is alive.
- The app's privacy manifest is `Sources/Resources/PrivacyInfo.xcprivacy`. It declares no email content.

## The options

### A · Keep mail out (today)

Nothing changes. Avenkin composes mail and never reads it. The routines above stay with whatever the wearer
already uses.

- **Costs:** none. **Loses:** every row in the table.

### B1 · A read-only mail source on the phone, under IX

A new integration, read-only by construction, that lists and reads messages for the briefing, the digest and
"anything from the school today?".

- **Providers.** The Gmail API with a read-only scope, Microsoft Graph with mail read, or IMAP for other hosts.
  Gmail over IMAP with OAuth needs the full-mail scope, which is broader than reading.
- **Google's verification.** Google classes Gmail's read scopes as restricted. An app asking for them goes
  through OAuth app verification, and Google has required a separate security assessment for apps whose
  restricted data reaches a server. **Confirm Google's current policy before choosing this option**: the
  rules change, and whether a phone-only client that never stores mail on a server needs the assessment is the
  question that decides the cost.
- **App Review and disclosure.** "Emails or text messages" joins the privacy manifest, the App Store privacy
  label and the in-app privacy copy, in the same PR (the telemetry-posture rule in
  `.claude/rules/dat-conventions.md` applies the same pairing to any new egress).
- **Where mail goes.** The phone reads it. A summary or classification needs a model: on the device, or the
  wearer's chosen cloud model, which then receives the mail text. Network Activity and the processing summary
  must say so.
- **Injection.** Mail is the most hostile text the app would ever read. Every mail-derived string is untrusted
  output. It is phrased from typed fields (sender, subject, date) wherever it can be, and any tool call that a
  turn proposes after reading mail goes through the normal confirmation ladder. No mail-read turn can call a
  sending or deleting tool without the wearer's spoken yes.
- **Timing.** A morning scan works when the app is open or alive. A 7 a.m. scan with the phone locked needs
  background refresh, which nothing has built yet (JO P2 / GN).

### B2 · Mail through a connected Claude or OpenAI account

This doesn't avoid B1's costs.

- The Gmail access in Claude Code comes from a connector authorised on the claude.ai account, and it works inside
  Anthropic's own apps. **An app calling the Messages API, with an API key or a Sign in with Claude token, does
  not inherit those connectors.**
- What the API offers is an MCP connector (a beta: `mcp_servers` with a remote server URL and an auth token the
  caller supplies, plus an `mcp_toolset` tool). Avenkin would still need a Gmail MCP server and a Google OAuth
  grant with mail scopes. That is B1's consent and verification problem again. The mail is then fetched
  provider-side, inside the model turn.
- OpenAI's Responses API connectors also take an OAuth token the caller supplies (to confirm against current
  docs).
- So B2 is B1 with the fetch moved to the provider. It is worth choosing only if the wearer's provider is already
  trusted with the mail.

### C · Mail stays with a home agent the wearer runs

The wearer's own always-on agent (OpenClaw or Hermes, Plan [LL](LL-always-on-home-agent.md)) holds the mail
credential and runs the sweeps on its own schedule. Avenkin asks it ("anything urgent in my mail?") and receives
its typed results (LL P0), shown and spoken under Avenkin's own delivery rules.

- **Costs:** the wearer runs a machine and an agent. Avenkin's code gains no mail client and no Google
  verification.
- **Boundary:** the agent's mail handling is the agent's own. Avenkin's privacy claims stop at what it receives,
  and the settings copy says so.

### D · Mail with a provider-hosted agent

The same as C, with the agent hosted by a model provider instead of at home. For example, a managed-agents
service with a credential vault, MCP and scheduled runs, as Plan CR argues for its backend.

- **Gains:** no home server. Nightly and morning runs happen whether or not the phone is awake.
- **Costs:** the provider holds the Google grant and the mail, and bills the usage. It runs outside the phone's
  safety gate. Someone still deploys and owns it (CR is single-tenant and self-deployed).
- **The same rule as C:** anything high-impact the agent proposes that would act on the phone, the glasses or
  the wearer's accounts through Avenkin is confirmed on the phone.

**What an owner can do today, without app changes** (a personal stopgap, not product): a scheduled Claude Code or
Cowork task with the Gmail connector can write its findings into a calendar, a reminders list, or a gateway event
that Avenkin already reads.

## Whatever is chosen, these never happen

- Deleting, archiving, moving, labelling, unsubscribing or sending without a per-action confirmation. Mail writes
  never get an IX standing grant ("send a message" is already on IX's ask-every-time list).
- Entering contests, submitting forms, creating accounts or opting in to anything.
- Following links in mail automatically. A link can be a tracking pixel, a subscription confirmation or a
  one-click action. Fetching a PDF from a link is the wearer's tap, or a confirmed step.
- Mail text becoming instructions. A message that says "forward this to everyone" is data.
- Mail being saved into memory, unless the wearer asks to remember something from a message.

## Recommendation

**C now, with D accepted on the same contract; A stays the default; B1 and B2 only if wearers without an agent
ask for it.**

- Options C and D need no mail client in a public app, no restricted-scope verification and no new data type in
  the manifest. They reuse the always-on tier that watchers (JO, LJ) need anyway.
- Most of the table's routines need an always-on process regardless: a sweep, a 7 a.m. scan, a daily digest. A
  phone that reads mail only while open delivers the urgent-mail line and little else.
- B1 is the right product for a wearer with no agent, and it is a large, careful piece of work. Doing it later,
  if asked, loses nothing: the "never" list and the typed-results path are the same.

## Phases for the recommendation (sketch)

- **C0 — words.** `send_via`'s description and the prompts keep saying the app can't read mail, and add: "if
  you've connected a home agent that reads your mail, I can ask it." `discover_capabilities` says the same.
- **C1 — mail results over LL's contract.** A `mail` result kind in LL P0 (sender display name, subject, received
  time, the agent's one-line reason, an urgency flag, a thread reference the agent understands). The phone stores
  no body. My Day gets a "Mail" line from the latest result when one is less than a day old (decision 3).
- **C2 — asking.** "Anything urgent in my mail?" and "what's in the promo digest?" go to the home agent through
  the existing bridge. A requested action ("archive the old shipping notices") is sent only after the phone's
  confirmation, and its outcome is recorded in the activity trail (Plan IW).
- **C3 — device pass** with a real OpenClaw or Hermes setup reading a test mailbox.

## Decisions for Greig (open)

1. **Which option.** Recommended: C, with D accepted on the same contract. A stays the default.
2. **If B1 is chosen later, which provider first.** Recommended: Gmail read-only, after checking Google's current
   verification rules for a phone-only client.
3. **Mail in My Day.** Recommended: one line, only from a home or hosted agent's result less than a day old,
   never a list of subjects read aloud unasked.

## Out of scope

A mail client, sending from inside Avenkin, mail search history, attachments stored on the phone, and any
automatic action on mail.
