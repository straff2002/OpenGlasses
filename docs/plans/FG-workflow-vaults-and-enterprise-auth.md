# Plan FG — Workflow Vaults, Enterprise Authentication and Connected Tasks

**Status: 📝 Drafted 2026-09-13 — generic vault content prepared; connected functionality in P1–P12 remains pending.**

Enable organisations to adapt selectable vault workflows and connect their own authorised tools
using Microsoft Entra ID or a compatible OAuth/OpenID Connect provider. Retain OpenGlasses identity
and the existing provider architecture. Scope includes reusable content, authentication and gateway compatibility, with
no company-specific products, voice endpoint adapters, branding or distribution arrangements.

The final user journey is to select a workflow, find existing tasks, create a task from a reviewed
draft, assign it, add evidence or comments, change its status and verify completion through an
authorised connected system. Support both glasses voice and phone interaction. “Tasks” here means
records in a connected work-management system, not MCP protocol task execution handles.

Ship in increments: P0–P6 establish authenticated retrieval and drafts; P7–P8 deliver task creation;
P9–P10 deliver task management and recovery; P11–P12 deliver follow-up and release readiness.
Capabilities depend on the connected system and its permissions. Report unsupported operations
explicitly instead of promising identical features across all backends.

## P0 — Reusable vault content

The [aviation operations example](../../examples/vaults/aviation-operations/README.md) provides seven
selectable procedures: safety occurrence draft, manual lookup request, IT support intake, operations
handover, crew-record review, vendor renewal review and software task brief. Each produces a draft
for review. Organisations supply their own approved documents, review owners and permitted sources.

Keep manifests, procedure graphs and citations compatible with the existing importer and procedure
library. Document import, selection and adaptation. Do not embed endpoints, secrets or assumptions
about a particular organisation. Preserve the current team licence requirement for custom vaults.

Acceptance: an `ExampleVaultAviationTests` suite — modelled on the existing
`ExampleVaultLennoxTests` — decodes the seven procedures with the app's real `VaultManifest` and
procedure types and validates graph/citation integrity; then test folder import, procedure
selection, restart and completion on a device. Confirm missing sources are reported and no draft
completion invokes an external write.

## P1 — Shared OAuth and OpenID Connect connection model

Extend the existing MCP configuration and transport rather than creating another tool client.
HTTP MCP and bearer/custom headers exist; `MCPAuthKind.oauth.isAutomated` is currently false.

Separate OIDC sign-in identity from OAuth API authorization. Configure issuer, public client ID,
redirect URI, requested scopes and intended resource. Use authorization code with PKCE through
system browser authentication; never embed a client secret. Validate callback state, issuer and
OIDC nonce/ID-token claims when using OIDC. Send access tokens, never ID tokens, to APIs.

Implement supported MCP protected-resource/authorization-server discovery and resource binding.
Validate discovered URLs through the existing network policy before fetching them; do not forward
credentials across origins. Support administrator-provisioned client registration as the baseline,
and show a clear unsupported-configuration error rather than assuming every provider supports
automatic registration. Pin the supported MCP authorization revision during implementation.

Store tokens in Keychain, scoped by issuer, account, client and resource. Provide expiry handling,
single-flight refresh, reconnect, cancellation and disconnect with local credential removal.
Avoid replaying a potentially executed write after an authentication or network failure.

## P2 — Entra and generic provider setup

Offer an Entra preset with administrator-provided tenant, app registration and API scopes, plus
a generic standards-based setup. Show the connected organisation/account and requested access
before connecting. Explain when tenant consent or registration changes are required. Validate one
Entra deployment and one independent OIDC provider before describing support as interoperable.

Evaluate native library support against browser authentication, token lifecycle and Entra policy
requirements before choosing the implementation. Broker/device-compliance support must be tested
separately; do not promise that basic OIDC covers every Conditional Access policy.

Authentication does not unlock medical/commercial purchases, activate a team licence, approve a
tool action or establish upstream row-level isolation. Keep entitlement and action authorization
checks independent. The backend must enforce tenant/user access; shared upstream credentials
require an explicitly scoped trust boundary. Preserve local-only egress restrictions.

## P3 — Controlled rollout and validation

