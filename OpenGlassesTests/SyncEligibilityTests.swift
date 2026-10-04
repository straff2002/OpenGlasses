import XCTest
@testable import OpenGlasses

/// Whether a recorded job may be sent now: the network × power × policy × medical table, and the
/// reason given when it may not.
final class SyncEligibilityTests: XCTestCase {
    private typealias E = SyncEligibility

    /// Everything in order: on Wi-Fi, on power, current, the office in reach, nothing else waiting.
    private func ready(_ change: (inout E.Conditions) -> Void = { _ in }) -> E.Conditions {
        var conditions = E.Conditions(network: .wifi, isCharging: true, batteryLevel: 0.2, profileIsCurrent: true,
                                      leaseIsCurrent: true, bindingIsCurrent: true, officeIsReachable: true)
        change(&conditions)
        return conditions
    }

    func testOnWiFiAndPowerWithEverythingCurrentARecordingMayGo() {
        XCTAssertEqual(E.evaluate(ready()), .eligible)
        XCTAssertTrue(E.evaluate(ready()).isEligible)
        XCTAssertEqual(E.reasons(ready()), [])
    }

    // MARK: - Network

    func testTheNetworkTable() {
        let table: [(E.Network, user: Bool, organisation: Bool, E.Verdict)] = [
            (.wifi, false, false, .eligible),
            (.wifi, false, true, .eligible),
            (.wifi, true, true, .eligible),
            (.none, false, false, .notEligible(.noNetwork)),
            (.none, true, false, .notEligible(.noNetwork)),
            (.cellular, false, false, .notEligible(.waitingForWiFi)),
            (.cellular, true, false, .eligible),
            (.cellular, false, true, .notEligible(.cellularForbiddenByOrganization)),
            (.cellular, true, true, .notEligible(.cellularForbiddenByOrganization)),
        ]
        for (network, user, organisation, expected) in table {
            let verdict = E.evaluate(ready {
                $0.network = network
                $0.cellularAllowedByUser = user
                $0.cellularForbiddenByOrganization = organisation
            })
            XCTAssertEqual(verdict, expected, "\(network), user \(user), organisation \(organisation)")
        }
    }

    func testMobileDataIsOffUnlessThePersonTurnsItOn() {
        let conditions = E.Conditions(network: .cellular, isCharging: true, batteryLevel: 1, profileIsCurrent: true,
                                      leaseIsCurrent: true, bindingIsCurrent: true, officeIsReachable: true)
        XCTAssertFalse(conditions.cellularAllowedByUser)
        XCTAssertEqual(E.evaluate(conditions), .notEligible(.waitingForWiFi))
    }

    // MARK: - Power

    func testThePowerTable() {
        let table: [(charging: Bool, battery: Double?, defers: Bool, E.Verdict)] = [
            (true, 0.05, false, .eligible),
            (true, nil, false, .eligible),
            (true, 0.05, true, .eligible),  // on power, the phone's saving posture does not hold it back
            (false, 0.9, false, .eligible),
            (false, 0.51, false, .eligible),
            (false, 0.5, false, .notEligible(.waitingForPower)),  // above the floor, not at it
            (false, 0.2, false, .notEligible(.waitingForPower)),
            (false, nil, false, .notEligible(.waitingForPower)),  // a battery that will not say is not full
            (false, 0.9, true, .notEligible(.savingPower)),
            (false, 0.2, true, .notEligible(.savingPower)),
        ]
        for (charging, battery, defers, expected) in table {
            let verdict = E.evaluate(ready {
                $0.isCharging = charging
                $0.batteryLevel = battery
                $0.powerDefersBulkTransfer = defers
            })
            XCTAssertEqual(verdict, expected, "charging \(charging), battery \(String(describing: battery)), defers \(defers)")
        }
        XCTAssertEqual(E.batteryFloor, 0.5)
    }

    // MARK: - Policy and medical

    func testThePolicyTable() {
        for profile in [true, false] {
            for lease in [true, false] {
                for binding in [true, false] {
                    let reasons = E.reasons(ready {
                        $0.profileIsCurrent = profile
                        $0.leaseIsCurrent = lease
                        $0.bindingIsCurrent = binding
                    })
                    var expected: [E.Reason] = []
                    if !profile { expected.append(.profileNotCurrent) }
                    if !lease { expected.append(.leaseNotCurrent) }
                    if !binding { expected.append(.bindingNotCurrent) }
                    XCTAssertEqual(reasons, expected, "profile \(profile), lease \(lease), binding \(binding)")
                }
            }
        }
    }

