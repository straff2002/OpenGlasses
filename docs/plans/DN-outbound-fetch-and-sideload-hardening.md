# Plan DN — Outbound Fetch and Skill-Pack Sideload Hardening

**Status:** 🟡 In progress — P0–P3 engineering checkpoints implemented 2026-09-06; focused runtime, Release-artifact and physical-device network evidence remain.
**Origin:** 2026-08-26 adversarial review findings 5 (High) and 8 (Medium).
**Priority:** P0 for QR redirects/DNS; do not approve distribution of the re-enabled hardened paths until the compiled adversarial suite and device evidence pass.

This plan creates one bounded, redirect-aware outbound fetch substrate for untrusted QR and skill-pack
URLs, and a streaming archive reader that enforces limits before allocation. A deep link is an offer to
review a download, not permission to contact its server.

## Implementation checkpoint — 6 September 2026

- `UntrustedNetworkFeaturePolicy` routes QR context, signed catalog/archive and remote skill-pack
  deep-link fetches through named hardened profiles in both Debug and Release. Release has no private
  HTTP profile. A private-HTTP skill-pack profile exists only under `#if DEBUG`, accepts only private
  addresses and never follows redirects; the fail-closed refusal decision remains available as a
  rollback/test seam.
- `BoundedHTTPClient` resolves each hostname once per hop, rejects the entire answer set when a public
  destination contains any private/reserved address, connects to an approved numeric address and
  preserves the original host for TLS SNI and certificate verification. It parses HTTP/1.1 itself,
  follows at most three redirects after re-running URL/DNS/address policy, rejects HTTPS downgrade and
  redirect loops, disables HTTP content coding, and enforces profile MIME and streamed byte ceilings.
- In builds where sideload fetching is permitted, receipt of a link now creates a non-network download
  offer showing only the normalized origin and 8 MiB limit. The approval is bound to the exact request,
  expires after five minutes and is consumed before fetching, so it cannot be replayed. Credentials and
  URL fragments are rejected. The existing post-inspection install confirmation remains the second gate.
- Skill-pack archives are rejected before extraction when compressed input exceeds 8 MiB, entries exceed
  128, an entry exceeds 4 MiB, declared aggregate output exceeds 32 MiB, per-entry compression exceeds
  100:1, paths are noncanonical/too deep/too long/duplicate, or entries are encrypted, symlinks, nested
  archives, special Unix file types/type masquerading, or use unsupported methods. Stored/deflated
  output must match declared size and CRC. Central/local names, flags, methods, sizes and CRC values must
  agree; the central directory must end exactly at EOCD; descriptors and physical ranges must be valid
  and non-overlapping; ZIP64 and multi-disk layouts are refused.
- Consented bytes are stored in a protected, backup-excluded staging directory. Backgrounding or
  dismissal cancels and invalidates the flow and removes staging; service startup removes abandoned
  UUID sessions left by process termination. The install prompt is single-use; installation reloads
  the staged archive, verifies its SHA-256 digest and re-extracts those exact bytes.
- The production downloader streams response bytes through a 32 KiB rolling buffer and enforces the
  8 MiB compressed cap during receipt instead of buffering the network response in memory.
- The store's production signature, manifest, definition-scanner and admission checks now run before
  the install prompt. The prompt enumerates origin, archive hash, action names, native/procedure/remote/
  hardware capabilities, settings and validation warnings; install repeats validation over the exact bytes.
- Protected staging maps the already-capped archive instead of copying it into heap. `ZipArchiveReader`
  streams stored and deflated content through 32 KiB chunks into a caller sink, decrements actual output
  budgets before delivery and calculates CRC incrementally. `SkillPackArchive` may still materialize
  approved files after these checks, bounded to 4 MiB each and 32 MiB total.
- Nine bounded-client tests cover address pinning, mixed DNS, hop re-resolution, public-to-private and
  downgrade redirects, loops/count, URL credentials/fragments/ports, MIME/content coding/declared length,
  chunk streaming/overflow and stacked transfer coding. The archive corpus now includes central/local
  mismatch, exact central-directory bounds, physical overlap and Unix special-file/type-masquerade cases,
  in addition to the existing size, traversal and CRC cases. Consent/lifecycle/tamper/recovery/budget
  coverage remains in the sideload suite.
- Xcode-beta successfully compiled and linked the arm64 Debug app and complete test bundle after these
  changes. The 60-test focused selection could not begin in two attempts: a new iOS 27 simulator timed
  out while preparing to boot, and an existing booted simulator remained blocked waiting for workers
  to materialize. Both produced infrastructure failures with zero XCTest cases executed.
- Xcode-beta build `27A5228h` successfully produced the current unsigned arm64 Release simulator app.
  Its 136,425,544-byte Mach-O has SHA-256
  `ec32f1eb275856c43f36e4cf76d116ffa01d3df384f3e5aa4332e299cc84eb1a`. Inspection found the public
  `qrContext`, `signedCatalog` and `skillPack` profile strings and bounded-fetch policy messages; the
  Debug-only `internalSkillPack` literal was absent.
