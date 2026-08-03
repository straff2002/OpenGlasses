# Plan AI — LLM Provider Auth Paths (reference + provider additions)

**Status:** 📝 Reference; **Vertex OAuth provider shipped 2026-08-03** — `GoogleOAuth`/`VertexAI`
pure cores (PKCE, reverse-DNS callback, form-encoded token requests, regional endpoint builder),
`GoogleOAuthService` edge (`ASWebAuthenticationSession`, keychain, refresh-with-leeway),
`.geminiVertex` provider case routed through a shared `geminiRequest` builder at all five Gemini
call sites (Bearer auth, per-turn re-resolution), model-editor UI (client ID / project / region /
sign-in). Gemini Live + streaming scoped out as planned. The BK P2b hand-off item 2 verified
already satisfied: `ModelFallbackChain` classifies `missingAPIKey` as per-candidate. The
Claude-app Shortcut item stays demoted to an appendix; runtime failover is **owned by Plan BK
P2b**, not this doc (this plan hands it two requirements, below).

How OpenGlasses authenticates to an LLM backend, what each path costs in *functionality*, and
where OAuth / "use my account" actually works.

## The governing principle

**Full functionality** = the app sends a real chat/vision request with our system
prompt, camera images, tool definitions, and gets back streamed text + structured
tool calls. That needs a genuine **completions API**.

A consumer **subscription** (ChatGPT Plus, Gemini Advanced / Google One AI) generally does
**not** expose such an API to third-party apps. Two qualifications learned since the first
draft: **Anthropic now does** (Sign in with Claude, shipped in-app — below), and the app
already supports three **subscription-billed coding-plan endpoints** (`.zai`, `.qwen`,
`.minimax`, `LLMService.swift:27-29,68-70`). "OAuth + full functionality" is therefore real
where the vendor offers an account-scoped completions endpoint; elsewhere it remains key-based.

## ✅ Shipped since first draft: Sign in with Claude (in-app OAuth)

Commit `32c2f9d` (2026-07-03) shipped the path this doc's first draft said didn't exist:

- `ClaudeOAuth.swift` — pure PKCE core (authorize URL, code#state parsing, token
  exchange/refresh, `sk-ant-oat…` detection, expiry-with-leeway). House-style deterministic core.
- `ClaudeOAuthService.swift` — token exchange, refresh-before-expiry (5-min leeway),
  Keychain storage, sign-out wipe.
- `AnthropicAuth.apply` (`ClaudeOAuth.swift:167-186`) — OAuth tokens ride
  `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`; API keys ride `x-api-key`;
  `resolveCredential` falls back from explicit key to the connected account.
- Wired into the live send path (`LLMService.swift:1167-1171`) and Settings
  (`ModelFormView.swift:31-35,347-400`).

**Consequence:** the no-key/no-Mac Claude path is the ordinary `sendAnthropic` path with **full
vision + tools**, hands-free. Everything below is written against that reality. (Honesty note:
the same ToS-gray-area caveat this doc attached to the CLI bridge applies to serving app
requests on a subscription via in-app OAuth — the sanctioned programmatic path is still a key.)

## Auth-path matrix (complete against `LLMProvider`)

| Path | Auth | Vision + native tools | Who bills | In OpenGlasses |
|---|---|---|---|---|
| **Anthropic API** | API key | ✅ full | Anthropic (key) | ✅ supported |
| **Anthropic — Sign in with Claude** | **OAuth (in-app PKCE)** | ✅ full | Claude subscription* | ✅ **shipped** (`32c2f9d`) |
| **Claude via local CLI bridge** | OAuth (Claude Code on a Mac/host) | ✅ full | Claude subscription* | ⚠️ model-listing + save work keyless, but **keyless sends throw** (`LLMService.swift:1343-1345` key guard is unconditional) — bug tracked separately; superseded for most users by in-app OAuth anyway |
| **OpenAI API** | API key | ✅ full | OpenAI (key) | ✅ supported |
| **Groq / xAI / OpenRouter** | API key | ✅ per model | vendor (key) | ✅ supported (OpenAI-compatible) |
| **z.ai / Qwen / MiniMax coding plans** | API key (subscription-billed) | ✅ per model | vendor subscription | ✅ supported ("(Subscription)" providers) |
| **Azure OpenAI** | **Microsoft Entra OAuth** | ✅ full | Azure (account) | ⚠️ via Custom provider; needs token refresh |
| **Gemini API (AI Studio)** | API key (created via Google sign-in) | ✅ full | Google (free tier + per-token) | ✅ supported (key rides the **query string** at 5 call sites + the Gemini Live websocket) |
| **Gemini via Vertex AI** | **Google OAuth** (GCP project) | ✅ full (streaming would be new — see below) | Google Cloud (account) | 📋 the buildable item |
| **AWS Bedrock** | AWS SigV4 / IAM | ✅ full | AWS (account) | ⚠️ needs signing |
| **Local MLX / Apple on-device** | none | text (+ tools, no vision) | free | ✅ supported |
| **Claude app "Ask Claude" (Shortcut)** | on-device Claude app | ❌ text only, no tools | Claude subscription | ❌ demoted — appendix |

\* Subscription-serving-app-requests is a ToS gray area regardless of transport (CLI or in-app
OAuth). The sanctioned programmatic path is an API key.

## "Through my Google account" — the specifics