Start with synthetic records and read-only tool discovery/retrieval. Verify successful login,
cancelled consent, invalid state/nonce/issuer/audience, denied scopes, expired/revoked tokens,
refresh races, account/tenant switching and logout. Confirm no credential leakage in logs,
exports, prompts or requests to another resource. Test malformed discovery metadata and redirects.

On-device acceptance covers browser callback and app background/foreground transitions, cold
restart, network loss and a source-backed answer from the approved server. Test access denial
across accounts/tenants and ensure sign-in cannot bypass paid-feature locks. Later writes retain
payload review, explicit confirmation and verified receipts; uncertain outcomes need reconciliation.

## P4 — Gateway compatibility and workflow tool selection

Support administrator-operated OpenAPI-to-MCP gateways through the existing HTTP MCP client.
Reuse discovery, calls, server-qualified tool names and action authorization. Keep API conversion
and upstream credentials on the gateway; the phone holds only credentials for its approved gateway
connection. A hosted gateway service is outside this phase.

Allow each workflow to declare optional required tool capabilities, with an explicit mapping to
administrator-approved server/tool identities. Define this as a backward-compatible manifest
extension before implementation; existing vaults must still import without it. Imported declarations
are requests, never grants. Show missing capabilities and retain the local draft-only path.
Resolve offered tools as the intersection of workflow needs, administrator grants and current app
policy. Enforce the same restrictions at dispatch, not merely by hiding tools from the model.

Start from a reviewed operation allowlist. Writes require separate enablement and existing action
confirmation. Neither an HTTP GET method, a tool annotation nor a scope named “read” proves an
operation is harmless. Enforce permissions upstream as well as in the app, including user/tenant
record access; namespaces alone do not provide isolation.

Add tool-list refresh on reconnect and explicit user refresh; handle change notifications where
the negotiated transport supports them. Compare discovered definitions with the reviewed version.
New tools and materially changed schemas/descriptions require review before offering or dispatching
them. Remove withdrawn tools immediately and invalidate pending approvals tied to changed tools.
Distinguish refresh failure from an empty successful list. Cached definitions may remain visible
with a stale label, but changed/unverified capabilities must not silently become executable.

Expose connection, authentication and tool-catalogue freshness separately: sign-in required,
connected, refresh failed and unavailable should have actionable explanations. Do not assume every
MCP server exposes an HTTP health endpoint or interpret degraded readiness as a reason to restart.

## P5 — Generic gateway deployment example

Create a small, reproducible example backed by a maintained OpenAPI-to-MCP implementation, with
pinned dependencies, a synthetic support API and namespaced search/get operations. Include an
excluded write operation to demonstrate that configuration filters the advertised tool surface.
Keep the example vendor-neutral and use no real organisation data or endpoint configuration.

Provide administrator-owned configuration containing secret references, a container/run guide,
HTTPS deployment instructions and a documented trust boundary. Keep upstream credentials fixed
server-side; bound routing to approved origins/base paths, reject unapproved redirects and external
schema references, and prevent tool arguments from overriding credentials or destinations.

Demonstrate validated, atomic schema refresh using ETags/content hashes where supported. Retain
the last valid definitions when refresh fails and expose degraded readiness separately from process
liveness. Reapply operation policy on every refresh so a method/schema change cannot expand access.
Document credential rotation, rollback and the client refresh procedure. Public examples contain
only synthetic configuration; deployment secrets stay outside the repository and build context.

Acceptance: a clean setup exposes only approved tools; denied operations cannot execute through
direct calls; malformed/failed schema updates preserve the last valid catalogue without widening
access; routing and credential overrides fail. No production deployment is part of this plan.

## P6 — One complete vault-to-tool pilot

Use IT support intake from the generic vault. An administrator connects the synthetic support
gateway and maps ticket search/get capabilities. The user signs in, selects the workflow, describes
an issue, retrieves an authorised matching ticket with source/time, and reviews a local intake draft.
Completion explicitly says that nothing was submitted. Missing access or an unavailable gateway
must leave the draft usable and clearly identify which information could not be retrieved.

Validate on a phone with glasses after the synthetic API integration checks pass. Cover denied
account/tenant access, withdrawn or changed tools, failed refresh, expired login and interrupted
requests. Confirm that workflow selection cannot enable an unapproved tool, sign-in cannot unlock
paid features, and draft completion causes zero external writes. Record the tested gateway/client
versions and evidence before marking the pilot complete. Ticket submission is a later increment
with exact payload review, confirmation, stable request identity and a verified receipt.

