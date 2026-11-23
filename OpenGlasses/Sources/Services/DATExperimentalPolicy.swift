import Foundation

/// Whether one of Meta's [Experimental] glasses features may run in this copy (Plan JV). Pure.
///
/// Meta's SDK ships features it labels experimental, and apps that use them cannot be published.
/// The owner's decision (2026-10-26) is an opt-in generation flag: `AVENKIN_DAT_EXPERIMENTAL=1`
/// adds `project.experimental.yml`, which defines `DAT_EXPERIMENTAL`, and every line that touches
/// an experimental API compiles only under it. **The compile flag is the gate**: an unflagged
/// binary does not contain the feature, as opposed to containing it switched off.
///
/// Everything else here only restricts a flagged binary further. A feature runs when all hold:
/// - the build is flagged (compiled with `DAT_EXPERIMENTAL`);
/// - the install channel is TestFlight, a development build or the simulator. The channel is
///   `AppBuildIdentity`'s support hint, which "must never decide which features the binary
///   offers" — and it does not here: it can never turn a feature on, only hold one off, so a
///   flagged build promoted to the store by mistake still runs nothing;
/// - this copy offers glasses at all (`GlassesSupportPolicy.isSupported`);
/// - the wearer's own switch for the feature is on.
enum DATExperimentalPolicy {

    /// The experimental features, each with the wearer's switch.
    enum Feature: String, CaseIterable {
        /// "Hey Meta, open Avenkin": the SDK's voice invocations (P1).
        case voiceInvocation
        /// Plan MU §7: Neural Band swipes left and right on the manual page view (Inputs).
        case lensPageSwipes
        /// Plan NB §6: pinch and turn the wrist to zoom the manual page view (Motion and Inputs).
        case lensTwistZoom
        /// Plan NB (owner, 2026-11-23): pinch and move the arm to pan the manual page view.
        case lensArmPan

        /// Where the wearer's switch is kept.
        var defaultsKey: String { "datExperimental.\(rawValue)" }

        /// Whether the switch starts on. Voice invocations do: they fire only when the wearer says
        /// the phrase. Page swipes do: the band is listened to only while a page view is on the lens,
        /// and only left and right are acted on. The wrist gestures do not (Plan NB decisions 2
        /// and 7): which way is clockwise, and whether a held pinch lasts, wait for the device pass.
        var defaultOn: Bool {
            switch self {
            case .voiceInvocation, .lensPageSwipes: return true
            case .lensTwistZoom, .lensArmPan: return false
            }
        }
    }

    enum Verdict: Equatable {
        case runs
        /// The binary was built without the flag: the feature is not in it at all.
        case notInThisBuild
        /// A flagged binary installed from the App Store, where it must never have gone.
        case heldOnThisChannel
        /// This copy offers no glasses (the phone-only product).
        case glassesNotSupported
        /// The wearer turned the feature off.
        case switchedOff
    }

    /// Checked in this order, so a report names the first condition that won.
    static func verdict(flagged: Bool, channel: AppBuildIdentity.Channel, glassesSupported: Bool,
                        switchOn: Bool) -> Verdict {
        guard flagged else { return .notInThisBuild }
        guard allowedChannels.contains(channel) else { return .heldOnThisChannel }
        guard glassesSupported else { return .glassesNotSupported }
        guard switchOn else { return .switchedOff }
        return .runs
    }

    /// Where a flagged binary may run anything experimental. Never the App Store.
    static let allowedChannels: Set<AppBuildIdentity.Channel> = [.testFlight, .development, .simulator]

    /// Whether this binary was compiled with the experimental features.
    static var isCompiledIn: Bool {
        #if DAT_EXPERIMENTAL
        return true
        #else
        return false
        #endif
    }

    // MARK: - The wearer's switches

    static func isSwitchOn(_ feature: Feature, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: feature.defaultsKey) as? Bool ?? feature.defaultOn
    }

    static func setSwitch(_ feature: Feature, on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: feature.defaultsKey)
    }

    /// Plan NB decision 9: "Reverse the twist", under the twist's switch. Off: clockwise zooms in.
    static let twistReversedKey = "datExperimental.lensTwistReversed"

    static func isTwistReversed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: twistReversedKey)
    }

    static func setTwistReversed(_ reversed: Bool, defaults: UserDefaults = .standard) {
        defaults.set(reversed, forKey: twistReversedKey)
    }

    // MARK: - This copy

    static func current(_ feature: Feature, identity: AppBuildIdentity = .current,
                        defaults: UserDefaults = .standard) -> Verdict {
        verdict(flagged: isCompiledIn, channel: identity.channel,
                glassesSupported: GlassesSupportPolicy.isSupported,
                switchOn: isSwitchOn(feature, defaults: defaults))
    }

    /// A diagnostics tool's verdict (the Developer panel's Inputs probe, P2). It has no switch of
    /// its own: it runs only while the wearer has pressed Start, so the press is the switch, and
    /// the rest of the conditions hold as for any feature.
    static func currentForDiagnostics(identity: AppBuildIdentity = .current) -> Verdict {
        verdict(flagged: isCompiledIn, channel: identity.channel,
                glassesSupported: GlassesSupportPolicy.isSupported, switchOn: true)
    }

    // MARK: - Support report

    /// One line for the support report, beside the `Glasses:` line: whether the binary carries the
    /// experimental features, whether its Info.plist stamp agrees, and each feature's verdict.
    /// Case names only.
    static func reportLine(flagged: Bool, stamped: Bool, channel: AppBuildIdentity.Channel,
                           glassesSupported: Bool, switches: [Feature: Bool]) -> String {
        var line = "Experimental glasses features: "
        if !flagged {
            line += "not in this build"
        } else {
            let features = Feature.allCases.map { feature in
                let on = switches[feature] ?? feature.defaultOn
                let verdict = verdict(flagged: true, channel: channel, glassesSupported: glassesSupported,
                                      switchOn: on)
                return "\(feature.rawValue) \(verdict.reportToken)"
            }
            line += "in this build (TestFlight only) · " + features.joined(separator: ", ")
        }
        if flagged != stamped {
            line += " · stamp disagrees (Info.plist says \(stamped ? "YES" : "NO"))"
        }
        return line
    }

    static func currentReportLine(identity: AppBuildIdentity = .current,
                                  defaults: UserDefaults = .standard) -> String {
        reportLine(flagged: isCompiledIn, stamped: identity.datExperimental, channel: identity.channel,
                   glassesSupported: GlassesSupportPolicy.isSupported,
                   switches: Dictionary(uniqueKeysWithValues: Feature.allCases.map {
                       ($0, isSwitchOn($0, defaults: defaults))
                   }))
    }
}

extension DATExperimentalPolicy.Verdict {
    var reportToken: String {
        switch self {
        case .runs: return "runs"
        case .notInThisBuild: return "notInThisBuild"
        case .heldOnThisChannel: return "heldOnThisChannel"
        case .glassesNotSupported: return "glassesNotSupported"
        case .switchedOff: return "switchedOff"
        }
    }
}