- Remaining evidence/work: run the compiled suite in a functioning simulator/CI host; add distinct
  first-byte/idle deadline and TLS-hostname failure cases; validate the manifest before materializing
  optional files; inspect a signed installed Release artifact; and capture real-device
  DNS/redirect/private-address behavior. MCP/custom-model/gateway/FHIR and other clients remain a
  separate W02.3 inventory.

---

## Assessment-baseline problem and verified path

At the assessment baseline, `URLFetchGuard` rejected literal loopback/private hosts but did not resolve DNS.
`QRContextTool` validated only the initial URL and then used `URLSession.shared.data(from:)`, which followed
redirects automatically. A public-looking hostname or redirect could therefore reach localhost, LAN,
link-local, metadata-like, or other non-public addresses.

At that baseline, skill-pack deep links were handled outside the ordinary trust gate and began downloading before the
install confirmation. Downloads were buffered in full. `SkillPackCatalog` enforced one cap —
`maxEntryBytes` (5 MiB) per entry, and only *after* the entry was allocated and inflated; there was no
total-archive cap, entry-count cap, or ratio cap. `ZipArchiveReader.inflate` allocated
`Data(count: entry.uncompressedSize)` straight from the archive's central-directory metadata before
any of that, so a single entry declaring a huge uncompressed size triggered the full allocation before
the 5 MiB check could reject it. A crafted link could cause network disclosure, memory/disk pressure, or a
zip bomb before the user has meaningfully consented.

At that baseline, `URLFetchGuard.validate` was called from exactly one place — `QRContextTool`. The
skill-pack sideload and catalog fetches called `URLSession.shared.data(from:)` **with no `URLFetchGuard`
check at all**; the sideload URL was gated only by `SkillPackSideload.isPermittedSource` (a
looser HTTPS-or-private-host allowlist that also followed redirects). The plan's "one bounded,
redirect-aware substrate" must therefore *replace* both the QR path and these ungated skill-pack
fetches, not just harden the guard QR already uses.

Relevant seams:

- `OpenGlasses/Sources/Services/URLFetchGuard.swift`
- `OpenGlasses/Sources/Services/NativeTools/QRContextTool.swift`
- deep-link handling in `OpenGlasses/Sources/App/OpenGlassesApp.swift`
- `OpenGlasses/Sources/Services/SkillPacks/SkillPackSideload.swift`
- `OpenGlasses/Sources/Services/SkillPacks/SkillPackCatalog.swift`
- `OpenGlasses/Sources/Services/Reading/BookFileExtractor.swift` (`ZipArchiveReader`)
- `OpenGlassesTests/SafetyGateTests.swift`
- `OpenGlassesTests/SkillPackCatalogTests.swift`

## Decisions and invariants

1. Untrusted fetches allow public **HTTPS** only. Plain HTTP, credentials in URLs, non-default schemes,
   fragments used as data, and local/private/reserved destinations are rejected.
2. Every redirect is a new security decision. Redirect count is bounded and HTTPS may never downgrade.
3. DNS policy validates all A/AAAA answers and the connection is pinned to an approved address. A
   validate-then-`URLSession` implementation that permits a second DNS resolution is insufficient
   against rebinding.
4. No byte is fetched for a sideload deep link until the user sees the origin, expected content type,
   and limits and explicitly chooses Download.
5. Compressed bytes, uncompressed bytes, entry count, per-entry size, path shape, nesting, and
   compression ratio are independently bounded before large allocation.

---

## P0 — Immediate containment ✅ engineering checkpoint

1. Disable QR network fetch and remote skill-pack deep-link download behind separate kill switches.
   QR text display and locally bundled packs continue to work.
2. Change remote pack deep-link handling to present a non-network preview containing the normalized
   origin only. The default action is Cancel; no URLSession/task is created before Download.
3. Reject all redirect responses in the legacy QR path until the safe client lands. Reject hostnames
   that cannot be resolved and every answer set containing a non-public address.
4. Add strict small response caps to any temporarily retained path and cancel as soon as the cap is
   exceeded; `Content-Length` is only an early rejection hint, never proof.

**Tests.** Opening a deep link produces zero transport calls before consent; redirect is refused;
mixed public/private DNS answers fail closed; oversized chunked response cancels.

## P1 — Pinned, policy-driven HTTP client 🟡 implemented; runtime/device evidence pending

Build a small `BoundedHTTPClient` with injected resolver, connector, clock, and policy. Do not put this
policy into a general app-wide `URLSession` extension; callers must opt into a named fetch profile.

1. Resolve hostnames with `getaddrinfo`/Network framework on a bounded executor. Normalize IPv4,
   IPv6, IPv4-mapped IPv6, zone ids, decimal/octal/hex-like host forms, trailing dots, IDNs, and DNS
   CNAME results before classification.
2. Reject unspecified, loopback, private, link-local, carrier-grade NAT, multicast, documentation,
   benchmarking, reserved, and IPv6 ULA ranges. Reject the entire host if **any** answer is disallowed.
