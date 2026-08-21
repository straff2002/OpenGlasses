# Plan CT — Organisation Configuration Profiles (scan once, configured correctly)

**Status:** 📝 Drafted (not scheduled), 2026-08-09
**Depends on:** Plan F/licensing primitives (Ed25519 verification), Plan BX (signed-manifest +
lossy-decode precedent), Plan BM P10 (`OwnerGateMachine`), Plan CD P1 (the onboarding-flag hazard)
**Related:** Plan CS (watch propagation), Plan CR P4 (enrolment endpoint, for the secrets half)
**Shape:** pure schema + applier first (P1), three ingress adapters (P2), onboarding + managed-state
UI + watch propagation (P3), enrolment endpoint deferred (P4)

---

## The ask, and the gap

An organisation — a museum, a field-service contractor, a hospital ward, a training provider — wants
to hand someone a device and have the app come up configured: the right capabilities on, the wrong
ones off, the right gateway, the right vault, the right mode. Today the only route is a person walking
through [`OnboardingView`](../../OpenGlasses/Sources/App/Views/OnboardingView.swift)'s seven pages and
then through Settings, by hand, per device, correctly, every time.

The primitives for the fix are almost all already here:

| Needed | Already shipped |
|---|---|
| Signed payload the app can trust | [`LicenseService`](../../OpenGlasses/Sources/Services/LicenseService.swift) — `base64(payload).base64(sig)`, Ed25519, public key embedded, private key off-repo, generator script; and `SkillPackSignature` over a manifest |
| Trust posture for a QR-delivered link | [`SkillPackSideload`](../../OpenGlasses/Sources/Services/SkillPacks/SkillPackSideload.swift) — deliberately *not* token-gated because a QR cannot carry the `DeepLinkTrust` app-group token; the compensating control is that the link never acts, it presents identity + signature status and a human confirms |
| QR decoding | `VNDetectBarcodesRequest`, used in three tools already |
| A gate between the user and Settings | [`OwnerGateMachine`](../../OpenGlasses/Sources/Services/OwnerGate.swift) (BM P10) + Simple Mode |
| A precedent for policy removing capabilities | HIPAA mode — an external policy hard-disables features and the app says so |

**So the QR is not the hard part.** The hard part is that
[`Config.swift`](../../OpenGlasses/Sources/Utils/Config.swift) is 3,277 lines of 45
`@UserDefaultsBacked` properties plus a long tail of hand-written accessors, with **no export, no
import, no versioning and no enumerable schema**. A profile cannot be applied to a settings surface
that cannot enumerate itself. That is the work; everything else is adapters.

The one genuinely new UI piece is a live-camera QR scanner — every existing decode path reads a
*captured* frame (glasses camera or a still), and there is no scanner view.
[`PhoneCameraView`](../../OpenGlasses/Sources/App/Views/PhoneCameraView.swift) already wraps
`AVCaptureSession`, so this is small.

## Identity is per-person; policy is per-device

