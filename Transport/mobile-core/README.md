# Embedded iPhone experiment

This original Go bridge exposes one approved desktop peer and two synthetic lab folders.
It does not expose arbitrary sharing, a management server, business acceptance or the OpenGlasses
data store. LAN-only is the default; automatic discovery/relay and forced-relay policies require
an explicit binding mode. Startup, scanning and shutdown run off Swift's main
actor. The standalone app stops the engine on backgrounding; it does not promise background sync.
Its UI records the connection type from engine events and the current iOS network path. The
desktop's connection API supplies the actual route used to decide the experiment result.

The engine is the official **Syncthing v2.1.5** release commit
`2ca95cf1498104113fdfde46df4107f2450a0f71`. Upstream's module path has no `/v2` suffix, so Go records
that exact commit as `v1.30.0-rc.1.0.20260908065755-2ca95cf14981`. It is not an older engine selection.
`go.mod`/`go.sum` pin its dependency graph and Go mobile tools. Go 1.27.1 is the build toolchain.
`noassets` omits the unused management UI. The mobile engine adds the small, pinned
[`avenkin-model-hook.1` extension](../vendor/syncthing/mobile-extension/README.md) so an application
wrapper can reject outbound content requests before the stock model reads any file. The desktop
binary remains unmodified. The complete modified source and notices ship with Device Lab.

The source preparer verifies the original file SHA-256 and the whole upstream module's Go `h1`
checksum, then creates an ignored generated replacement module. It never modifies the module
cache. Run `Transport/scripts/build_ios_lab.sh` to prepare source before testing/building the bridge;
a clean direct build without the required hook fails, rather than bypassing the guard.

Only the completed synthetic `receipt.json` in the report folder can be served. Manual, control,
temporary and unknown-folder requests receive `ErrNoSuchFile` without reaching the underlying
model. Index/progress metadata to the approved office still flows. A test-only `manualLab` binding
adds a receive-only fictional manual folder, verifies bytes and atomically installs them outside
all shared folders. Both retained transport files and partial staging remain guarded. Real signed
manual manifests, vault import and production outbound kinds are separate integration work.

The adversarial `labprobe` peer checks live authenticated BEP requests against partial and completed
manual bytes, an unknown folder and an exact report. Set `AVENKIN_MANUAL_TEST_IP` to an explicit
private interface to run `TestManualNoExportAcrossRealEmbeddedEngineAndBEP`; it is skipped by default.
The separate Avenkin Office Device Lab can run the same probe against an iPhone without copying
payloads through USB.

The compiled arm64 framework is ignored and built locally. Follow
the private Avenkin Office Device Lab instructions. The UI and bridge are lab
code, not production pairing or signed receipt authority. A matching receipt proves exact bytes
arrived and were processed by this companion, not that a business operation was accepted.

References: [official engine source](https://github.com/syncthing/syncthing/tree/v2.1.5),
[Go mobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile),
[Sushitrain's existing iOS embedding](https://github.com/pixelspark/sushitrain).
No Sushitrain source or binary is bundled by this bridge.

The 0.4 [office preview](../../Contracts/office-preview.md) adds explicit application-key
pairing and three pair-specific folders for signed control, immutable manuals and exact
receipts. Its private-LAN configuration is selected only after the saved binding verifies,
not by a renderer-supplied transport flag. Saved companion job/manual metadata restores
without starting the engine, so explicit Stop and offline viewing survive relaunch.
The preview is separate from the synthetic Internet modes and production OpenGlasses import.