    func testAMedicalModeHoldsARecordingWhateverElseIsTrue() {
        XCTAssertEqual(E.evaluate(ready { $0.medicalModeOn = true }), .notEligible(.medicalMode))
        let everythingWrong = E.Conditions(network: .none, isCharging: false, batteryLevel: 0.1, profileIsCurrent: false,
                                           leaseIsCurrent: false, bindingIsCurrent: false, medicalModeOn: true,
                                           officeIsReachable: false, smallerItemsWaiting: true)
        XCTAssertEqual(E.evaluate(everythingWrong), .notEligible(.medicalMode))
    }

    // MARK: - The organisation's blur rule

    /// Where the organisation requires faces blurred and what is waiting is not, it is not sent —
    /// whatever else is true — and it says why.
    func testAnUnblurredRecordingIsHeldWhereTheOrganisationRequiresBlur() {
        XCTAssertFalse(ready().blurRequiredAndNotDone, "off unless the caller says so")
        XCTAssertEqual(E.evaluate(ready { $0.blurRequiredAndNotDone = true }), .notEligible(.blurRequired))
        let sentence = E.Reason.blurRequired.explanation
        XCTAssertTrue(sentence.contains("blurred") && sentence.contains("stays on this phone"), sentence)
        // A sealed recording cannot be blurred afterwards. What can be done about it is said.
        XCTAssertTrue(sentence.contains("can't be blurred now") && sentence.contains("You can delete it"), sentence)
        XCTAssertFalse(sentence.contains("yet"), "the app can blur a recording now; this one it cannot")
    }

    // MARK: - The office and smaller traffic

    func testAnOfficeOutOfReachHoldsIt() {
        XCTAssertEqual(E.evaluate(ready { $0.officeIsReachable = false }), .notEligible(.officeNotReachable))
    }

    func testJobReportsAndReceiptsGoFirst() {
        XCTAssertEqual(E.evaluate(ready { $0.smallerItemsWaiting = true }), .notEligible(.smallerItemsFirst))
    }

    // MARK: - Which reason is named

    func testWhenSeveralThingsAreInTheWayTheyAreNamedInOrder() {
        let everythingWrong = E.Conditions(network: .cellular, cellularForbiddenByOrganization: true, isCharging: false,
                                           batteryLevel: 0.1, profileIsCurrent: false, leaseIsCurrent: false,
                                           bindingIsCurrent: false, medicalModeOn: true, blurRequiredAndNotDone: true,
                                           officeIsReachable: false, smallerItemsWaiting: true)
        XCTAssertEqual(E.reasons(everythingWrong), [
            .medicalMode, .blurRequired, .profileNotCurrent, .leaseNotCurrent, .bindingNotCurrent, .cellularForbiddenByOrganization,
            .waitingForPower, .officeNotReachable, .smallerItemsFirst,
        ])
        XCTAssertEqual(E.evaluate(ready {
            $0.network = .none
            $0.isCharging = false
            $0.officeIsReachable = false
        }), .notEligible(.noNetwork))
    }

    // MARK: - Plain words

    func testEveryReasonIsASentenceForATechnician() {
        var seen: Set<String> = []
        for reason in E.Reason.allCases {
            let sentence = reason.explanation
            XCTAssertTrue(seen.insert(sentence).inserted, "two reasons with the same words: \(sentence)")
            XCTAssertTrue(sentence.first?.isUppercase == true && sentence.hasSuffix("."), sentence)
            // No plan letters, phase names or identifiers leak into what a person reads.
            for token in ["Plan", "HE", "P0", "P1", "FX", "lease", "binding", "profile", "posture", "eligible", "_"] {
                XCTAssertFalse(sentence.contains(token), "\(sentence) — \(token)")
            }
        }
        XCTAssertEqual(E.Reason.noNetwork.explanation, "Waiting for Wi-Fi.")
        XCTAssertEqual(E.Reason.waitingForPower.explanation, "Waiting for power. Plug the phone in to send the recording.")
        XCTAssertEqual(E.Reason.smallerItemsFirst.explanation, "Job reports are being sent first.")
    }
}
