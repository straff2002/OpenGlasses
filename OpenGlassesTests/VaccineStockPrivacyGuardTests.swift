import XCTest
@testable import OpenGlasses

/// Plan MY Decision 1 and §9 — a clinic's stock list is the fridge's record, never a second
/// patient log: `van_stock` offers no field for a patient, a movement has no free-text field, and
/// a clinic's sentences say "given", "doses" and "lot", never "van", "part" or "used". The
/// clinical flag is the organisation's to lock.
@MainActor
final class VaccineStockPrivacyGuardTests: XCTestCase {

    /// Words a field name could carry if it were about a person.
    private static let personWords = ["patient", "person", "name", "nhi", "dob", "birth", "mrn", "who", "recipient",
                                      "client", "customer", "medicare", "insurance", "address", "phone", "email",
                                      "note", "comment", "free_text", "encounter", "appointment"]

    /// Every property name in a schema, nested `items` included.
    private func propertyNames(_ schema: [String: Any]) -> [String] {
        var names: [String] = []
        if let properties = schema["properties"] as? [String: Any] {
            for (name, value) in properties {
                names.append(name)
                if let nested = value as? [String: Any] {
                    names += propertyNames(nested)
                    if let items = nested["items"] as? [String: Any] { names += propertyNames(items) }
                }
            }
        }
        return names
    }

    func testTheToolsSchemaHasNoPatientLikeParameter() {
        for kind in StockPlace.Kind.allCases {
            for clinical in [false, true] {
                let names = propertyNames(VanStockTool.parametersSchema(for: kind, clinical: clinical))
                XCTAssertFalse(names.isEmpty)
                for name in names {
                    let lowered = name.lowercased()
                    XCTAssertFalse(Self.personWords.contains { lowered.contains($0) },
                                   "\(kind) clinical=\(clinical): '\(name)' could carry a person")
                }
            }
            let system = propertyNames(VanStockTool.parametersSchema(for: kind, system: "Example system"))
            XCTAssertFalse(system.contains { name in Self.personWords.contains { name.lowercased().contains($0) } })
        }
    }

