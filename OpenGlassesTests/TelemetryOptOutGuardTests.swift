import XCTest
@testable import OpenGlasses

/// Keeps the third-party telemetry opt-out and the privacy manifest from drifting apart.
///
/// The opt-out itself already shipped: `MWDAT/Analytics/OptOut` and `MWDAT/CrashReporting/OptOut`
/// are in the authored `OpenGlasses/Info.plist`, and `MetaTelemetryBlock` is the `URLProtocol`
/// backstop registered before `Wearables.configure()`. What was missing is the thing that notices
/// when any of that quietly comes undone — a key dropped in a merge, a manifest claim left standing
/// after someone intentionally re-enables vendor telemetry, or the backstop sliding to *after* the
/// SDK is configured, where it no longer wins the race it exists to win.
///
/// This lives in the test suite rather than a script for the same reason the privacy-logging ledger
/// does: every PR runs the suite, so enforcement is inherited with no CI configuration to remember.
/// `MetaTelemetryBlockTests` asserts the *shipped bundle* carries the keys; this file asserts the
/// authored sources that produce it, the manifest claim they have to stay consistent with, and the
/// wiring that makes the authored plist the one the build actually consumes.
final class TelemetryOptOutGuardTests: XCTestCase {

    // MARK: - Repo anchor
    //
    // `#filePath` is baked in at compile time, so it resolves the same on a developer machine and
    // in CI, and the simulator shares the host filesystem. Same anchor the privacy-logging source
    // scan uses.

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static let authoredInfoPlist = "OpenGlasses/Info.plist"
    private static let privacyManifest = "OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy"

