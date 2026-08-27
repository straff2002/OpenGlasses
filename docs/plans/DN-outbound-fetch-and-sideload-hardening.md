# Plan DN — Outbound Fetch and Skill-Pack Sideload Hardening

**Status:** 📝 Drafted (2026-08-26)
**Origin:** 2026-08-26 adversarial review findings 5 (High) and 8 (Medium).
**Priority:** P0 for QR redirects/DNS; remote deep-link pack install stays disabled until P1/P2.

This plan creates one bounded, redirect-aware outbound fetch substrate for untrusted QR and skill-pack
URLs, and a streaming archive reader that enforces limits before allocation. A deep link is an offer to
review a download, not permission to contact its server.

---

## Problem and verified path

`URLFetchGuard` rejects literal loopback/private hosts but explicitly does not resolve DNS.
`QRContextTool` validates only the initial URL then uses `URLSession.shared.data(from:)`, which follows
redirects automatically. A public-looking hostname or redirect can therefore reach localhost, LAN,
link-local, metadata-like, or other non-public addresses.

Skill-pack deep links are handled outside the ordinary trust gate and begin downloading before the
install confirmation. Downloads are buffered in full. `SkillPackCatalog` enforces one cap —
`maxEntryBytes` (5 MiB) per entry, and only *after* the entry is allocated and inflated; there is no
total-archive cap, entry-count cap, or ratio cap. `ZipArchiveReader.inflate` allocates
`Data(count: entry.uncompressedSize)` straight from the archive's central-directory metadata before
any of that, so a single entry declaring a huge uncompressed size triggers the full allocation before
the 5 MiB check can reject it. A crafted link can cause network disclosure, memory/disk pressure, or a
zip bomb before the user has meaningfully consented.

Critically, `URLFetchGuard.validate` is called from exactly one place — `QRContextTool`. The
skill-pack sideload and catalog fetches call `URLSession.shared.data(from:)` **with no `URLFetchGuard`
check at all**; the sideload URL is gated only by `SkillPackSideload.isPermittedSource` (a
looser HTTPS-or-private-host allowlist that also follows redirects). The plan's "one bounded,
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

## P0 — Immediate containment 🔴

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

## P1 — Pinned, policy-driven HTTP client 🔴

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

## P2 — Consent-first sideload state machine 🟠

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

## P3 — Streaming archive limits before allocation 🟠

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
