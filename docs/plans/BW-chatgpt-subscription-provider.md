# Plan BW — ChatGPT Subscription Sign-In (Codex OAuth provider)

**Status: ✅ Shipped through P4's code half; account-scoped models + advanced device-code
fallback added 2026-08-29 — on-device verification checklist still owed (wire-format fixes
2026-08-31–09-04 show partial live exercise against a real ChatGPT account). 2026-10-21: an xAI (SuperGrok) account sign-in added on the same scaffolding — see the amendment at the end; its live sign-in check is owed. 2026-11-18: photos reopened per model — a ChatGPT model sees when the account's catalog says it takes images (P4's image turn, below); the live photo turn is owed.** P1 (`ChatGPTOAuth` + shared `PKCE`/`OAuthCodeInput`), P2 (`ResponsesTranslator` +
stream accumulator), P3 (`ChatGPTOAuthService`, `LLMProvider.chatgpt`, `sendChatGPT`, shared
`OAuthSignInRows` in the model editor), and P4's codeable half — stateless helpers
(summarization, `analyzeFrame`, structured vision/completion via forced function-call), the
shared `DarkAccountSignInSection` powering both the Claude and ChatGPT onboarding sections,
and the onboarding provider tile — are implemented with headless tests. Cascade
classification needed no change (429 quota → hop, 401/403 → skip candidate, no sign-in →
skip candidate). Design deviation from the plan text: the provider's history is stored in
the **chat shape** and translated to Responses items at request time, so `HistoryHygiene`
needed no new image matcher (a test pins that instead). **Still open (needs the phone + a
real ChatGPT account): the P4 live checklist below — the onboarding tile shipped ahead of
the voice-quality listen (deliberate; pulling one card is trivial if codex answers sound
wrong), so run the checklist before any release.**

"Sign in with ChatGPT" as a no-API-key way to run OpenAI
models, mirroring the shipped Claude account sign-in (`ClaudeOAuth` / `ClaudeOAuthService` +
the onboarding surface from the build-320 PR). OpenAI explicitly supports subscription OAuth
in external tools now — but the token it grants authenticates against the **ChatGPT Codex
backend**, a **Responses-API** surface with its own model catalog, *not* `api.openai.com`
chat completions. So this is a **new provider path** (new auth + new wire format), not a
toggle on the existing OpenAI provider — which is exactly why it gets a plan instead of an
afternoon.

Structural facts the design hangs on:

- **Auth**: authorization-code + PKCE in the browser, with a **device-code** variant that is
  available under Other sign-in options for advanced/headless use. Browser sign-in remains the
  normal iPhone path; device codes require the user to enable Device Code Authorization in
  ChatGPT Security settings. Either path yields access + refresh tokens
  and an `id_token` whose **account-id claim must ride every API request** as a header.
- **Wire**: the backend speaks the Responses API (input/output *items*, SSE streaming), and
  serves an account-scoped **Codex model catalog** — not the public API `/v1/models` catalog.
- **Hard exclusions**: subscription credentials are not valid where platform keys are
  required — our OpenAI **Realtime voice mode stays API-key-only**, documented, not worked
  around.

## P1 / PR1 — OAuth core (pure, headless)

