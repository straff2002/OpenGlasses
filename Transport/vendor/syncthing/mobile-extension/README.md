# Avenkin mobile model hook

This directory contains the **modified** `lib/syncthing/syncthing.go` from official Syncthing
v2.1.5 / commit `2ca95cf1498104113fdfde46df4107f2450a0f71`, under the original MPL-2.0 notice.
The complete modified file, this notice and the source/checksum pin are bundled with Device Lab.
The upstream licence and authorship files remain under the parent directory.

Avenkin modification `avenkin-model-hook.1` adds `Options.ModelWrapper`, applies it immediately
following model construction, and rejects a nil result. This wraps the model used by connection
management before any connection/service starts. All other upstream files are unchanged.
The desktop archive and binary remain the official, unmodified release.

`Transport/scripts/prepare_mobile_source.py` checks both the original file SHA-256 and the complete
module's recorded Go `h1` checksum before creating an ignored, generated source tree. The mobile
module replaces the pinned upstream module with that tree. The generator never edits the Go
module cache. A build without the hook fails to compile the guarded bridge; there is no silent
fallback. An upstream update requires reviewing the full-file diff and updating the source pin.

The phone wrapper rejects all content requests except the lab's completed `receipt.json` in the
report folder. It delegates other model methods normally, allowing inbound manual/control
transfers and outbound receipts. This is a synthetic feasibility boundary; production outbound
kinds require a separately reviewed allowlist and signed import/receipt contracts.

[Upstream source](https://github.com/syncthing/syncthing/blob/v2.1.5/lib/syncthing/syncthing.go)