3. Pin the connection to one validated address while preserving the original hostname for TLS SNI and
   certificate hostname verification. The recommended implementation is a narrow HTTPS GET client over
   `NWConnection`/TLS with a bounded HTTP/1.1 parser; if `URLSession` is retained, the PR must prove it
   cannot re-resolve to an unvalidated peer. “We checked immediately before starting” is not proof.
4. Parse redirects manually. Re-run scheme, credential, port, host, DNS, and address pinning on every
   hop; cap at 3; reject loops and HTTPS→HTTP downgrade.
5. Enforce connect, first-byte, idle, and total deadlines; compressed/decoded byte ceilings; accepted
   MIME types; and no cookie/cache/credential persistence. Strip authorization on cross-origin hops.
6. Return typed policy errors without echoing full URLs. Log only destination class, hop count, byte
   count, duration, and verdict.

Fetch profiles:

- `qrContext`: HTTPS public internet, JSON/text allowlist, 256 KiB decoded cap, no archives.
- `skillPack`: HTTPS public internet, pack MIME/extension allowlist, 8 MiB compressed cap.
- an explicitly enabled internal-development profile may allow selected LAN CIDRs for a foreground
  session, but is compile-time absent from Release and cannot be triggered by a public deep link.

**Tests.** Table-driven IPv4/IPv6 range corpus; DNS to localhost; mixed answers; DNS rebind simulation;
public→private redirect; cross-origin redirect; downgrade; loop; too many hops; slowloris deadlines;
chunked cap; MIME mismatch; TLS hostname mismatch; credential stripping. All use fakes/local fixtures,
not live internet.

## P2 — Consent-first sideload state machine 🟡 implemented; runtime evidence pending

Implement a pure, replay-resistant state machine:

```text
received → awaitingConsent → downloading → inspecting → awaitingInstall → installed
    └──────── cancel/error at every stage; no implicit retry ────────┘
```

1. Canonicalize the URL for display without resolving/fetching. Show hostname, scheme, and that the
   source is untrusted. Do not show userinfo; reject it.
2. Consent creates a single-use download nonce bound to the canonical URL and scene. Backgrounding,
   app restart, URL change, or elapsed approval window invalidates it.
3. Stream compressed bytes into a dedicated protected/no-backup staging directory. Bound memory to a
   small rolling buffer and delete staging on cancel, error, timeout, or scene abandonment.
4. After download, inspect metadata and manifest under P3 caps, run the existing definition scanner and
   pack validator, then present a second install review with actions, native targets, settings, origin,
   hashes, warnings, and requested capabilities.
5. Installation uses the exact inspected bytes/hash. Never re-download between review and install.

**Tests.** No pre-consent network; nonce cannot be replayed or used for another URL; cancel/background
deletes staging; tampering after review fails hash check; install review enumerates native targets;
network errors do not automatically retry.

## P3 — Streaming archive limits before allocation 🟡 implemented; manifest-first admission and runtime evidence pending

Replace `ZipArchiveReader`'s trust in declared output size with a budgeted API.

Recommended default ceilings (centralized and versioned):

- 8 MiB compressed archive;
- 32 MiB total uncompressed;
- 4 MiB per entry;
- 128 entries;
- 100:1 maximum compression ratio per entry and overall;
- path depth 8 and filename length 180;
- no encrypted entries, symlinks, devices, absolute paths, `..`, duplicate normalized paths, nested
  archives, unsupported methods, or overlapping/inconsistent ZIP regions.

1. Parse the end/central directory with checked integer arithmetic and reject metadata whose offsets,
   sizes, or counts exceed the actual compressed buffer or policy before allocating output.
2. Inflate in chunks into a caller-provided sink while decrementing both per-entry and total budgets.
   Abort immediately on actual output beyond declared size or policy; never allocate
   `expectedUncompressedSize` up front.
3. Validate CRC and require exactly one manifest at its canonical path. Read/validate the manifest
   before extracting optional assets; only declared, allowed content types are materialized.
4. Share the hardened reader with book ingestion only after its different limits and compatibility
   corpus are explicit. Do not weaken skill-pack limits to preserve unrelated EPUBs.

**Tests.** Zip bomb, forged huge size, integer overflow, truncated stream, overlapping entries,
duplicate normalized path, traversal, absolute path, symlink, encrypted entry, nested zip, too many
entries, total cap across small entries, ratio cap, CRC mismatch, and valid boundary-size pack.

---

## Rollout, rollback, and exit criteria

P0 ships immediately. Re-enable QR fetch only after P1's address-pinning and redirect suite is green.
Re-enable remote sideload only after P1–P3 and the two-consent flow are green. A rollback disables the
network features and removes staging; it never falls back to `URLSession.shared.data(from:)` or the
unbounded reader.

Complete when:

- untrusted fetches cannot connect to a disallowed address through literals, DNS, or redirects;
- no sideload network task starts before explicit consent;
- response and archive work are bounded during streaming, before large allocation;
- install uses the exact reviewed bytes and declares composed native targets;
- all staging data is protected, no-backup, and deterministically cleaned; and
- adversarial network/archive suites, full unit suite, and Release build are green.

Plan DJ remains the runtime safety backstop for installed pack actions; this plan does not replace it.
