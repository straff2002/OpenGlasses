# Syncthing runtime

The desktop lab executes the unmodified binary from the pinned upstream release. Archives are SHA-256 verified before extraction; the locked
digests came from the release asset metadata, rather than a checksum fetched at each build.

Syncthing is copyright the Syncthing Authors and distributed under
[Mozilla Public License 2.0](https://github.com/syncthing/syncthing/blob/v2.1.5/LICENSE).
Source for the bundled release is available at
[syncthing v2.1.5](https://github.com/syncthing/syncthing/tree/v2.1.5).

This is a feasibility runtime, not approval to use stock receive-only folders for protected
manuals. Production distribution must include the complete applicable notices and preserve
source availability; any modified embedded iOS engine needs its own inventory and review.


The iPhone lab embeds that pinned source with the
[mobile model hook](mobile-extension/README.md). Its complete modified `syncthing.go`, pin and
extension notice are bundled with the iPhone app, alongside the upstream licence/authorship files.
The build verifies the original whole-module checksum before preparing a generated replacement.
The application-owned request guard and adversarial probe live under `Transport/mobile-core/`.
No Sushitrain code or binary is bundled.
