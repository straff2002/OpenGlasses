# Plan DD — Onboarding Sign-In & Design Refresh

**Status:** ✅ P1–P3 shipped — P1+P2 (loopback capture + in-app sheet) 2026-08-25; P3, the
design-language half, landed 2026-08-25 as **DG P2**

## Why

With App Store distribution as the mainline channel, the first-run experience is no longer a
contributor path — it is the product's front door, and the most common walk through it will be:
install, pick the provider whose subscription you already pay for, sign in, talk. Today the
sign-in half of that walk is developer-grade.

The ChatGPT provider (Plan BW) authenticates with authorization-code + PKCE against a public
client whose **registered redirect is `http://localhost:1455/auth/callback`**
(`ChatGPTOAuth.swift`). On the phone that flow is: button opens the external browser → the user
logs in → the redirect **fails to load** (nothing is listening on localhost) → the user copies
the full callback URL out of the address bar → app-switches back → pastes it into a field
(`ChatGPTOAuthService.completeSignIn(pastedCode:)`). Sign in with Claude is the same shape —
out to the browser, then a code pasted back. Every other provider is a raw API-key paste. The
flow *works*, and Plan BW was right to ship it; but "login → dead page → copy a URL out of the
address bar" is the single worst minute of the product for exactly the user we most want to keep.

The unlock is sitting in the redirect itself: **`localhost` on the phone is the phone.** If the
app presents the login page in an in-app browser sheet (`SFSafariViewController`), the app stays
foreground-active, which means it can run a loopback listener on port 1455 for the duration of
the sign-in. The browser's redirect then lands on *our* listener: we validate state, capture the
code, serve a tiny "you're connected — return to the app" page, dismiss the sheet, and exchange
the token. The user experience collapses to: **tap Sign in → log in on the sheet → sheet closes
→ "Account connected."** No paste, no app-switching, no dead page — and no cooperation needed
from the provider, because we changed nothing about the OAuth contract; we just answered the
redirect the client was always registered to make.

Second half: the onboarding surface these flows live in is a fully hand-rolled white-on-black
world — custom cards, custom fields — visually unrelated both to the system design language and
to the app's own OGDesign components (Plan CL). For a first-party-feeling first minute on
current iOS, provider and model selection should read as native: system materials, grouped
selection, native sheets. This plan restyles the onboarding provider/credential/model pages;
it does not touch the rest of onboarding's structure (Plan DB owns the Back button and the
keyless default, and lands first).

## P1 — Pure core: loopback capture + flow state

- **`LoopbackCallbackServer`** — an `NWListener` bound to **loopback only** (`127.0.0.1`), port
  1455 in production and injectable for tests. Speaks just enough HTTP to serve one endpoint:
  `GET /auth/callback`. Parses the query via the existing shared parser
  (`ChatGPTOAuth.parseAuthorizationInput`), validates the `state` against the in-flight PKCE
  state (constant-time compare), and is strictly **single-use**: first valid hit captures and
  the listener stops; anything else gets a 404 and is ignored. Port already in use, listener
  failure, or timeout are all reported as typed outcomes — every failure path lands the UI on
  the existing paste fallback, never a dead end. Serves a minimal static success page; never
  logs or renders the code or tokens. Headless-testable end to end: start on an ephemeral port,
  hit it with `URLSession`, assert capture/rejection/single-use/shutdown.
