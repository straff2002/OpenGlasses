# OpenGlasses opportunity assessment

As of 26 August 2026, OpenGlasses has enough capability to become a differentiated product, but it does not need more tools. It needs a sharper consumer promise, dramatically simpler onboarding, production hardening, and a small set of dependable everyday experiences.

The strongest positioning is:

> A private, model-independent everyday copilot that can see what you see, remember what matters, and safely act across your digital life.

That separates it from Meta AI’s generic assistant through offline operation, user-owned memory, model choice, extensibility, and specialized workflows.

## Executive findings

1. **The market is real.** EssilorLuxottica reported more than seven million Ray-Ban Meta and Oakley Meta units sold during 2025. [EssilorLuxottica 2025 report](https://www.essilorluxottica.com/api/getCapContent/?download=false&id=284350)

2. **The market still lacks a clear daily purpose.** In a 4,000-person US survey, 50% cited “no clear need/purpose” as a deterrent, ahead of cost at 41%. [The Vision Council](https://thevisioncouncil.org/blog/latest-report-vision-council-shows-rising-awareness-smart-eyewear-recent-years)

3. **OpenGlasses has unusual technical breadth.** The repository contains roughly 120,000 lines of Swift application code, 40,000 lines of tests, and implementations spanning voice, vision, memory, automation, streaming, HUDs, accessibility, enterprise procedures, and 85+ native tools. The overview is in [README.md](../README.md#L5), while the conditional tool surface is visible in [NativeToolRegistry.swift](../OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift#L23).

4. **Distribution is the largest immediate constraint.** Meta still calls DAT a developer preview and documents release channels for test users rather than normal public distribution. [Meta DAT repository](https://github.com/facebook/meta-wearables-dat-ios) OpenGlasses itself correctly warns that App Store distribution is pending in [README.md](../README.md#L7).

5. **Trust and reliability are release gates.** Current plans document a critical composed-tool authorization bypass plus high-severity issues around conversation indexing, medical credentials, production logs, URL fetching, LAN services, and Field Assist entitlement. Those need to be fixed or the affected features disabled before any consumer or regulated release.

6. **The best near-term commercial opportunity is B2B Field Assist.** The largest eventual audience is the consumer everyday copilot, but controlled organizational pilots fit the current release-channel environment much better.

---

# What OpenGlasses can do today

“Implemented” here means substantial code and tests exist. It does not mean every path has been verified across every glasses model, firmware version, provider, and real-world environment.

| Capability | Current reality | Strategic value |
|---|---|---|
| Voice assistant | Wake words, push-to-talk, personas, barge-in, Siri/App Intents, Gemini Live and OpenAI Realtime | Strong foundation, but personas and modes should be hidden from ordinary users |
| AI choice | Anthropic, OpenAI-compatible providers, Gemini, local MLX models, self-hosted servers, automatic routing | One of the clearest differentiators from Meta |
| Fully offline loop | On-device SenseVoice speech recognition, local LLMs and Kokoro TTS | Highly differentiated for privacy, travel and poor connectivity |
| Vision | Glasses and phone camera, photos, preview, recording, OCR, barcode/QR, structured assessments, frame deduplication and vision memory | Strong, though dependent on evolving DAT lifecycle and hardware |
| Everyday actions | Calendar, reminders, notes, messaging, calls, navigation, music, smart home, search and utilities | Broad enough already; feature discovery and composition are the gaps |
| Memory | Conversations, semantic memory, object memory, social context, “brain,” document RAG and projects | Potentially the strongest consumer moat after privacy remediation |
| Accessibility | Reading, object/text recognition, low-vision navigation, colour/money identification, captions and assistive narration | High-impact and well aligned with glasses |
| Workflows | Playbooks, procedures, capture flows, task cards, agent planning and confirmations | Excellent B2B and advanced-user infrastructure |
| Display | Meta Display cards, captions, navigation and interactive tasks | Timely: DAT 0.7–0.9 added first-party Display support, Wi-Fi transport and richer lifecycle APIs. [Meta DAT changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/main/CHANGELOG.md) |
| Media | Meeting recording, transcription, teleprompter, RTMP, Twitch chat and WebRTC expert video | Attractive creator and professional niche |
| Extensibility | Custom tools, MCP, skill packs, voice-taught skills, OpenClaw/Hermes and agent harnesses | Powerful moat, but unsafe to expose broadly before stronger permission and reputation systems |
| Companions | Apple Watch, widgets, CarPlay, Live Activities, Siri and Spotlight | Useful for starting and recovering sessions without opening the phone |

Several advertised surfaces remain conditional:

- EVEN G2 has a backend abstraction and mock-tested protocol stack, but its BLE transport “ships dark” pending hardware validation. [Plan status](plans/README.md#L47)
- The app-side WebRTC expert implementation exists, but self-hosted signaling, TURN and expert infrastructure remain external requirements. [Plan status](plans/README.md#L25)
- Some diarization behavior and UI are incomplete, including a documented HIPAA runtime gap. [Plan status](plans/README.md#L56)
- Many tools only exist when their service, entitlement, device capability, or mode is active. That conditional registration is explicit in [NativeToolRegistry.swift](../OpenGlasses/Sources/Services/NativeTools/NativeToolRegistry.swift#L113).

## OpenGlasses’ defensible advantages

Meta’s own glasses already handle capture, calls, messaging, music, reminders, lists, translation, visual questions and limited navigation. [Meta voice-command guide](https://www.meta.com/ca/ai-glasses/learn/voice-command/) Generic parity will therefore be difficult to monetize.

OpenGlasses’ stronger advantages are:

- Local and self-hosted processing
- Provider independence rather than Meta-only intelligence
- User-owned long-term memory and document knowledge
- Extensible actions through MCP, Shortcuts and custom tools
- Professional procedures and structured data capture
- Cross-device output through phone, watch, CarPlay and multiple HUD backends
- Transparent routing, cost, egress and confirmation controls
- Accessibility features that can be customized rather than treated as isolated commands

---

# What everyday users actually need

The product should be organized around jobs, not tools or models.

## 1. “Keep me on top of my day”

Create one cohesive Everyday Briefing experience:

- Next appointment and travel time
- Important reminders and overdue tasks
- Weather relevant to upcoming activities
- One or two high-priority messages or updates where integrations permit
- Contextual prompts such as “leave in ten minutes”
- Evening recap and tomorrow preparation

Most of the primitives already exist: calendar, reminders, weather, location, scheduled tasks, digests, geofences and HUD cards. The missing work is orchestration, prioritization and a single configuration surface.

Do not claim to summarize every iPhone notification; third-party notification access is constrained. Start with data OpenGlasses can authoritatively access.

## 2. “Turn what I’m looking at into an action”

This should be the flagship visual interaction:

> “OpenGlasses, handle this.”

The assistant identifies the likely job and offers one action:

- Business card → create contact
- Event poster → create calendar event
- Receipt → save structured expense
- Tracking label → save tracking number
- Menu or sign → translate
- Product label → explain ingredients or compare options
- Document → scan, summarize or add to a project
- QR code → preview safely before opening

OpenGlasses already has most of these components. The opportunity is a dependable, reversible “see → understand → confirm → act” flow.

## 3. “Remember this for me”

Build a privacy-first memory product around explicit capture:

- “Remember where I parked.”
- “Remember I left the spare key here.”
- “What did we decide in that meeting?”
- “Where did I see that product?”
- “What was the name of the person I met at the conference?”
- “What was just said?” using a short, clearly indicated audio buffer

Memory should have visible provenance: when, where, how it was captured, and whether it came from voice, photo, meeting or imported content.

Avoid default continuous lifelogging. Recent egocentric-memory research shows strong potential for object finding, recall and life summarization, but continuous audio/video produces major power, consent and privacy costs. [LightMem-Ego research](https://arxiv.org/abs/2607.11487)

## 4. “Help me while I’m travelling”

Combine existing isolated tools into a Travel mode:

- Two-way speech translation
- Sign and menu translation
- Walking directions
- Currency and unit conversions
- Saved hotel, car and meeting locations
- Itinerary-aware briefings
- Receipt capture
- Local emergency information
- Offline language and voice packs

Translation is becoming platform-standard, but OpenGlasses can differentiate with broader provider choice, offline routing, saved context and action composition.

## 5. “Help me do this without using my hands”

Create guided modes rather than more generic prompts:

- Cooking: recipe steps, timers, ingredient recognition and short technique feedback
- DIY and repairs: step cards, parts capture and safety checkpoints
- Exercise: intervals and occasional form checks
- Shopping: list, comparison and allergen/preferences checks
- Reading/study: definitions, summaries, spaced repetition and page-aware questions

Camera use should be event-driven or low duty-cycle. Meta’s current DAT APIs explicitly expose battery, thermal and peak-power failure states, reinforcing that continuous vision cannot be treated as free. [Meta DAT changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/main/CHANGELOG.md)

## 6. Accessibility as a first-class product

This is one of the strongest opportunities, not a secondary settings toggle.

A 2025 study involving 25 people with vision impairment found significantly better completion odds for text tasks using AI assistive implementations and high overall satisfaction. [ARVO study](https://doi.org/10.1167/tvst.14.1.3) A 2026 study of older adults with cognitive impairment ranked audio reminders, phone calls, GPS and distress signals highest, while emphasizing a fast, intuitive audio interface. [JMIR Aging](https://aging.jmir.org/2026/1/e81840)

Recommended accessibility bundle:

- Instant scene, text and object description
- Find-an-object guidance
- Audio reminders and location cues
- Simplified calls and trusted-contact check-ins
- Distress action with location
- Colour, money and medication-label reading
- Walking assistance with conservative hazard language
- Caregiver-configurable Simple Mode
- Full VoiceOver and Dynamic Type support in the phone app

Meta is actively funding accessibility and workforce uses through nearly $2 million in grants to 30 organizations, suggesting meaningful partnership opportunities. [Meta Impact Grants](https://about.fb.com/news/2026/07/ai-glasses-helping-people-work-learn-live-independently/)

---

# Recommended prioritization

| Priority | Experience | Recommendation |
|---|---|---|
| P0 | Trust, security and reliability | Complete before consumer expansion |
| P0 | Keyless, five-minute onboarding | Default model or account sign-in; advanced providers later |
| P1 | [Everyday Briefing](plans/DY-my-day-everyday-briefing.md) | P0/P1 phone/audio MVP implemented; validate on device, then add leave-by |
| P1 | See → Action | Make this the flagship visual interaction |
| P1 | [Explicit private memory](plans/DX-private-memory-timeline.md) | High differentiation and repeat value; phone-first control surface after DK |
| P1 | Accessibility bundle | High impact, partner-friendly and defensible |
| P1 | Travel bundle | Strong, understandable consumer use case |
| P2 | Cooking, shopping and DIY guided modes | Build as composed routines using existing primitives |
| P2 | Creator suite | Teleprompter, recording, broadcast and chat readback |
| P3 | Public skill ecosystem | Only after signed packages, scoped permissions and reputation |
| Defer | Default facial recognition and “social dossiers” | High privacy and social-acceptance risk |
| Defer | Continuous visual/audio lifelogging | Power, consent, storage and regulatory burden |
| Defer | Consumer medical decision support | High liability; retain conservative informational flows |
| Hide | Remote coding agents and deep MCP configuration | Useful power-user features, not an everyday front door |

---

# Release blockers and trust work

The 2026-08-26 code-verified review recorded ten findings; each was re-checked against source and is now owned by a plan. The numbered findings map to plans as follows:

- **Finding 1 (Critical)** and **9 (Medium)** — composed actions bypass the high-impact authorization boundary, and a timed-out side-effecting call is reported as a failure while its effect may still land. A user-authored Siri Action reaches the same unguarded execution path as a skill pack. [DJ](plans/DJ-composed-tool-safety-and-execution-outcomes.md#L14)
- **Finding 2 (High)** — conversation recall maintains a durable plaintext FTS index that does not follow lock and deletion semantics. [DK](plans/DK-protected-conversation-recall-index.md#L13)
- **Finding 3 (High)** and **10 (Medium)** — FHIR credentials are stored in preferences and clinical export files lack a bounded protected lifecycle. [DL](plans/DL-medical-secret-and-export-lifecycle.md#L13)
- **Finding 4 (High)** — production logs can contain transcripts, tool data, QR values, home commands and callback URLs. [DM](plans/DM-privacy-safe-production-logging.md#L13)
- **Finding 5 (High)** and **8 (Medium)** — QR fetching and skill sideloading have redirect, DNS-rebinding and archive-allocation risks. [DN](plans/DN-outbound-fetch-and-sideload-hardening.md#L13)
- **Finding 6 (High)** — LAN MCP and browser HUD services use cleartext HTTP; the bearer token itself travels in the clear. [DO](plans/DO-local-network-transport-hardening.md#L13)
- **Finding 7 (High)** — Field Assist contains a production-reachable developer entitlement bypass. [DP](plans/DP-release-entitlement-boundary.md#L13)

One further trust item, raised in follow-up, now has its own plan: the app's privacy manifest asserts there is no crash-reporting SDK, but the linked wearables SDK reports crashes to its vendor by default and the `MWDAT` configuration in [Info.plist](../OpenGlasses/Info.plist#L92) contains no crash-reporting opt-out. (The DAT App Model is always on as of SDK 0.9.0 and its `DAMEnabled` key is ignored, so the analytics half is not a lever; the crash-reporting opt-out is.) [DQ](plans/DQ-third-party-telemetry-opt-out.md#L14)

Until these items are remediated and independently reviewed, avoid marketing language implying blanket “HIPAA-grade” or international legal compliance. Whether HIPAA applies depends on the app’s relationship with covered entities and business associates, while non-HIPAA health apps can fall under the FTC Health Breach Notification Rule. [HHS health-app guidance](https://www.hhs.gov/hipaa/for-professionals/special-topics/health-apps/index.html), [FTC guidance](https://www.ftc.gov/business-guidance/resources/complying-ftcs-health-breach-notification-rule-0)

---

# Commercial opportunities

## 1. Field Assist: best near-term revenue

This is the clearest product-market wedge:

- Hands occupied and attention must remain on the physical task
- Procedures and structured capture already exist
- Organizations can provision controlled workflows and domain vaults
- Audit trails and expert escalation have direct economic value
- Pilots fit Meta’s current test-user release channels

Target refrigeration, telecom/broadband, roadside service, facilities maintenance, inspection and equipment commissioning.

Initial pricing hypothesis: paid pilot plus approximately $100–250 per active technician per month, depending on workflow authoring, support, integrations and compliance obligations.

## 2. Consumer private copilot: largest long-term upside

Once public distribution is available:

- Free core for voice, capture and accessibility
- Paid Plus tier for advanced memory, routine packs, private sync and premium model routing
- Users either bring their own provider or purchase managed usage
- Local-only functionality should remain genuinely useful without subscription

A plausible test range is US$8–15 per month, but value should be validated against weekly retained routines rather than number of tools.

## 3. Accessibility partnerships

Keep core accessibility free. Monetize through:

- Charities and government programs
- Employer accommodation programs
- Training and support contracts
- Sponsored device distribution
- Custom organizational deployments
- Grants and research partnerships

This produces trust and distribution while serving users with unusually strong, concrete needs.

## 4. Creator bundle

Teleprompter, long recording, transcription, RTMP/WebRTC and chat readback form a coherent niche product for:

- Live streamers
- Reporters
- Trainers
- Tour guides
- Presenters
- Content creators

This can become a simpler paid add-on without exposing the general-purpose agent configuration.

## 5. OpenGlasses as a platform

Longer term, signed skill packs, workflows, vaults and device backends could become an ecosystem. However, launch this only after:

- Scoped permissions per pack
- Signed publishers
- Human-readable action summaries
- Network-domain disclosure
- Version and compatibility checks
- Revocation and kill switches
- Review and reputation mechanisms

---

# 12-month product roadmap

## Phase 0: release foundation

- Close or disable all DJ–DP security findings
- Remove unsupported compliance claims
- Add an authoritative capability/availability layer
- Default to ephemeral visual capture
- Add clear camera, microphone, recording and cloud-processing indicators
- Finish VoiceOver and app accessibility work
- Replace seven-step technical onboarding with a keyless first useful interaction
- Establish hardware/firmware regression testing across supported glasses

## Phase 1: everyday product

Ship three opinionated packs:

1. **[My Day](plans/DY-my-day-everyday-briefing.md):** briefing, reminders, calendar, location and evening recap
2. **Travel:** translation, directions, saved places, currency and receipts
3. **Access:** reading, object finding, navigation cues, reminders and trusted contacts

Make these more prominent than models, personas, tools and MCP.

## Phase 2: differentiated intelligence

- [Explicit memory timeline with provenance and deletion](plans/DX-private-memory-timeline.md)
- “Handle this” visual action flow
- Cooking, shopping and household routines
- Sensitivity-aware model routing: local for private content, cloud only with consent
- Battery and thermal budgeting that changes behavior before failure

## Phase 3: focused growth

- Field Assist design partners and paid pilots
- Accessibility organizations and research partners
- Creator bundle launch
- Prepare App Store submission as soon as Meta and Apple permit it
- Begin Android portability only after the iOS everyday loop demonstrates retention

Google’s Android XR glasses are moving toward camera/microphone assistance and optional displays, while Snap is entering the market with a US$2,195 spatial-computing product. [Google Android XR](https://blog.google/products-and-platforms/platforms/android/android-show-xr-edition-updates/), [Snap SPECS](https://investor.snap.com/news/news-details/2026/Snap-Inc--Debuts-SPECS-Augmented-Reality-Glasses-to-Make-Computing-More-Human/default.aspx) OpenGlasses should preserve a device-neutral core, but should not attempt to compete with full spatial AR.

## North-star metrics

- First useful glasses interaction within five minutes
- Session-start success above 95%
- No dropped first response
- Median voice-to-first-audio below two seconds for simple actions
- Three or more successful “phone stayed in pocket” tasks per active day
- Weekly repeat use of Briefing, See → Action or Memory
- Percentage of sensitive turns processed locally
- User-understood cloud/recording status in usability testing
- Successful recovery from disconnect, doff, thermal and provider failures

The essential strategic move is to turn OpenGlasses from a powerful toolbox into a dependable set of daily promises. The technology is already unusually capable; focus, distribution, reliability and earned trust are now the highest-leverage work.