The profile answers *what this device may do*. It does not answer *who is holding it* — a person still
signs in as themselves, and the two must not be conflated. That separation is what makes a shared
device (a ward handset on a shift rota, a museum handset per visitor, a contractor's pool phone)
coherent rather than a pile of leftover state.

**Today the app has no user identity at all.** `ClaudeOAuthService` and `ChatGPTOAuthService` sign you
in to an *LLM provider*; StoreKit entitlements are Apple-ID scoped; `LicenseService` is device-scoped
and offline. There is no `UserAccount`, no account service, nothing that names a person. So "log in as
a user" is a capability this plan assumes and does not itself build — the natural home is Plan CR's
gateway, which is already `token:userId` with a per-user memory store, vault and session. CT's job is
to make sure that when identity arrives, it cannot widen the envelope.

Three consequences, each of which changes the design rather than decorating it:

1. **A user signing in must never widen the device.** Hence ceilings rather than pins. The user gets
   their own history, memory, connected apps and preferences *inside* the org's envelope.
2. **The envelope must cover provider and credential configuration, or it is theatre.** If a person
   can paste a personal API key, they route around the org's model policy; if they can add their own
   gateway, they route around its egress policy. So "which providers may be used" and "may the user
   add providers, gateways or MCP servers at all" are ceiling dimensions, not ordinary settings.
3. **Sign-out clears the person, keeps the policy.** The exact inverse of profile removal, which
   clears the policy and restores the person's prior values. Getting these two backwards is how a
   device ends up either leaking the last user's data or silently unmanaged.

## Three ingress paths, one schema

Worth stating up front because it changes the shape of P2 and costs almost nothing extra:

- **QR** — the asked-for path. Orgs without device management: museums, contractors, BYOD field teams,
  a code printed on a workshop wall or a laminated card in an equipment case.
- **Managed App Configuration** — the Apple-native path (`com.apple.configuration.managed`, written
  into the app's `NSUserDefaults` by the MDM). We support **none of it today**. For an organisation on
  Jamf/Intune/Kandji this is strictly better than a QR: zero-touch, nothing to scan, and policy can be
  changed remotely without touching a device. It is also roughly thirty lines to read.
- **Deep link** — the same profile emailed or messaged rather than printed.

Build the schema and the applier once; all three are thin adapters onto it. That turns an onboarding
convenience into an actual deployment story.

## Non-goals

- **Becoming an MDM.** We are a *managed app*, not a management platform. No enrolment of the device
  itself, no remote wipe, no inventory.
- **Building the user-account system.** One device, one active *policy* profile; identity is a
  separate axis and its home is Plan CR's per-user gateway. CT defines how policy clamps identity, not
  how identity works. Per-user *settings* profiles with PIN switching remain Plan AJ's deferred
  "profiles + PIN".
- **Downloaded code or behaviour.** A profile sets values and locks; it does not add tools, prompts or
  procedures. That is what Plan BX skill packs are for, and they have their own signing and install
  trust decision. A profile may *reference* a pack; it may not embed one.
- **Secrets in the profile.** Structural, see below.
- **Silently locking a device.** A managed device says so, on screen, always.

---

## P1 — Pure core (headless, no wiring)

### `ConfigProfile`

Versioned, `Codable`, signed. Fields: profile id, org display name, schema version, issued date,
**two expiry dates** (below), an optional skill-pack reference list, an `entitlements` map, and the
settings themselves as `[SettingKey: ManagedValue]` where:

```
ManagedValue = { value: ProfileValue, disposition: .default | .ceiling }
```

**The disposition is the field that decides whether this is a good feature**, and it is deliberately
not a boolean `locked`.

- `.default` — the org sets a starting value; the user may change it afterwards. A museum handing out
  devices wants this.
- `.ceiling` — the org sets a bound that **nothing downstream may widen**. Not "the org picked this
  value" but "this capability is not available on this device, whoever is holding it."

The distinction is not stylistic. The moment a person signs in (below), a pin and a ceiling behave
differently: with pins, whichever write happens last wins, so the outcome depends on the order of
enrolment, login, entitlement restore and settings sync. With a ceiling, **policy can only ever
subtract**, so the result is the intersection of org policy and user preference regardless of the
order they arrived in. Order-independence is what makes this auditable — an org can state what a
device can do without having to reason about the sequence of events on it.

Concretely: `.ceiling(privacyFilterEnabled: true)` means the blur cannot be turned off; a user
toggling it sees a locked control with the org name as the reason.
`.ceiling(remoteInvokeCaptureEnabled: false)` means no configuration, no login, no skill pack and no
future feature can grant remote capture on this device. A lock is never invisible — it renders with
its reason, per the rule CQ P0 and CS P1 both landed on.

### `SettingKey` — the org-settable surface

An explicit allow-list enum, not a string passthrough onto `UserDefaults`. Three reasons, in order of
importance:

1. **Secrets must be structurally impossible.** A QR is a photograph — it gets Slacked, printed,
   photographed, left in a camera roll. `Config` already maintains the authoritative inventory of what
   counts, in `migratableStringSecretKeys` (`anthropicAPIKey`, `openAIAPIKey`, `elevenLabsAPIKey`,
   `perplexityAPIKey`, `openClawGatewayToken`, `homeAssistantToken`, `broadcastStreamKey`,
   `expertTurnCredential`) and `migratableDataSecretKeys` (`savedModelConfigs`, `savedGateways`,
   `mcpServers`, `customAgentHarness` — each of which embeds a credential inside a JSON blob). None of
   those may be `SettingKey` cases, and a test asserts the two lists stay disjoint so a future key
   added to one cannot quietly appear in the other.
2. An arbitrary key/value write into `UserDefaults` from a scanned code is a remote-configuration
   primitive for anything the app stores, including flags that were never designed to be
   externally set.
3. It gives the profile a schema to validate against, which is what makes the report below possible.

Deliberately small first cut: the capability toggles and feature gates (`privacyFilterEnabled`,
`glassesDisplayEnabled`, `accessibilityModeEnabled`, `simpleModeEnabled`, `audioOnlyMode`,
`mcpServerEnabled`, `agentModeEnabled`, the `remoteInvoke*` trio, the fingerspelling and
visual-state families), plus non-secret endpoints (gateway host/port, Hermes bridge host/port) and
vault/procedure-pack selection. Everything else is a later addition, and adding one is one enum case.

### `ProfileApplier`

Pure: `apply(profile:, to: ConfigSnapshot, now:) -> ApplyResult`. No `UserDefaults` in the decision
path; the caller commits the result. `ApplyResult` carries the settings to write, the lock set, and a
**lossy-decode report** — BX's rule, which is the right rule here for a sharper reason than usual: a
profile is written by an org against one app version and scanned on another, so unknown keys and
out-of-range values are the *normal* case, not the exceptional one. Named drops, never silent, and the
report is surfaced to whoever is holding the phone at enrolment.

Precedence, stated once and tested: **managed app config > profile > user**, with ceilings applied as
a final clamp rather than a layer — a ceiling is not outranked by anything, including a later
managed-config *default*. An MDM-managed device whose administrator changes policy must win over a
profile scanned last month, and both win over a local preference. A profile arriving on a device
already under MDM management is reported, not silently merged.

### `PolicyEnvelope` — the clamp, and when it runs

The applier's ceiling output is a standing envelope, not a one-time write. It re-clamps on **every
identity or entitlement change**, not just at enrolment:

| Event | Why it must re-clamp |
|---|---|
| Sign-in (provider OAuth, gateway identity) | a person's own configuration must not widen the device |
| Sign-out / user switch | the next person inherits policy, not the last person's settings |
| IAP entitlement change or restore | a purchased tier must not unlock what the org forbade |
| License code entered | same, for the offline B2B path |
| Managed config updated by the MDM | policy changed under a running app |

A one-shot apply looks correct in testing and fails in exactly the case this plan exists for: someone
signs in an hour after enrolment and their own settings quietly restore a capability the org removed.

### Entitlement rides the profile — one artefact, bought once for the fleet

**Decided:** the org's code is both the configuration *and* the licence. An organisation buys for
everyone it deploys to, so the artefact that bounds a device is the same one that entitles it. There
is no per-seat activation, no seat-management system, and no reason for a person's login to carry
entitlement — login stays purely identity and personalisation.

This is cheaper than keeping them apart, not more expensive, because they are already the same
primitive. [`LicenseService`](../../OpenGlasses/Sources/Services/LicenseService.swift) verifies
`{feature, expiry}` under an Ed25519 signature with an embedded public key; `ConfigProfile` verifies
`{settings, expiry}` the same way. Merging is one payload type and one verification path instead of
two. The join on the consuming side already exists too: `VaultRegistry` gates on string ids
(`field_assist_refrigeration`, `field_assist_it`), so an org grant slots into the gating that ships
today.

Nor is it a new bypass of StoreKit. Field Assist is *already* unlockable by an offline signed code as
well as by `com.openglasses.field_assist` — the org-purchase path is shipped and this is the same path
with better ergonomics. What changes is the ergonomics only: one scan instead of a purchase flow plus
a code emailed to whoever set the device up.

**Why this is safe here specifically, and would not be as an inline code.** P2 already decided the QR
carries a *pointer*, not a payload. So a photographed poster yields a URL, not a bearer credential —
and that buys three properties an inline licence QR could never have: the hosted profile can be
**revoked** (delete it and the next fetch fails), **rotated** (a lost poster is a new URL, not a new
entitlement), and optionally **bound at first fetch** to the devices that actually enrol. An inline
licence in a wall-mounted QR would be a bearer token on a wall, and I would argue against it.

The offline cost is one round trip: enrolment needs connectivity, after which the verified profile is
cached and works offline indefinitely — which is what Field Assist actually needs, since enrolment
happens at the depot and the work happens in the field.

**Two clocks, not one.** `policyExpiry` and `entitlementExpiry` are separate fields, because a lapsed
subscription must not unmanage a device (the capability bounds are a safety property, not a paid
feature) and a rotated policy must not revoke a licence the org has paid for. Merging them into one
date is the mistake that turns a billing event into a compliance incident.

### `ProfileVerification`

Reuses the license primitive directly — same Ed25519 verification, with **domain separation in the
signed bytes** (a typed prefix per payload kind) and a signing key distinct from the consumer licence
key, so an org profile and a consumer licence code can never be replayed as one another and
compromising either key does not yield the other. Both expiries are checked here, independently, and
an expired profile is a *refusal with a reason*, never a silent no-op: an org that let one lapse needs
to hear which clock ran out, from the device.

---

## P2 — Ingress adapters

- **Scanner view** — the one new UI component. `AVCaptureSession` + `AVCaptureMetadataOutput`, on the
  phone, torch toggle, and it does nothing but hand a decoded string to the parser.
- **`openglasses://enrol?url=…&sig=…`** — parsed by the same shape as `SkillPackSideload`, reusing its
  source policy verbatim (HTTPS anywhere; plain HTTP only to a private/LAN host). Not
  `DeepLinkTrust`-gated, for the reason that file already documents, with the same compensating
  control: it fetches and verifies, then presents.
- **Managed app config reader** — `UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")`,
  observed rather than read once, because an MDM can update it mid-session.

**The QR carries a pointer, not a payload.** A version-40 QR tops out near 2,953 bytes at the weakest
error correction, and a code meant to be scanned reliably off a printed card at arm's length wants to
be well under half that; after JSON, base64 and a 64-byte signature, an inline profile realistically
fits a few dozen settings and no more. So the default form is a signed URL the app fetches over HTTPS,
with inline profiles supported for genuinely small ones. This is also strictly better operationally:
the org updates the hosted profile without reprinting anything.

---

## P3 — Onboarding, managed state, watch

### The first-run branch

A "Configure with a QR code" option on the welcome page, ahead of the provider/key pages, because the
whole point is skipping them.

**The trap here is a live crash class we have already been bitten by.** Plan CD P1: `needsOnboarding`
is `!hasCompletedOnboarding && !hasAnyAPIKey`, so anything that causes a key to exist *before*
onboarding finishes leaves both flags unset — the screen never reappears, nothing calls
`Wearables.configure()`, and MWDAT answers an unconfigured `Wearables.shared` with `fatalError`. An
enrolment path that applies settings mid-onboarding is exactly that hazard wearing a new hat. So:
enrolment funnels through `WearablesBootstrap`, sets `hasCompletedOnboarding` *explicitly* rather than
relying on the derived flag, and a test asserts that a profile applied at first run leaves the app in
the same flag state as completing onboarding by hand.

### Managed state, visible

- A persistent "Managed by ⟨org⟩" row in Settings, with the profile's issue date and expiry.
- Locked controls render locked with the org name as the reason — never merely disabled.
- **Removal is possible and owner-gated.** An organisation must be able to un-manage a device, and a
  person must be able to leave. Removal composes with `OwnerGateMachine`: it is a device-owner action,
  and it restores prior values rather than leaving the org's settings behind as unexplained defaults.
  A profile that could not be removed would be malware with a nicer name.

### Watch propagation

The profile rides the same phone→watch application-context channel Plan CS P2 defines. Locks must
travel with it: a capability disabled by policy on the phone but live on the wrist is a hole in
exactly the boundary the policy was drawn for — the same reasoning as CS's HIPAA revocation note, and
it fails the same way.

The watch has no camera and cannot scan, and WCSession already provides an authenticated channel
between exactly the right two devices. A QR there would be strictly worse than what exists.

---

## P4 — Deferred

- **The credential half — and per-user login resolves it more cleanly than a shared secret.** A
  profile cannot carry credentials, and with per-person identity it does not need to: the profile
  names *which* org gateway to authenticate against, and the person's own sign-in supplies the
  credential. That is strictly better than a shared enrolment secret, which would be one credential
  for every device that ever scanned the poster, unattributable and unrevocable per person. Plan AR's
  `SetupCode` remains the right shape for the shared-appliance case (a kiosk with no person to sign
  in), against Plan CR's endpoint. Until identity lands, an org-configured device is correctly
  *bounded* but still needs its credential entered once — which is a smaller gap than it sounds,
  because the bounding is the part that was impossible before.
- Device verification: printed-code scan distances and lighting, and the honest failure when a code is
  damaged or partially obscured.
- An authoring tool for profiles (a script mirroring the license generator, plus a QR renderer).

---

## Traps

| Trap | Consequence |
|---|---|
| Applying settings mid-onboarding | reproduces CD P1's flag desync — onboarding never reappears, `Wearables.configure()` is never called, the app fatals on Connect |
| Arbitrary key passthrough instead of an allow-list | a scanned code becomes a write primitive for every value the app stores |
| A secret key added to `Config` and to `SettingKey` | a credential becomes photographable; the disjointness test is the only thing that catches it |
| Applying the envelope once at enrolment | someone signs in an hour later and their own configuration restores a capability the org removed — the exact case this plan exists for |
| Ceilings that stop at feature toggles | a personal API key or a self-added gateway routes around the model and egress policy entirely |
| Sign-out that clears policy, or removal that keeps it | the two are inverses; swapping them leaks the last user's data or silently unmanages the device |
| One expiry covering both policy and entitlement | a lapsed subscription unmanages the device, turning a billing event into a compliance incident |
| An inline licence in the QR rather than behind the fetch | a bearer credential on a wall — no revocation, no rotation, no binding |
| Locks that don't reach the watch | policy holds on one device and not the other, silently |
| No removal path | the device is permanently owned by whoever printed a poster |
| Inline payload instead of a pointer | the profile stops fitting, or the code stops scanning, at exactly the size a real org needs |
| Read managed config once at launch | an MDM policy change lands next launch, or never |

---

## Open questions

- **How much of `Config` is org-settable, eventually?** The first cut above is deliberate and small.
  The full audit is a judgement call per setting, not a technical problem, and it does not block P1.
- **Should a profile be able to require a skill pack?** Referencing one is easy; *installing* it
  unattended crosses BX's line that install is the trust decision. Leaning: the profile names the pack
  and the enrolment screen presents it as part of the same human confirmation, so one decision covers
  both.
- **Does an expired profile revert or freeze?** Reverting silently changes a working device's
  behaviour; freezing leaves an unmanaged device configured by a lapsed policy. Leaning freeze plus a
  visible "management expired" state, because a device changing behaviour on its own in the field is
  the worse surprise.
- ~~Does org membership carry entitlement?~~ **Resolved:** entitlement rides the profile, device-scoped
  and org-purchased — see *Entitlement rides the profile* above.
- ~~Which tiers may an org grant?~~ **Resolved 2026-08-09.** Two grantable, one not:
  - **Field Assist** — already works this way; nothing changes but the ergonomics.
  - **Medical Compliance** — grantable as an org site licence. This is the coherent shape anyway: a
    ward buys the tier *and* pins HIPAA mode as a ceiling, and those are the same purchase rather than
    a licence plus a separate configuration step someone has to remember.
  - **Accessibility** — not grantable, because there is nothing to grant. It is free (Plan A), and a
    profile must never be able to *withhold* it either: accessibility settings are excluded from
    `SettingKey` in the ceiling direction, so no org policy can take assistive features away from the
    person holding the device.

  What remains is a price, not a decision: a Medical Compliance fleet licence has to mirror or
  deliberately depart from the per-region IAP pricing, and that is a sales question, not a schema one.
- **Should the profile be able to set HIPAA mode?** Leaning firmly yes, `.ceiling`-only (pin it on,
  never off), because a Medical Compliance site licence and a pinned HIPAA mode are the same purchase
  — see above. It is still the most consequential toggle in the app, so it wants its own review rather
  than a line in a settings table, but the direction is no longer in doubt.