- `ChatGPTOAuth` mirroring `ClaudeOAuth`'s shape: PKCE (extract the existing
  verifier/challenge/base64url helpers into a shared `PKCE` enum rather than duplicating),
  authorize-URL builder, **device-code request + poll** request shapes (pending / slow-down /
  expired handled as values), exchange of the approved authorization code, token-response parse
  (access / refresh / `id_token`), and
  account-id extraction from the `id_token` (pure base64url JWT-payload decode — we consume a
  claim, we don't validate signatures client-side).
- `Credentials` with `needsRefresh` leeway, refresh-request builder — same contract as the
  Claude pair so `ChatGPTOAuthService` (P3) can be a structural copy.
- All protocol constants (client id, authorize/token/device endpoints, backend base URL,
  required headers) in one place, explicitly marked *captured-at-implementation against the
  shipping auth service* — this backend is newer and driftier than Anthropic's; one constants
  block is the blast radius.
- Tests: PKCE vectors, authorize-URL shape, device-code poll state machine, token/claim
  parsing fixtures, refresh leeway boundaries.

## P2 / PR2 — Responses wire core (pure, headless)

- `ResponsesTranslator`: shared conversation history → Responses **input items** (text,
  image, tool results), `ToolDeclarations` → Responses tool declarations, and response
  **output items** → `(text, [ToolInvocation])`. Pure functions over `[[String: Any]]`, like
  `GeminiSchemaTranslator` / `HistoryHygiene`.
- SSE streaming: reuse `SSEEventParser` for framing; a small `ResponsesStreamAccumulator`
  folds item/delta events into the same reconstructed-message shape the tool loop consumes.
- `ProviderLoopAdapter` glue for `runToolLoop` — performTurn / appendAssistantToolCall /
  appendToolResults / finalize, with the leniency lessons already learned baked in from day
  one: tolerate missing ids/arguments on tool calls, tolerate missing text on tool-call
  turns, one parsed-vs-sent log line per turn.
- Tests: fixture transcripts for a text turn, an image turn, a tool-call turn (including a
  no-argument tool), a streamed turn reassembly, and history round-trips through
  `HistoryHygiene.pruneImages` (the item shape must be recognised — add it to the
  image-block matcher alongside the Anthropic/OpenAI/Gemini shapes).

## P3 / PR3 — Service edge + UI

- `ChatGPTOAuthService`: keychain persistence, refresh-ahead, `@Published isConnected`,
  `validAccessToken()` — structural copy of `ClaudeOAuthService`.
- New `LLMProvider.chatgpt` case ("ChatGPT (subscription)"): `requiresAPIKey == false`,
  its own base URL + account-scoped model discovery (with a current pre-discovery default), request auth = bearer
  token + account-id header applied in one `ChatGPTAuth.apply` (parallel to
  `AnthropicAuth`).
- `sendChatGPT` built on the P2 translator + adapter; cascade integration classifies
  subscription-quota exhaustion like a 429 so `ModelCascade` hops correctly.
- UI: generalize the onboarding `claudeSignInSection` and the model editor's
  `claudeSignInRows` into one account-sign-in component parameterized by service (Claude /
  ChatGPT), rather than a third hand-rolled copy. Model editor gets the sign-in first;
  onboarding shows the ChatGPT tile **only after P4's quality pass** — the codex catalog is
  coding-tuned, and we don't put a provider in front of first-run users before hearing how
  it answers voice-assistant questions.

## P4 — Live verification (device)

**Code half: shipped** — stateless helpers, onboarding tile + sign-in page, cascade taxonomy
confirmed covered. **Live half: pending, needs the phone + a real ChatGPT account:**

- [ ] Sign in (browser → copy the localhost callback URL from the address bar → paste).
- [ ] Sign in through Other sign-in options after enabling Device Code Authorization; confirm
      cancel, expiry, and disabled-setting messages reveal no token or device-auth id.
- [ ] Fetch models and confirm the list/default matches Codex for the same ChatGPT workspace.
- [ ] One streamed text turn (Chat tab), one buffered voice turn.
- [ ] One tool turn (a native tool AND an MCP tool) — watch the `ChatGPT turn: N tool
      call(s) parsed` log line.
- [ ] One image turn (photo question) — would confirm `input_image` acceptance on codex models.
      **Closed in the negative for now (2026-08-27).** This was never run, yet the provider was
      marked vision-capable and photo turns were handed the image *and* a system prompt insisting
      "You CAN see it — never deny vision" — which invites a described scene the model never saw.
      Every catalog entry is a coding variant with no vision sibling, so the honest default is no:
      `ModelConfig.inferredSupportsVision` reports `false` for this provider, and
      `ChatGPTVisionGate` declines a photo turn out loud (pointing at an API key, Gemini, or the
      on-device model) before an image byte is sent. If a live turn ever *does* prove acceptance,
      the gate is the one place to reopen, per model.
      **Reopened per model (2026-11-18).** Each `/codex/models` row names its
      `input_modalities`, and the upstream client treats a row that names none as text and
      image. `ChatGPTModelAvailability.Catalog` now keeps `imageInput` (the ids whose row takes
      images), `ChatGPTContextCatalog` mirrors it into `ChatGPTImageInput` on every stored catalog
      and at sign-in/launch from the stored copy (account-checked, 7-day ceiling), and every reader
      follows it: the send-time gate, `ModelConfig.inferredSupportsVision`, and the fallback
      chain, which no longer excludes `.chatgpt` outright but still refuses a model the catalog
      lists as text-only, whatever the saved override. Unknown (signed out, no catalog yet, or a
      snapshot stored before the field) is still no, and the decline now points at choosing
      another model in Settings first. The `false` the model editor used to save for every
      ChatGPT model is cleared once (`ChatGPTVisionOverrideReset`), and the editor now stores only
      a real "off". **Still owed:** one photo question on the phone with a real account, watching
      for an `input_image` refusal from the backend.
      **Smart camera now gives the stream back (2026-11-18, build 717 report).** Reopening photos
      let smart camera open the glasses camera for ChatGPT wearers for the first time, and it
      exposed a leak older than this plan: smart camera called a bare `startStreaming()` that
      nothing ever stopped, so one vision question left the camera streaming (and every later turn
      carrying a frame) until the glasses disconnected. A Ray-Ban Display wearer reported a
      permanent green dot on the lens right after. Smart camera now takes a `.smartCamera`
      stream claim through `SmartCameraStreamHold` and gives it back `smartCameraCooldown` after
      its last use (kept for good only under the "always" camera preset); a claim stops only a
      stream it started. **Owed:** confirm on the Display that the dot goes when the camera does.
- [ ] Token refresh across an expiry (leave the app overnight, ask again).
- [ ] Verify the endpoint constants against the live service (the P1 constants block is
      captured-at-implementation and unverified until this runs).
- [ ] **Listen to voice-answer quality** on codex models — decide whether the onboarding
      tile stays, and whether the default model changes.
- [ ] Confirm quota-exhaustion surfaces as a 429 (cascade hop) and note the error body.

## Explicitly out of scope

- OpenAI Realtime voice over subscription auth (platform-key-only; unchanged).
- Importing credentials from other tools' auth stores — we always run our own sign-in.
- Any use of the token against `api.openai.com` — different product, different key.

## Risks / escape hatches

- **Backend drift**: this surface moves faster than a public API. One constants block, P4
  as the gate before any onboarding exposure, and the provider degrades to "sign in again"
  rather than corrupting saved models.
- **Catalog fit**: codex models may answer voice queries in a coding register. P4 evaluates;
  the escape hatch is keeping the provider model-editor-only (power users) without the
  onboarding tile.
- **Device-code availability**: it is intentionally an advanced fallback and can be disabled at
  the account/workspace level. The normal browser flow remains available and is presented first.

## Verification

Headless: P1/P2 test suites + full suite + Release green per PR. Device: the P4 checklist
above, on the phone, with the results written back into this doc before the onboarding tile
ships.

## Amendment 2026-10-21: xAI subscription sign-in

**What shipped.** A wearer with a SuperGrok subscription can sign in to xAI from the model editor
(Settings → AI Models → xAI (Grok) → **Sign in with xAI**) and use Grok models with no xAI API key.
Same shape as this plan's ChatGPT sign-in and the Claude one before it: a pure core
(`Utils/XAIOAuth.swift` — PKCE authorize URL, pasted-input parsing via the shared
`OAuthCodeInput`, form-encoded exchange/refresh with no client secret, the discovery trust rule,
`id_token` email/name for the "Signed in as" row, the chat-model filter) and a `@MainActor`
service (`Services/XAIOAuthService.swift` — exchange, refresh through the shared
`SingleFlightRefresher` slot `xai`, `OAuthRefreshFailure.classify` so a dead refresh token signs
out and a network blip does not, credentials in the this-device-only keychain item
`xaiOAuthCredentials`). It conforms to `OAuthSignInService`, so the editor reuses
`OAuthSignInRows` and the in-app sheet. The client is xAI's CLI public client, the same
arrangement as the ChatGPT and Claude sign-ins.

**Where it differs from the ChatGPT shape.**

- **No provider case.** The token carries `api:access`, which the public API accepts as a plain
  `Bearer` on `api.x.ai/v1`. So the existing `LLMProvider.xai` Chat Completions path serves it —
  photos and tool calls included. A saved xAI model whose key is empty uses the account token when
  signed in; a typed key always wins (`XAIAuth.resolveCredential`). `LLMService` gained
  `xaiAccountOverride` beside the Claude/ChatGPT/Google seams; the main turn wraps every send in
  `SubscriptionAuthRetry` (one forced refresh and one retry on a 401, only for a sign-in token),
  and the one-shot paths (summarise, frame analysis, structured completion) resolve the same
  credential. Job-turn routing counts a signed-in xAI model as usable.
- **Loopback on `127.0.0.1:56121/callback`.** `LoopbackCallbackServer` already took a port and a
  path, so the zero-paste capture needed no change; the paste field stays as the fallback.
- **Discovery.** `https://auth.x.ai/.well-known/openid-configuration` may move the authorize and
  token endpoints, but each discovered endpoint is used only if it is `https` on `x.ai` or a
  subdomain, with no credentials or port of its own (`XAIOAuth.trustedEndpoint`); anything else, a
  failed fetch or a slow one (5 s) keeps the static `auth.x.ai/oauth2/{authorize,token}`. The
  answer is cached for the launch. Discovery starts when a sign-in starts, never at launch, so a
  wearer who never uses xAI never reaches its sign-in host; the authorize URL uses the static
  endpoint until this launch has a discovered one.
- **Model picker.** "Fetch available models" on a keyless, signed-in xAI model reads `GET /v1/models`
  with the account token; the xAI list is filtered to chat models (image/video generators, voice,
  realtime, embedding and build models dropped), keyed or not.
- **Egress and disclosure.** New route `NetworkRoute.xaiOAuthToken` (first-party cloud, credential
  only, blocked under the medical local-only rule like the other sign-ins — discovery included),
  `PrivacyLog.AuthProvider.xai`, the keychain key in `Config.accountCredentialKeychainKeys`, the
  `DataStoreRegistry` OAuth row, `privacy.html`'s provider list and `docs/BUILDING.md`.
- **Not added.** No onboarding tile (xAI is not an onboarding provider) and no organisation-profile
  sign-in option (an org xAI model stays key-based, as an org Anthropic model does).

**Owed (device).**

- [ ] Live sign-in on the phone with a real SuperGrok account: the sheet captures the
      `127.0.0.1:56121` redirect without a paste; the "Signed in as" row shows the email.
- [ ] A keyless xAI model answers a spoken turn, a photo turn and a tool call on the account token.
- [ ] Fetch available models lists only chat models for the account.
- [ ] Token refresh across an expiry (leave the app overnight, ask again).
- [ ] Note whether the discovery document moves either endpoint, and what a quota-exhausted
      subscription returns (expected 429 → cascade hop).