**Gemini — yes, two ways, both full-featured:**
1. **AI Studio key (easy, already supported).** Sign in to `aistudio.google.com` → create an
   API key → paste into the Gemini provider. Free tier; lowest-effort full-functionality path.
2. **Vertex AI + OAuth (the buildable item).** Scoped below.

**OpenAI — no, not "through Google."** Google SSO on the OpenAI platform still ends in an
OpenAI API key. No OAuth flow drives the OpenAI API from a ChatGPT Plus subscription; "Sign in
with ChatGPT" remains preview-only — design for it, don't depend on it.

## Buildable item — Vertex-AI OAuth Gemini provider (one PR)

**Reuse the shipped pattern:** pure core + service edge + Keychain + refresh-with-leeway,
mirroring `ClaudeOAuth`/`ClaudeOAuthService` — this is now precedent, not new design.

Google-specific requirements the first draft omitted:
- A registered **GCP OAuth client ID**; **`ASWebAuthenticationSession`** for the browser flow
  (Google blocks the paste-a-code trick the Claude flow uses); offline-access consent so a
  refresh token is issued.
- **Project ID + region selection UI** — both are path components of
  `aiplatform.googleapis.com` URLs.
- **Plumbing cost is real, not "just OAuth":** Gemini key auth is baked into URL query strings
  at five `LLMService` call sites (`:799, :895, :997, :1090, :1688`) plus the Gemini Live
  websocket (`Config.swift:1618-1622`). Vertex is either a new provider case with its own send
  path (Bearer headers) or a refactor of all six sites. **Gemini Live mode is not covered by
  this item** — scoped out explicitly.
- **No streaming inheritance:** `sendGemini` doesn't stream today (`:generateContent`, no
  `onToken`); Vertex streaming would be a new feature, not a free ride. Out of scope for PR1.
- **Voice-first lifecycle:** the OAuth flow is a Settings-time, phone-in-hand act — fine, say
  so in the UI. A **mid-session refresh failure** must not dead-air: narrate it (BK P2c
  pattern) and let the BK P2b cascade move to the next candidate.

**Tests (headless, house style):** pure `GoogleOAuth` core — authorize-URL construction,
token-request/refresh encoding, expiry-with-leeway; URL-builder tests for project/region paths.
Live browser flow + on-device validation deferred, mirroring Plan V's OAuth deferral precedent.

## Handed to Plan BK P2b (fallback-chain owner)

This plan defines no runtime failover — BK P2b's `ModelFallbackChain` owns it. Two requirements
originate here:

1. **Capability-filter candidates:** `requiresVision` / `requiresTools` / `handsFreeSafe`
   predicates. Text-only candidates (`.appleOnDevice`, models with `visionEnabled == false`,
   any foreground-hop path) must be skipped for turns that need what they lack; a
   foreground-hop provider should **never** be an automatic cascade candidate (breaks
   hands-free, can't preserve history/tool state).
2. **Expired/missing OAuth credential is skip-to-next, not chain-terminal.** A refresh failure
   surfaces as `missingAPIKey` (`LLMService.swift:1169`) — terminal *for that provider*,
   retryable on the next. BK P2b's current taxonomy classes `missingAPIKey` as fully terminal;
   with OAuth providers in the mix it must be per-candidate.

## Recommendation

- **Least effort, full functionality** → Gemini AI Studio key (already supported).
- **No key, full functionality, hands-free** → **Sign in with Claude** (shipped).
- **True OAuth on Google** → the Vertex item above (one PR, core-first).
- The CLI bridge and the Shortcut are both effectively superseded; fix the keyless-Custom send
  bug on its own merits.

---

## Appendix — Claude-app Shortcut fallback (demoted, not scheduled)

Kept for reference; its raison d'être ("the only no-key/no-Mac option") ended when in-app OAuth
shipped. Residual audience: a user with the Claude app who refuses in-app sign-in — thin, for a
path that breaks hands-free per query.

If it is ever revived, the review corrections that must apply:
- **Reuse the existing callback host** — `shortcuts://x-callback-url/run-shortcut` +
  `x-success=openglasses://shortcut-result` already exist end-to-end
  (`CustomToolWrapper.swift:48-85`, `ShortcutCallbackManager.swift`,
  `OpenGlassesApp.swift:171-177`). Don't invent `openglasses://claude-result`.
- `ShortcutCallbackManager` holds a **single continuation** with a **30s timeout** — too short
  for a long Claude answer, and a concurrent custom-tool shortcut would clobber it. Key by
  request if this ships.
- **Backgrounded/locked phone is a failure mode, not friction:** `UIApplication.shared.open`
  of `shortcuts://` from a backgrounded voice session won't foreground reliably, and the
  round-trip app-switch disrupts the audio session/wake-word listener — in the primary usage
  posture this path *doesn't work*, not "is degraded."
- One-line warning to carry: never expose this as an `AppShortcut` phrase with a free-form
  String parameter (`AskQuestionIntent.swift:11-14` encodes the lesson — it halts
  `appintentsmetadataprocessor` and wipes ALL intent metadata; only a Release/SDK build
  catches it).
- (Correction from the first draft: the inbound deep-link handler parses `openglasses://`
  hosts only; `fb-viewapp://` appears once as an *outgoing* open — it was never evidence of
  reusable inbound plumbing.)
