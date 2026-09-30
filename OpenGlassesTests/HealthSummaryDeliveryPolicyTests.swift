import XCTest
@testable import OpenGlasses

/// Plan GI P1 — health numbers reach a model only when it runs on the phone, or when the wearer has
/// turned sharing on; Medical Compliance keeps them from any model.
final class HealthSummaryDeliveryPolicyTests: XCTestCase {

    /// Every one of the sixteen combinations, against the rule written out longhand.
    func testEveryCombination() {
        for local in [false, true] {
            for share in [false, true] {
                for hipaa in [false, true] {
                    for localOnly in [false, true] {
                        let expected: HealthSummaryDeliveryPolicy.Delivery
                        if hipaa || localOnly {
                            expected = .speakDirect
                        } else if local || share {
                            expected = .returnToModel
                        } else {
                            expected = .speakDirect
                        }
                        XCTAssertEqual(
                            HealthSummaryDeliveryPolicy.decide(activeModelIsLocal: local, shareHealthWithAI: share,
                                                               hipaaMode: hipaa, medicalLocalOnly: localOnly),
                            expected, "local=\(local) share=\(share) hipaa=\(hipaa) localOnly=\(localOnly)")
                    }
                }
            }
        }
    }

    func testMedicalComplianceAlwaysSpeaksDirect() {
        for local in [false, true] {
            for share in [false, true] {
                XCTAssertEqual(HealthSummaryDeliveryPolicy.decide(activeModelIsLocal: local, shareHealthWithAI: share,
                                                                  hipaaMode: true, medicalLocalOnly: false),
                               .speakDirect)
            }
        }
    }

    func testTheDefaultCloudSetupKeepsNumbersFromTheModel() {
        XCTAssertEqual(HealthSummaryDeliveryPolicy.decide(activeModelIsLocal: false, shareHealthWithAI: false,
                                                          hipaaMode: false, medicalLocalOnly: false),
                       .speakDirect)
    }

    func testReceiptsCarryNoDigits() {
        for receipt in [HealthSummaryDeliveryPolicy.receipt, HealthSummaryDeliveryPolicy.notSpokenReceipt] {
            XCTAssertFalse(receipt.contains(where: \.isNumber), receipt)
        }
    }
}
