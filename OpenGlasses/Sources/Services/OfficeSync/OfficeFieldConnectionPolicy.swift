import Foundation

/// The decisions of keeping a paired phone connected to its office while the app is open, with
/// no clock, engine, storage or network of their own: `OfficeFieldConnection` passes what it saw
/// and gets back what happens next, and what the phone says about it.
enum OfficeFieldConnectionPolicy {

    enum Route: Equatable, Sendable {
        /// A TCP or QUIC connection straight to the office, on its network or across the internet.
        case direct
        /// Through a community relay; still end to end encrypted and pinned to the office.
        case relay
    }

    /// Why the connection stopped and will not start again on its own. Each one needs a person.
    enum StopReason: Equatable, Sendable {
        /// No office pairing on this phone (or no office enrolment at all).
        case notPaired
        /// The office pairing (30 days) or the organisation profile it rests on has expired.
        case pairingExpired
        /// The organisation's management period on this phone has lapsed, or its licence has gone.
        case managementLapsed
        /// A newer pairing replaced this one, or the saved one is older than one already accepted.
        case pairingReplaced
        /// The saved pairing no longer verifies against this phone and its organisation.
        case pairingInvalid
        /// The organisation connects on the office network only, and no office address is saved.
        case noOfficeAddress
    }

    enum State: Equatable, Sendable {
        /// This build has no office transport. Nothing is shown and nothing runs.
        case unavailable
        /// The engine is running and looking for the office under this policy.
        case waiting(OfficePairingService.TransportPolicy)
        case connected(Route)
        /// Stopped while the app is in the background or the pairing screen has the engine.
        case paused
        case stopped(StopReason)
    }

    // MARK: - Timing

    /// How often the engine's state is read while the app is open.
    static let pollInterval: TimeInterval = 3
    /// How often the saved approval is verified again while the connection runs.
    static let approvalRecheckInterval: TimeInterval = 30
    /// How long without a connection before a network that has just come back restarts it.
    static let networkRestartThreshold: TimeInterval = 10