    func testAClinicsSchemaTakesALotAWasteReasonAndCartons() throws {
        let schema = VanStockTool.parametersSchema(for: .stock, clinical: true)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        for wanted in ["lot", "waste_reason", "cartons", "doses_per_carton"] {
            XCTAssertNotNil(properties[wanted], wanted)
        }
        let actions = try XCTUnwrap((properties["action"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(Set(["give", "waste", "receive", "count"]).isSubset(of: Set(actions)))
        let reasons = try XCTUnwrap((properties["waste_reason"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(reasons, ["expired", "cold_chain", "drawn_up_not_given", "broken", "opened_vial_discarded", "other"])
        // A list that is not a clinic's is offered exactly what it was.
        let van = try XCTUnwrap(VanStockTool.parametersSchema(for: .van)["properties"] as? [String: Any])
        XCTAssertNil(van["lot"])
        XCTAssertNil(van["waste_reason"])
        XCTAssertEqual((van["action"] as? [String: Any])?["enum"] as? [String], VanStockTool.actions)
    }

    /// A movement's fields are a closed set: a new field (a note, a name) fails here until it is
    /// argued for. `oldValue`/`newValue` hold a line's edited attribute, never a person.
    func testAMovementCarriesNoFreeTextField() {
        let movement = VanStockMovement(itemID: "flu", kind: .used, at: Date(), batch: "b", source: .spoken)
        let fields = Set(Mirror(reflecting: movement).children.compactMap(\.label))
        XCTAssertEqual(fields, ["id", "itemID", "kind", "quantity", "at", "batch", "source", "jobSessionID",
                                "jobReference", "reason", "requestID", "reverses", "attribute", "oldValue",
                                "newValue", "openingCounted", "openingUnreliable", "lotID", "wasteReason"])
        let lot = StockLot(id: "l", itemID: "flu", code: "ZZ1001", expiry: nil, firstReceived: Date(), createdBatch: "b")
        XCTAssertEqual(Set(Mirror(reflecting: lot).children.compactMap(\.label)),
                       ["id", "itemID", "code", "expiry", "firstReceived", "createdBatch", "hidden"],
                       "a lot's fields are its code, expiry, dates and the count's hidden flag; never free text")
    }

    func testTheClinicalDescriptionSaysItIsNotThePatientsRecord() {
        let description = VanStockTool.description(for: .stock, system: nil, clinical: true)
        XCTAssertTrue(description.contains("not the patient's immunisation record"), description)
        XCTAssertTrue(description.contains("Never pass, say or keep the name"), description)
        XCTAssertEqual(VanStockTool.description(for: .van, system: nil, clinical: false), VanStockTool.description(for: .van))
    }

    // MARK: - Wording

    /// No "van", "part" or "used" in a clinic's sentences, for every place kind.
    func testAClinicsSentencesSayGivenDosesAndLot() {
        let today = StockDay(year: 2026, month: 11, day: 22)!
        let item = VanStockItem(id: "flu", description: "the flu vaccine", codes: ["02000000000015"], dosesPerCarton: 10,
                                createdBatch: "b")
        let lot = StockLot(id: "a", itemID: "flu", code: "ZZ1001", expiry: StockDay(year: 2027, month: 3, day: 31),
                           firstReceived: Date(), createdBatch: "b")
        let older = StockLot(id: "o", itemID: "flu", code: "ZZ0999", expiry: StockDay(year: 2026, month: 12, day: 31),
                             firstReceived: Date(), createdBatch: "b")
        var level = VanStockLevel(itemID: "flu", onHand: StockQuantity(whole: 9), asOf: Date())
        level.lots = ["a": StockLotLevel(lotID: "a", onHand: StockQuantity(whole: 4), asOf: Date()),
                      "o": StockLotLevel(lotID: "o", onHand: StockQuantity(whole: 5), asOf: Date())]
        let one = StockQuantity(whole: 1)
        for kind in StockPlace.Kind.allCases {
            let w = StockPlaceWording(kind, clinical: true)
            let composer = StockLotComposer(wording: w)
            let sentences = [
                composer.given(item, quantity: one, lot: lot, after: level, older: older),
                composer.givenDone(item, quantity: one, lot: lot),
                composer.wasted(item, quantity: one, reason: .coldChain, lot: lot, after: level),
                composer.wastedDone(item, quantity: one, reason: .expired, lot: lot),
                composer.received(item, quantity: StockQuantity(whole: 10), lot: lot, newLot: true, after: level),
                composer.lotCounted(item, lot: lot, newLot: false, check: .short(expected: one + one, by: one), after: level),
                composer.whichLot(item, lots: [lot, older], levels: level.lots, today: today),
                composer.lotNotHeld(item, said: "ZZ9", lots: [lot]),
                composer.newLotOnGiven(item, code: "ZZ9"),
                composer.expiredOnGiven(item, lot: older),
                composer.noCartonSize(item),
                composer.lotsSummary(item, lots: [lot, older], levels: level.lots, today: today, calendar: .current) ?? "",
                w.toolLead, w.useGloss, w.takenVerb, w.takenFrom, w.goods,
                VanStockTool.description(for: kind, clinical: true),
            ]
            for sentence in sentences {
                for word in ["van", "truck", "part", "parts", "used"] {
                    let pattern = "\\b" + word + "\\b"
                    XCTAssertNil(sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                                 "\(kind): '\(word)' in: \(sentence)")
                }
            }
            XCTAssertEqual(w.takenVerb, "given")
            XCTAssertEqual(w.goods, "doses")
            XCTAssertEqual(w.amount(StockQuantity(whole: 3), of: item), "3 doses of the flu vaccine")
            XCTAssertEqual(w.amount(one, of: item), "1 dose of the flu vaccine")
            XCTAssertEqual(w.recordNote, "This is a stock record, not the immunisation record.")
        }
    }

    func testAListThatIsNotAClinicsReadsAsItAlwaysHas() {
        for kind in StockPlace.Kind.allCases {
            let plain = StockPlaceWording(kind)
            XCTAssertFalse(plain.clinical)
            XCTAssertEqual(plain, StockPlaceWording(kind, clinical: false))
            XCTAssertNotEqual(plain.takenVerb, "given")
            XCTAssertEqual(plain.recordNote, "")
        }
    }

    // MARK: - Who sets it (Decision 12)

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Example Clinic",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    func testTheClinicalFlagFollowsTheProfileOverTheList() {
        XCTAssertEqual(StockClinicalSetting.resolve(profile: nil, list: nil), .init(clinical: false, isLocked: false))
        XCTAssertEqual(StockClinicalSetting.resolve(profile: nil, list: true), .init(clinical: true, isLocked: false))
        XCTAssertEqual(StockClinicalSetting.resolve(profile: true, list: false), .init(clinical: true, isLocked: true))
        XCTAssertEqual(StockClinicalSetting.resolve(profile: false, list: true), .init(clinical: false, isLocked: true))
    }

    func testTheProfileKeyIsOwnedLockedAndSummarised() {
        let key = SettingKey.organizationStockClinical
        XCTAssertEqual(key.kind, .profileOwned(.bool))
        XCTAssertEqual(VaccineStockPolicy.clinicalProfileKey, key)
        let result = apply([key.rawValue: RawSetting(.bool(true), .default)])
        XCTAssertEqual(result.owned[key], .bool(true))
        XCTAssertTrue(result.isLocked(key))
        XCTAssertTrue(result.drops.isEmpty)
        let wrongType = apply([key.rawValue: RawSetting(.string("yes"), .default)])
        XCTAssertNil(wrongType.owned[key])
        XCTAssertFalse(wrongType.drops.isEmpty)
        XCTAssertEqual(key.ownedDescription(.bool(true)), "The stock list is a clinic's: doses given and wasted, by lot")
        XCTAssertEqual(key.ownedDescription(.bool(false)), "The stock list is not a clinic's")
        XCTAssertNotEqual(key.ownedDescription, key.rawValue)
    }

    func testTheProfilesFlagLocksTheListAndIsNeverWrittenIntoIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clinical-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VanStockStore(directory: directory)
        XCTAssertEqual(store.resolvedClinical, .init(clinical: false, isLocked: false))
        store.setClinical(true)
        XCTAssertEqual(store.resolvedClinical, .init(clinical: true, isLocked: false))

        let key = SettingKey.organizationStockClinical
        PolicyEnvelope.install(apply([key.rawValue: RawSetting(.bool(false), .default)]), organizationName: "Example Clinic")
        defer { PolicyEnvelope.clear() }
        XCTAssertEqual(Config.organizationStockClinical, false)
        XCTAssertEqual(store.resolvedClinical, .init(clinical: false, isLocked: true))
        XCTAssertEqual(store.van?.clinical, true, "the profile's value is resolved over the list's, not written in")

        PolicyEnvelope.clear()
        XCTAssertNil(Config.organizationStockClinical)
        XCTAssertEqual(store.resolvedClinical, .init(clinical: true, isLocked: false))
    }
}