- **`SignInFlowState`** — pure state machine shared by the UI:
  `idle → presenting(listening) → captured → exchanging → connected | failed(reason) | cancelled`.
  Cancellation (sheet dismissed) and timeout (generous — sign-in legitimately takes minutes;
  tied to the sheet's lifetime, not a short timer) both stop the listener immediately. Legal
  transitions unit-tested.

## P2 — Wire the sheet

- Present the provider's auth URL in an **in-app `SFSafariViewController` sheet** instead of the
  external browser; start the loopback server as the sheet appears, stop it whenever the sheet
  goes away, whatever the reason. On capture: exchange, dismiss, show the existing
  "Account connected" state.
- **ChatGPT** gets the full zero-paste path. **Claude** gets the same sheet treatment (no more
  bouncing to Safari), but keeps its paste step — its redirect is the provider's own hosted
  code page, so there is nothing for a loopback listener to catch; verify at build time whether
  the client permits a localhost redirect, and take the zero-paste path if it does.
- The paste field and the open-in-browser path **remain** as visible fallbacks (listener failed,
  user prefers their password manager's browser autofill, etc.). `DarkAccountSignInSection` /
  `OAuthSignInRows` grow the seamless path rather than being replaced — the model editor in
  Settings gets the same improvement for free.

## P3 — Design-language refresh ✅ shipped (as DG P2)

> **Scope note (2026-08-24):** the visual refresh is no longer onboarding-only — Plan DG owns an
> app-wide design language, and this phase is its onboarding slice (DG P2). DG P1's tokens and
> components land first so onboarding doesn't invent a one-off look; the criteria below stand.

- Restyle the onboarding **provider, credential, and model-selection pages** to current-iOS
  system idioms: system materials and grouped selection instead of hand-rolled opacity cards,
  native sheet presentation for sign-in, system typography scale, standard field affordances
  for the key-paste path. Reuse OGDesign components where they fit rather than inventing a
  third visual language; keep the app's existing accent conventions.
- The model picker that appears after a credential validates becomes a proper selection list
  (current custom ScrollView → native grouped list), consistent between onboarding and the
  Settings model editor.

**Landed** (see DG P2 for the full note): the flow lost `preferredColorScheme(.dark)` and now
answers the user's appearance setting; every list-shaped page is a real grouped `List` on the
warm canvas; the hand-rolled white slab button became the accent button, with its label picked
by measurement (`onAccentLabel`); `DarkAccountSignInSection` became
`OnboardingAccountSignInSection`, a grouped `Section` rather than a dark card — its sign-in
mechanics, sheet, capture and paste fallbacks untouched.

## Non-goals

- **Registering our own OAuth clients** with providers — the loopback capture makes it
  unnecessary for ChatGPT, and nothing else about the wire changes (Plan BW still owns the
  OAuth/backends contract; scopes, token exchange, storage are untouched).
- API-key providers gaining an account flow — they get the visual refresh only.
- Onboarding *structure* (page order, Back button, keyless default) — Plan DB, which lands
  first.
- The Settings/configuration progressive-disclosure journey — its own discussion and plan.

## Later notes

- **2026-08-27 — what a ChatGPT sign-in actually buys.** Device-traced confusion: signing in
  covers *conversation* on the plan (it unlocks the codex catalog for Direct mode) and nothing
  more. Live voice mode is a separate OpenAI product that accepts only a platform API key, so no
  app can reach it through a subscription sign-in. The sign-in section's caption says this on
  both sides of the connection, and the live-mode picker's refusal says it too when an account is
  connected (`ConversationModeAvailability.realtimeUnavailableReason`) — a generic "add a model"
  reads as a bug to someone whose plan advertises a voice mode.
- **2026-08-27 — the flow can now open on a welcome-back page.** A delete-and-reinstall keeps its
  Keychain and loses its `UserDefaults`, and the onboarding gate read the surviving credentials as
  "already set up" and skipped silently. That state now shows the flow with the first page in a
  welcome-back variant: "Restore my setup" (the old silent path, chosen) or "Set up fresh". Both
  exits set the completion flag and run the SDK-configure path, so nothing downstream of
  `isPastOnboarding` changes. See Plan DH P2, which shipped it.

## Security notes

Listener binds loopback only, exists only while a sign-in sheet is on screen, accepts exactly
one valid callback, and validates state before anything else. Codes and tokens never appear in
logs or in the served page. The success page carries no external resources.

## Open

- Whether the external-browser flow should also try the listener (app backgrounds → likely
  suspended → capture unreliable; leaning no — document that the seamless path is the sheet).
- Whether Google/Vertex sign-in (`GoogleOAuthService`) can share the same sheet + listener
  shape; check its registered redirect at build time.
