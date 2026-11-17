import XCTest
@testable import OpenGlasses

/// When one of Meta's experimental glasses features may run (Plan JV P0).
final class DATExperimentalPolicyTests: XCTestCase {

    private typealias Policy = DATExperimentalPolicy

    private func defaults() -> UserDefaults {
        let name = "DATExperimentalPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testEverythingHoldingRuns() {
        for channel in [AppBuildIdentity.Channel.testFlight, .development, .simulator] {
            XCTAssertEqual(Policy.verdict(flagged: true, channel: channel, glassesSupported: true, switchOn: true),
                           .runs, channel.rawValue)
        }
    }

    func testTheCompileFlagIsTheGateNothingElseTurnsAFeatureOn() {
        for channel in [AppBuildIdentity.Channel.appStore, .testFlight, .development, .simulator] {
            XCTAssertEqual(Policy.verdict(flagged: false, channel: channel, glassesSupported: true, switchOn: true),
                           .notInThisBuild, channel.rawValue)
        }
    }

    /// A flagged build that reached the store by mistake still runs nothing.
    func testTheAppStoreChannelHoldsAFlaggedBuildOff() {
        XCTAssertEqual(Policy.verdict(flagged: true, channel: .appStore, glassesSupported: true, switchOn: true),
                       .heldOnThisChannel)
        XCTAssertFalse(Policy.allowedChannels.contains(.appStore))
    }

    func testTheConditionsWinInOrder() {
        XCTAssertEqual(Policy.verdict(flagged: true, channel: .appStore, glassesSupported: false, switchOn: false),
                       .heldOnThisChannel)
        XCTAssertEqual(Policy.verdict(flagged: true, channel: .testFlight, glassesSupported: false, switchOn: false),
                       .glassesNotSupported)
        XCTAssertEqual(Policy.verdict(flagged: true, channel: .testFlight, glassesSupported: true, switchOn: false),
                       .switchedOff)
    }

    func testTheVoiceInvocationSwitchDefaultsOnAndRemembersTheWearersChoice() {
        let defaults = defaults()
        XCTAssertTrue(Policy.isSwitchOn(.voiceInvocation, defaults: defaults))
        Policy.setSwitch(.voiceInvocation, on: false, defaults: defaults)
        XCTAssertFalse(Policy.isSwitchOn(.voiceInvocation, defaults: defaults))
        Policy.setSwitch(.voiceInvocation, on: true, defaults: defaults)
        XCTAssertTrue(Policy.isSwitchOn(.voiceInvocation, defaults: defaults))
    }

    func testTheReportLineForAnUnflaggedBuild() {
        XCTAssertEqual(Policy.reportLine(flagged: false, stamped: false, channel: .appStore, glassesSupported: true,
                                         switches: [:]),
                       "Experimental glasses features: not in this build")
    }

    func testTheReportLineForAFlaggedBuildNamesEachFeaturesVerdict() {
        XCTAssertEqual(Policy.reportLine(flagged: true, stamped: true, channel: .testFlight, glassesSupported: true,
                                         switches: [.voiceInvocation: true]),
                       "Experimental glasses features: in this build (TestFlight only) · voiceInvocation runs")
        XCTAssertEqual(Policy.reportLine(flagged: true, stamped: true, channel: .testFlight, glassesSupported: true,
                                         switches: [.voiceInvocation: false]),
                       "Experimental glasses features: in this build (TestFlight only) · voiceInvocation switchedOff")
        XCTAssertEqual(Policy.reportLine(flagged: true, stamped: true, channel: .appStore, glassesSupported: true,
                                         switches: [:]),
                       "Experimental glasses features: in this build (TestFlight only) · voiceInvocation heldOnThisChannel")
    }

    func testTheReportLineSaysWhenTheStampDisagrees() {
        XCTAssertTrue(Policy.reportLine(flagged: false, stamped: true, channel: .testFlight, glassesSupported: true,
                                        switches: [:]).hasSuffix(" · stamp disagrees (Info.plist says YES)"))
        XCTAssertTrue(Policy.reportLine(flagged: true, stamped: false, channel: .testFlight, glassesSupported: true,
                                        switches: [:]).hasSuffix(" · stamp disagrees (Info.plist says NO)"))
    }

    /// The report line never carries the SDK's module names, which the phone-only artifact check
    /// bans from the store binary.
    func testTheReportLineNamesNoSDKModule() {
        for flagged in [false, true] {
            let line = Policy.reportLine(flagged: flagged, stamped: !flagged, channel: .testFlight,
                                         glassesSupported: true, switches: [:])
            XCTAssertNil(line.range(of: "mwdat", options: .caseInsensitive), line)
        }
    }
}