## P7 — Task capability and record contracts

Define a common task representation: connection, organisation/workspace/project, stable remote ID,
title, description, status, assignee, priority, due date/time zone, source URL, last-updated time and
revision where available. Preserve backend-specific fields and status transitions through validated
capability metadata; do not force every system into one universal workflow.

Map reviewed MCP operations to search/list/get, create, edit, assign, comment, attach, transition,
complete and reopen capabilities. Archive/delete are separate optional destructive capabilities.
Discover required/custom fields, available people/projects and allowed transitions through approved
tools or administrator configuration. Never infer a tool mapping solely from its name. Keep a
traceable link from workflow draft to remote record and action receipt.

Add a connected task browser/detail view with search, pagination, filters, source links and freshness.
Support voice requests such as “find my open tasks” and “read the latest on this task”. Resolve
ambiguous matches and assignees before acting; use stable IDs after selection. Keep source content
as untrusted data, never as permission to invoke another tool.

Acceptance: duplicate titles across projects cannot cause misrouting; pagination does not omit or
duplicate records; unsupported fields/transitions are explained; dates preserve the intended time
zone; backend errors do not become empty task lists. Maintain existing draft-only vault behaviour.

## P8 — Reviewed task creation

Extend a workflow draft into an optional connected action. Select the destination, populate required
fields, resolve assignee/project and show or speak a concise preview. Allow editing and cancellation.
Ask for confirmation bound to the exact connection, account, destination, payload and tool version.
Any material change invalidates that confirmation. Reuse the existing action authorization router.

Persist action intent and a stable request identity before dispatch. Use backend idempotency where
supported, with reconciliation by receipt or client reference after interruption. A timeout is an
unknown outcome, not a failed create that can be blindly retried. If the backend supports neither
deduplication nor reliable lookup, stop and require outcome review before another create attempt.

After success, retain the remote ID/link and verify persisted fields through a read when available.
Distinguish backend-acknowledged creation from read-back verification; never announce completion
from a tool-name list or a queued response. Update the workflow record with the result. The original
draft remains available if permission, validation or connection fails.

Acceptance: create a synthetic task from glasses and from the phone; cancel before sending; reject
missing fields and denied destinations; double confirmation does not create duplicates; simulate
timeout after server commit and app termination around dispatch. Prove no write happens before
confirmation and no sign-in bypasses entitlement checks.

## P9 — Task updates, collaboration and completion

Add edits to title/description, assignment, priority and due date; comments; reviewed photo/document
attachments; supported status transitions, completion and reopening. Preview field differences or
comment/attachment content and the destination before confirmation. Announce the resulting remote
state only after receiving a valid result. Finishing a local procedure does not automatically close
its linked task.

Fetch current state before editing and use revision/ETag preconditions where supported. A conflict
requires a refreshed comparison and new confirmation. Where conditional writes are unavailable,
explain the concurrency limitation and avoid silently overwriting full records. Check attachment
size/type and permitted data; verify upload outcome and handle orphan uploads or partial failure.
Readback should summarise sensitive fields appropriately for the user's audio context.

Treat archive/delete and bulk operations as separately enabled capabilities with explicit item lists
and per-item outcomes. Prefer archive when supported; do not offer undo unless the backend can
actually reverse the action. A bulk failure must not replay already successful changes.

Acceptance: exercise every supported mutation, stale revision, revoked access, invalid transition,
wrong assignee and partial attachment/bulk failure. Verify task completion/reopening against backend
state and that cancellation leaves records unchanged. Unsupported actions remain unavailable.

## P10 — Durable drafts, action recovery and result history

Persist draft edits and a bounded action journal using existing protected storage patterns. Model
draft, awaiting confirmation, sending, acknowledged, verified, failed and outcome-unknown states
explicitly. Record connection/account, remote IDs, payload digest, request identity and timestamps;
exclude tokens and unnecessary sensitive content. Provide retention and deletion controls.

On restart or reconnection, reconcile interrupted actions before offering retries. Offline work can
save a draft, but cannot silently submit it later. Require a current review after material account,
permission, destination or tool changes. Cancellation after dispatch may mean the server still
completed the request; do not present it as a rollback.