    private func sourceText(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The authored plist, parsed the way the build reads it rather than grepped.
    private func authoredInfoDictionary() throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent(Self.authoredInfoPlist)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "\(Self.authoredInfoPlist) is not a dictionary")
    }

    // MARK: - The opt-out keys

    /// Absent or `false` is not a neutral state — it is the SDK's default, which is opted **in**.
    ///
    /// Parsed through `MetaTelemetryBlock.plistOptOut` on purpose: the guard and the app read the
    /// same keys through the same code, so they cannot disagree about where the flags live.
    func testAuthoredInfoPlistOptsOutOfAnalyticsAndCrashReporting() throws {
        let state = MetaTelemetryBlock.plistOptOut(in: try authoredInfoDictionary())

        XCTAssertTrue(state.analytics,
                      "MWDAT/Analytics/OptOut is missing or false in \(Self.authoredInfoPlist). "
                          + "Absent means opted IN: the glasses SDK uploads its session, stream, "
                          + "permission and display event batches to the vendor.")
        XCTAssertTrue(state.crashReporting,
                      "MWDAT/CrashReporting/OptOut is missing or false in \(Self.authoredInfoPlist). "
                          + "Absent means opted IN: a crash ships a report to the SDK vendor.")
    }

    /// The authored file and the bundle the tests are hosted by must say the same thing.
    ///
    /// This is what closes the gap between "the source is right" and "the build is right". The two
    /// could diverge if a build setting ever pointed `INFOPLIST_FILE` somewhere else, or if a
    /// generated plist snapshot were reintroduced — both of which have bitten this project before
    /// (a stale personal copy silently dropped newly added keys).
    ///
    /// **Stated limit:** this reads the bundle of whatever configuration ran the suite — Debug in
    /// the ordinary PR run. What makes it a statement about Release too is structural, not observed:
    /// the keys live in the authored plist and `GENERATE_INFOPLIST_FILE` is `NO` (both asserted
    /// below), so there is no per-configuration plist that could diverge.
    func testShippedBundleAgreesWithTheAuthoredPlist() throws {
        let authored = MetaTelemetryBlock.plistOptOut(in: try authoredInfoDictionary())
        let bundled = MetaTelemetryBlock.bundleOptOut

        XCTAssertEqual(authored.analytics, bundled.analytics,
                       "the built app's Analytics opt-out does not match \(Self.authoredInfoPlist) — "
                           + "something between the authored plist and the bundle is rewriting it")
        XCTAssertEqual(authored.crashReporting, bundled.crashReporting,
                       "the built app's CrashReporting opt-out does not match \(Self.authoredInfoPlist)")
    }

    // MARK: - The manifest pairing rule

    /// The manifest claim, whitespace-normalised so the XML's line wrapping is not load-bearing.
    ///
    /// Quoted from `PrivacyInfo.xcprivacy`'s header comment as it actually reads today. Rewording it
    /// makes the pairing rule below stop enforcing rather than start failing — which is correct, not
    /// a hole: the rule exists to stop the *claim* outliving the opt-out, so withdrawing the claim
    /// satisfies it. What it does mean is that a merely cosmetic rewrite silently disarms the guard,
    /// so update this constant alongside any edit to that sentence.
    private static let noTelemetrySDKClaim =
        "There is no analytics, crash-reporting, or advertising SDK"

    private func normalisedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The invariant: the manifest's claim and the plist's opt-out stand or fall together.
    ///
    /// The manifest tells Apple, in the author's own words, that this app links no crash-reporting
    /// SDK. That is only true because the opt-out is set. If a future change intentionally enables
    /// vendor telemetry, this test fails until the manifest comment and the user-facing disclosure
    /// copy are updated in the same PR — the claim is never allowed to outlive the egress it
    /// describes.
    func testManifestNoTelemetryClaimRequiresThePlistOptOut() throws {
        let manifest = normalisedWhitespace(try sourceText(Self.privacyManifest))
        guard manifest.contains(Self.noTelemetrySDKClaim) else {
            // The claim was withdrawn. That is a legitimate way to satisfy the rule — the manifest
            // now discloses the egress instead of denying it — so there is nothing to enforce.
            return
        }

        let state = MetaTelemetryBlock.plistOptOut(in: try authoredInfoDictionary())
        XCTAssertTrue(state.analytics && state.crashReporting,
                      "\(Self.privacyManifest) still asserts \"\(Self.noTelemetrySDKClaim)\" while "
                          + "\(Self.authoredInfoPlist) no longer opts out of the wearables SDK's "
                          + "telemetry. Those two cannot both be true. Either restore the opt-out, "
                          + "or — if enabling vendor telemetry is deliberate — change the manifest "
                          + "comment and the in-app privacy copy in this same PR so the app never "
                          + "ships a privacy claim it does not honour.")
    }

    // MARK: - Backstop ordering

    /// Drops whole-line `//` comments so a source-order scan reads code, not prose.
    ///
    /// Line comments are all this file needs — `WearablesBootstrap` uses no block comments, and a
    /// scanner that tried to track `/* */` nesting would be more machinery than the one ordering
    /// question here justifies. A trailing comment on a code line is left alone: it cannot move a
    /// call, only annotate one.
    private func strippingLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The `URLProtocol` backstop only works if it is registered before the SDK is configured.
    ///
    /// `Wearables.configure()` is what brings the SDK's uploader to life; a registration that lands
    /// after it can lose the race for the first batch. Ordering is not something a runtime test can
    /// observe without configuring the SDK for real — which is fatal in a unit-test host and
    /// irreversible for the rest of the bundle — so this reads the source, which is where the
    /// ordering is actually decided.
    func testTelemetryBlockIsInstalledBeforeWearablesIsConfigured() throws {
        // Comments are stripped first: the file's own doc comment names `Wearables.configure()`
        // several lines above the call it documents, and prose is not execution order.
        let source = strippingLineComments(
            try sourceText("OpenGlasses/Sources/Services/WearablesBootstrap.swift"))

        let install = try XCTUnwrap(source.range(of: "MetaTelemetryBlock.install()"),
                                    "WearablesBootstrap no longer installs MetaTelemetryBlock — the "
                                        + "network backstop for the SDK's telemetry is gone")
        let configure = try XCTUnwrap(source.range(of: "Wearables.configure()"),
                                      "WearablesBootstrap no longer calls Wearables.configure()")

        XCTAssertLessThan(install.lowerBound, configure.lowerBound,
                          "MetaTelemetryBlock.install() must precede Wearables.configure(). "
                              + "Registered afterwards, the SDK's uploader can win the race and the "
                              + "first telemetry batch leaves the device before the interceptor exists.")
    }

    // MARK: - What the build consumes
    //
    // The opt-out lives in an authored plist rather than a generated one so it is present in every
    // configuration, Release included. These assertions keep that wiring in place.

    /// `INFOPLIST_FILE` points at the authored plist and nothing generates one over the top of it.
    func testProjectSpecBuildsTheAuthoredInfoPlist() throws {
        let spec = try sourceText("project.base.yml")

        XCTAssertTrue(spec.contains("INFOPLIST_FILE: \(Self.authoredInfoPlist)"),
                      "project.base.yml no longer points INFOPLIST_FILE at \(Self.authoredInfoPlist); "
                          + "the opt-out keys are only guaranteed in the plist the build consumes")
        XCTAssertTrue(spec.contains("GENERATE_INFOPLIST_FILE: \"NO\""),
                      "project.base.yml no longer sets GENERATE_INFOPLIST_FILE: NO — a generated "
                          + "plist would not carry the MWDAT opt-out keys")
    }

    /// **Stated limit.** Personal build settings ride in through the gitignored `project.local.yml`,
    /// which by definition is not present in a clean clone or in CI, so no test can assert on a file
    /// that may not exist. The whole-plist override that *could* have silently dropped these keys —
    /// `Config/Info/Info.personal.plist`, wired by overriding `INFOPLIST_FILE` — was removed
    /// precisely because it went stale that way; only credentials are substituted into the committed
    /// plist now, as `$(...)` build settings. This test enforces that removal where it can: on the
    /// worked-in checkout, if a local spec exists it must not reintroduce the override. On a machine
    /// without one, `testShippedBundleAgreesWithTheAuthoredPlist` is the assertion that still holds —
    /// it reads what was actually built, whatever produced it.
    func testLocalSpecDoesNotOverrideTheInfoPlist() throws {
        let url = Self.repoRoot.appendingPathComponent("project.local.yml")
        guard let spec = try? String(contentsOf: url, encoding: .utf8) else { return }

        // Comments are stripped before matching, and the match is on the YAML key form. The
        // template this file is copied from carries a comment *telling* you never to override
        // `INFOPLIST_FILE` — a bare substring search flags that warning as the violation it warns
        // against, which is a false failure that teaches people to delete the warning.
        let settings = spec.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.prefix { $0 != "#" } }

        let overrides = settings.filter { $0.contains("INFOPLIST_FILE:") }
        XCTAssertTrue(overrides.isEmpty,
                      "project.local.yml sets INFOPLIST_FILE (\(overrides.map(String.init).joined(separator: "; "))). "
                          + "That mechanism was removed: a personal plist copy goes stale and "
                          + "silently drops keys — usage descriptions once (ITMS-90683), and the "
                          + "MWDAT telemetry opt-out just as easily. Put personal values in build "
                          + "settings instead.")
    }
}
