# Plan MH — App Store Compliance Gaps (a third-party checklist read against the store build)

**Status:** 🚧 P0 built 2026-11-18 (headless): the System Boot Time required-reason API is declared,
with a guard test that reads the sources, and the three paywalls state an eligible introductory
offer ("1 week free, then $4.99/month"). P1–P4 are not started. 6 decisions open.
**Track:** the phone-only App Store build (`OPENGLASSES_PHONE_ONLY=1`). Every change also reaches the
glasses build, where it does no harm.
**Builds on:**
- [`reports/app-store-2026.10/submission-checklist.md`](../../reports/app-store-2026.10/submission-checklist.md),
  the evidence still owed against the exact archive. This plan adds to that list and does not
  replace it.
- Roadmap W04.5 `PrivacyManifestReconciliationTests`, which now also checks required-reason APIs.
- The support report (`SupportReporting`, `SupportReportViews`), which P1 reuses.

---

## Trigger

The owner, 2026-11-18: look up a published App Store compliance checklist and review Avenkin
against it. The checklist has 93 items in 10 sections. Most are already met or already listed in
`submission-checklist.md`. The review found eight gaps. This plan fixes two of them in code now and
sequences the other six.

## The eight findings, and where each goes

| # | Finding | Guideline | Phase |
|---|---|---|---|
| 1 | `ProcessInfo.systemUptime` is used in 10 files, but the manifest does not declare System Boot Time (ITMS-91053) | 5.1 / manifest | **P0 ✅** |
| 2 | The paywalls never state a trial's length or the price after it | 3.1.2 | **P0 ✅** |
| 3 | There is no way to report an AI reply, and no published route for content complaints | 1.2, 4.7 | P1 |
| 4 | `HomeKit` and `CarPlay` are used as search keywords | 2.3.7 | P2 |
| 5 | The copyright names Skunkworks NZ Ltd while the seller is an Individual account, and the EU DSA trader status is not filed | 5.x / DSA | P2 (decision 1) |
| 6 | The Shared Location and Dating declarations (due 12 Jan 2027) and the new age-rating questionnaire are not done | 2026–27 | P2 |
| 7 | The review notes do not justify the `*.ts.net` plain-HTTP exception | 2.5 / ATS | P1 (notes) |
| 8 | There is no 5.2.2 evidence that a third-party app may use Claude subscription OAuth (`ClaudeOAuth`) | 5.2.2 | P3 (decision 5) |

## P0 — the manifest and the trial line (built)

- `PrivacyInfo.xcprivacy` declares `NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1`
  (elapsed time between in-app events, timers). `systemUptime` is the monotonic clock for camera
  stall recovery, job recording, the bounded HTTP client, My Day, Scan Assist and recipe-regex
  timeouts. It is never sent anywhere.
- `PrivacyManifestReconciliationTests.testEveryRequiredReasonAPIInTheSourcesIsDeclared` scans each
  target's sources (the app, the activity widget, the watch app, the watch widget) for the boot-time,
  disk-space and active-keyboard symbols. It fails when a symbol is used without its category
  declared in that target's manifest. The gap went unnoticed because the old test only checked a
  fixed list.
- `SubscriptionOfferTerms` turns a StoreKit introductory offer into one sentence for each payment
  mode: a free trial, pay as you go, or pay up front. `StoreKitService.introOfferEligibleIds` holds
  the products this account can still take an offer on, rechecked after loading and after a
  purchase. `offerTerms(for:)` returns nil when there is no offer or the account is not eligible,
  so a paywall never promises a trial StoreKit would not give. My Manuals, Field Assist and Medical
  Compliance show the line next to the price. The general "eligible subscribers" note stays.
- `SubscriptionOfferTermsTests` pins the wording.
- **Owed:** catalog sync for the new strings (on their own commit, as usual), and checking the line
  on a device in sandbox (P4).

## P1 — report a reply (headless app work, then site and notes)

- A **Report this reply** action on an assistant reply's context menu (`MessageBubble`). It opens
  the existing support report composer, scoped to that one turn: the question, the reply, the model
  and provider, and the build identity. It does not include the rest of the conversation unless the
  wearer adds it. The wearer reviews the report before sending, as with every support report.
- A pure `ReportedReplyScope` decides what goes in. A headless test proves that the report carries
  the turn and nothing else by default, and that a private conversation (Plan LU) still masks what
  it masks.
- `support.html`: a "Reporting an AI reply" section that gives the in-app route and the email, and
  says reports are read and acted on. This is the published complaint route that 1.2 asks for.
- Review notes: one line each on how to report a reply, on provider-side moderation (each provider's
  own filters apply), on the `ts.net` exception (Tailscale's WireGuard tunnel, used only for the
  wearer's own servers), and on skill packs and MCP not being executable app code. The notes are at
  3,767 of 4,000 bytes, so make room by trimming the Field Assist paragraph.
- **Not in scope:** blocking users or removing other people's content. There is no social feature.

## P2 — store metadata and declarations (owner, App Store Connect)

- **Keywords:** replace `HomeKit` and `CarPlay` with generic terms ("smart home", "car"). The
  description can keep saying the app works with them.
- **Copyright and seller:** fix the copyright line once decision 1 is taken.
- **EU DSA trader status:** file it for whoever the seller is. As an Individual seller this
  publishes an address and phone number on EU storefronts.
- **Shared Location and Dating/Relationships declarations**, due 12 Jan 2027. The recommended
  answer to both is "no": the app never shares a wearer's location with another user. A job sent to
  an expert carries a site address, but the wearer sends it through Messages, Mail or the share
  sheet.
- **Age-rating questionnaire:** answer it for an AI chatbot with web search, plus the first-aid,
  triage and medication tools. Record the answers in `submission-checklist.md`.
- **Social media capability declaration:** "no".

## P3 — evidence for third-party sign-in (owner)

- Confirm in writing that Anthropic's terms allow subscription OAuth in a third-party app, and keep
  that confirmation with the 5.2.2 evidence. If it can't be confirmed, compile `ClaudeOAuth` out of
  the phone-only build. API keys keep working either way. This is decision 5.
- Google sign-in connects a service; it is not an app account, so the Sign in with Apple rule does
  not apply. Check that signing out of Google deletes its tokens from the Keychain.

## P4 — device pass

On the exact phone-only archive, with a sandbox account:
- Check the trial line on each paywall for an account that is eligible, then confirm it disappears
  once the offer has been used.
- File a report from a reply.
- Watch for any ITMS-91053 email after the upload.

## Decisions open

1. **Seller entity.** Stay an Individual (the copyright names the account holder, and the trader
   address is a personal one) or move to an Organisation account for Skunkworks NZ Ltd before
   launch. *Recommendation:* decide before the first public release; an Organisation account needs
   a D-U-N-S number and takes weeks.
2. **Replacement keywords.** *Recommendation:* "smart home,car".
3. **Shared Location answer.** *Recommendation:* no.
4. **Report destination.** The email in `support.html`, or a form on avenkin.com.
   *Recommendation:* email, through the existing report composer.
5. **Claude subscription OAuth in the store build.** Keep it with written evidence, or compile it
   out. *Recommendation:* compile it out of the phone-only build unless the evidence is in hand.
6. **Trial wording when eligibility is unknown** (StoreKit has not answered yet). *Recommendation:*
   show nothing, as built, rather than "may include a free trial".

## Non-goals

- Treating a third-party checklist as Apple's word. Where they differ, Apple's guidelines win.
- Re-running the items `submission-checklist.md` already owns.