Show understandable history: what was requested, what the server confirmed and what remains
unknown. Sign-out/account changes must not leak prior task data or queued actions to another user.
Coordinate durable execution with the existing remote-agent work rather than introducing competing
receipt or confirmation models.

Acceptance: terminate at each state boundary, restart offline, switch accounts and reconcile a
successful write whose response was lost. Verify bounded retention, protected storage and no
automatic duplicate or cross-account submission.

## P11 — Task follow-up and connected workflow templates

Allow users to revisit tasks linked to a workflow, refresh status and prepare a handover from
source-backed open items. Add opt-in due-date reminders and status-change notifications where the
backend and iOS delivery mechanisms support them. Specify polling/push support and background
limitations per integration; do not imply continuous monitoring when the app cannot provide it.

Offer reviewed templates for support intake, handover and software task briefs using the same
capability mappings. Keep administrative aviation examples as drafts unless the organisation
explicitly configures their authorised connected actions. No template grants operational approval.

Default notification content should avoid sensitive task details on the lock screen. Provide mute,
disconnect and per-workflow controls. Notifications open the correct task/account and never cause
an automatic mutation. Scheduled or autonomous writes are outside this plan's user-confirmed scope.

Acceptance: changing due dates updates reminders, completed tasks stop obsolete reminders, revoked
connections stop retrieval and stale notifications cannot act on the wrong account. Test source
freshness in handovers and graceful behaviour when background delivery is unavailable.

## P12 — Interoperability, rollout and definition of done

Extend the synthetic gateway fixture to include all mutation and failure scenarios above. Validate
one administrator-authorised real task integration in a non-production workspace, then a second
independent backend to prove that the contracts are reusable. Record the supported capability set
and explicit limitations for each. Revalidate Entra and generic OIDC paths against those boundaries.

Roll out read access, creation and subsequent mutation groups behind independently controllable
capability gates. Provide administrator setup, user help, revocation/rotation and rollback guidance.
Capture redacted diagnostics for auth, discovery, latency and outcome reconciliation without task
content or credentials. A disabled integration must preserve local drafts and prevent new calls.

Definition of done: a user can find, read, create, assign, edit, comment on, attach evidence to,
complete and reopen supported tasks from glasses or phone; results have remote identities and
truthful status; interruptions do not cause duplicate writes; permissions and paid-feature locks
remain enforced. Optional destructive/bulk and follow-up features ship only with their own passing
acceptance evidence. No phase is complete solely because the happy-path synthetic demo succeeds.

## Delivery and evidence

Proposed PR grouping: **PR1** P0–P3 (vault content plus the authentication core), **PR2** P4–P6
(gateway compatibility and the one complete pilot), **PR3** P7–P8 (task capability contracts and
reviewed creation), **PR4** P9–P10 (mutations, durable drafts and recovery), **PR5** P11–P12
(follow-up templates and interoperability). Each PR records its fixture evidence separately from
administrator-authorised backend evidence.

| Gate | Status |
|---|---|
| Aviation-operations vault decodes and imports with the app's real types | Pending |
| OAuth/OIDC connection model, PKCE and resource-bound authorization | Pending |
| Entra and generic provider setup, revocation and rotation | Pending |
| Controlled rollout and validation evidence | Pending |
| Gateway compatibility and workflow tool selection | Pending |
| One complete vault-to-tool pilot | Pending |
| Task capability discovery and record contracts | Pending |
| Reviewed task creation with request identity | Pending |
| Task updates, collaboration and completion | Pending |
| Durable drafts, action recovery and reconciliation | Pending |
| Follow-up templates | Pending |
| Second independent backend and interoperability | Pending |

For each gate record build/commit, fixture or connected workspace, result and remaining gap.

## Protocol references

- [Microsoft authorization code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow): native/public-client code flow, PKCE and token acquisition.
- [MCP authorization, 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization): discovery, PKCE and resource-bound authorization requirements.

Coordinate provider authentication with [AI](provider-auth-and-fallbacks.md) and vault retrieval
with [ED](ED-vault-manual-retrieval.md). This plan owns organisational MCP sign-in and reusable
workflow packaging and MCP gateway interoperability; it does not replace those existing workstreams.