    /// The wait after the `failures`th start failure in a row: 2, 4, 8, … seconds, at most 60.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60, pow(2, Double(min(failures, 6))))
    }

    /// A network that has just become available restarts a connection that has not reached the
    /// office for a while; one that is connected, or only just started, is left alone.
    static func restartsOnNetworkReturn(_ state: State, notConnectedSince: Date?, now: Date) -> Bool {
        guard case .waiting = state, let since = notConnectedSince else { return false }
        return now.timeIntervalSince(since) > networkRestartThreshold
    }

    /// How long without the office, under `automatic`, before the engine is started again to look
    /// the office up afresh, and how often after that while it is still not found.
    static let rediscoveryFirstAfter: TimeInterval = 60
    static let rediscoveryInterval: TimeInterval = 120

    /// Whether to start the engine again so it asks discovery for the office again. Under
    /// `automatic` the phone finds the office through global discovery, and the engine keeps a
    /// lookup that found nothing for as long as the server says (about half an hour, measured):
    /// a phone that looked before the office computer was on, or before it first announced, would
    /// otherwise not look again until the engine restarts. So: once after a minute without the
    /// office, then every two minutes until it is found. Never while connected, and not for
    /// office-network-only, which dials the saved address and never asks discovery.
    static func restartsToLookAgain(policy: OfficePairingService.TransportPolicy, notConnectedSince: Date?,
                                    lastLookedAgain: Date?, now: Date) -> Bool {
        guard policy == .automatic, let since = notConnectedSince else { return false }
        if let last = lastLookedAgain, last >= since {
            return now.timeIntervalSince(last) >= rediscoveryInterval
        }
        return now.timeIntervalSince(since) >= rediscoveryFirstAfter
    }

    // MARK: - What the engine reports

    enum Observation: Equatable, Sendable {
        case connected(Route)
        /// Running, office not (or not yet recognisably) connected.
        case waiting
        /// No managed engine running: it stopped or never started.
        case notRunning
    }

    /// The route from the engine's `observedConnectionType` (`tcp-client`, `quic-server`,
    /// `relay-client`, …). Nil when it names neither.
    static func route(connectionType: String) -> Route? {
        if connectionType.hasPrefix("relay-") { return .relay }
        if connectionType.hasPrefix("tcp-") || connectionType.hasPrefix("quic-") { return .direct }
        return nil
    }

    /// Whether a snapshot says the phone is connected straight to its office on a private
    /// network (`observedConnectionLocal`): not across the internet, not through a relay. Anything
    /// the snapshot does not say plainly is not local.
    static func onOfficeNetwork(snapshot: String) -> Bool {
        guard case .connected(.direct) = observe(snapshot: snapshot),
              let data = snapshot.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return fields["observedConnectionLocal"] as? Bool == true
    }

    /// What one engine snapshot (the bridge's public status JSON) says.
    static func observe(snapshot: String) -> Observation {
        guard let data = snapshot.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              fields["running"] as? Bool == true,
              fields["managedOffice"] as? Bool == true else { return .notRunning }
        guard fields["connected"] as? Bool == true,
              let route = route(connectionType: fields["observedConnectionType"] as? String ?? "") else {
            return .waiting
        }
        return .connected(route)
    }

    // MARK: - Failures

    enum AfterFailure: Equatable, Sendable {
        /// Stop the engine and say why; only a person can put this right.
        case stop(StopReason)
        /// Try again after the backoff (the engine, the network or a moment's change).
        case retry
    }

    /// What a failure to verify the saved approval, or to start the engine, means.
    static func afterFailure(_ error: Error) -> AfterFailure {
        if let refusal = error as? OfficePairingService.Refusal {
            switch refusal {
            case .noDesktopEnrolment, .noApprovedOffice: return .stop(.notPaired)
            case .inactiveLease, .missingLicence: return .stop(.managementLapsed)
            case .approvalSuperseded: return .stop(.pairingReplaced)
            case .noOfficeAddress: return .stop(.noOfficeAddress)
            // The organisation setup changed mid-check: the next check reads the new one.
            case .changedDuringApproval: return .retry
            }
        }
        if let refusal = error as? OfficePeerBinding.Refusal {
            switch refusal {
            case .notCurrentlyValid, .profileExpired: return .stop(.pairingExpired)
            case .rollback: return .stop(.pairingReplaced)
            case .untrustedProfile, .malformed, .badSignature, .wrongOrganizationOrProfile,
                 .wrongPeer, .invalidFields: return .stop(.pairingInvalid)
            }
        }
        if let refusal = error as? OfficeInlineEntitlement.Refusal {
            return refusal == .notCurrentlyValid ? .stop(.managementLapsed) : .stop(.pairingInvalid)
        }
        if error is OfficeApprovedPeerStore.Refusal { return .stop(.pairingInvalid) }
        return .retry
    }

    // MARK: - What the phone says

    struct Status: Equatable, Sendable {
        let title: String
        let detail: String?
        let systemImage: String
    }

    /// The words for each state. Nil when nothing is shown.
    static func status(_ state: State) -> Status? {
        switch state {
        case .unavailable:
            return nil
        case .connected(.direct):
            return Status(title: "Connected to office — direct", detail: nil, systemImage: "checkmark.circle")
        case .connected(.relay):
            return Status(title: "Connected to office — via relay",
                          detail: "Through a community relay. The connection is still encrypted end to end.",
                          systemImage: "checkmark.circle")
        case .waiting(.automatic):
            return Status(title: "Waiting for the office",
                          detail: "The office computer has to be on, with Avenkin Office open.",
                          systemImage: "hourglass")
        case .waiting(.privateLan):
            return Status(title: "Office network only — waiting",
                          detail: "This organisation connects on the office network only.",
                          systemImage: "hourglass")
        case .paused:
            return Status(title: "Office connection paused", detail: nil, systemImage: "pause.circle")
        case .stopped(.notPaired):
            return Status(title: "Not paired with the office",
                          detail: "Pair this phone at the office to connect.",
                          systemImage: "link")
        case .stopped(.pairingExpired):
            return Status(title: "Office pairing has expired",
                          detail: "Pair this phone again at the office.",
                          systemImage: "exclamationmark.triangle")
        case .stopped(.managementLapsed):
            return Status(title: "Your organisation's management period has lapsed",
                          detail: "Pair this phone again at the office.",
                          systemImage: "exclamationmark.triangle")
        case .stopped(.pairingReplaced):
            return Status(title: "This office pairing was replaced",
                          detail: "Pair this phone again at the office.",
                          systemImage: "exclamationmark.triangle")
        case .stopped(.pairingInvalid):
            return Status(title: "Office pairing no longer matches this phone",
                          detail: "Pair this phone again at the office.",
                          systemImage: "exclamationmark.triangle")
        case .stopped(.noOfficeAddress):
            return Status(title: "Office network only — no office address",
                          detail: "On the office's network, open Pair with Avenkin Office and use Test office connection.",
                          systemImage: "wifi.exclamationmark")
        }
    }
}
