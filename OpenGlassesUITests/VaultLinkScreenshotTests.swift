import XCTest

/// Plan FS PR2 — photographs of the two screens the decision turns on, in both appearances.
///
/// Not an audit: these exist so a person can look at the review sheet's signed and unverified
/// states and the Custom Vaults badge and say whether they read. The archive behind them is built
/// in-process by the app's own `UITestVaultFixture` and goes through the whole pipeline — zip
/// reader, header, checksums, signature, publisher lookup — with only the transport replaced.
///
/// Set `OG_SHOT_DIR` to write the PNGs somewhere as well as attaching them to the result bundle.
final class VaultLinkScreenshotTests: AccessibilityAuditCase {

    private func save(_ app: XCUIApplication, named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // `TEST_RUNNER_`-prefixed variables are the ones xcodebuild forwards to the runner
        // process; the bare name is accepted too for a run driven some other way.
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["OG_SHOT_DIR"] ?? environment["TEST_RUNNER_OG_SHOT_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    // MARK: - The review sheet

    func testSignedReviewSheetLight() {
        let app = launch([.configured, .fieldAssist, .vaultLinkSigned])
        awaitReviewSheet(app)
        save(app, named: "fs2-review-signed-light")
    }

    func testSignedReviewSheetDark() {
        let app = launch([.configured, .fieldAssist, .vaultLinkSigned, .darkAppearance])
        awaitReviewSheet(app)
        save(app, named: "fs2-review-signed-dark")
    }

    func testUnverifiedReviewSheetLight() {
        let app = launch([.configured, .fieldAssist, .vaultLinkUnverified])
        awaitReviewSheet(app)
        awaitScreen(app.staticTexts["Unverified source"], named: "The unverified-source warning")
        save(app, named: "fs2-review-unverified-light")
    }

    func testUnverifiedReviewSheetDark() {
        let app = launch([.configured, .fieldAssist, .vaultLinkUnverified, .darkAppearance])
        awaitReviewSheet(app)
        awaitScreen(app.staticTexts["Unverified source"], named: "The unverified-source warning")
        save(app, named: "fs2-review-unverified-dark")
    }

    // MARK: - The badged row

    func testCustomVaultsRowWithTheBadgeLight() {
        let app = launch([.configured, .showAllSettings, .fieldAssist, .vaultReceivedBadge])
        openCustomVaults(app)
        save(app, named: "fs2-custom-vaults-badge-light")
    }

    func testCustomVaultsRowWithTheBadgeDark() {
        let app = launch([.configured, .showAllSettings, .fieldAssist, .vaultReceivedBadge,
                          .darkAppearance])
        openCustomVaults(app)
        save(app, named: "fs2-custom-vaults-badge-dark")
    }

    // MARK: - Helpers

    private func awaitReviewSheet(_ app: XCUIApplication) {
        awaitScreen(app.navigationBars["Add from link or QR"], named: "The vault-link sheet")
        awaitScreen(app.staticTexts["What it contains"], named: "The review's contents section")
    }

    private func openCustomVaults(_ app: XCUIApplication) {
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Tools & Actions", in: app)
        awaitScreen(app.navigationBars["Tools & Actions"], named: "Tools & Actions")
        tapRow(startingWith: "Custom Vaults", in: app)
        awaitScreen(app.navigationBars["Custom Vaults"], named: "Custom Vaults")
        awaitScreen(app.staticTexts["Unverified source"], named: "The unverified-source badge")
    }
}
