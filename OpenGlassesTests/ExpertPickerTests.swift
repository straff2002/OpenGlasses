import XCTest
@testable import OpenGlasses

// Plan KM P0 — the list and the pick. Invented people and numbers throughout (the 555-01xx range
// and example.test addresses).

private enum Fixture {
    static func expert(_ id: String, _ name: String, phone: String? = "+1 555 0100",
                       handle: String? = nil, tags: [String] = [], kind: EscalationContact.Kind = .staff,
                       onCall: [OnCallWindow] = [], zone: String? = nil,
                       rate: EscalationContact.Rate? = nil) -> EscalationContact {
        EscalationContact(id: id, name: name, phone: phone, faceTimeHandle: handle, specialties: tags,
                          kind: kind, onCall: onCall, timeZoneIdentifier: zone, rate: rate)
    }

    static let rate = EscalationContact.Rate(perHour: 90, minimumMinutes: 15, roundingMinutes: 15, currency: "USD")

    /// 2026-11-06 (a Friday) at the given UTC time.
    static func friday(_ hour: Int, _ minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 6; parts.hour = hour; parts.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: parts)!
    }

    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func window(_ day: Int, _ start: Int, _ end: Int) -> OnCallWindow {
        OnCallWindow(weekday: day, startMinute: start, endMinute: end)!
    }

    static func isolatedDefaults() -> UserDefaults {
        let name = "ExpertPickerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

// MARK: - Who the experts are

final class EscalationContactTests: XCTestCase {

    func testAStaffExpertNeverCarriesARate() {
        let staff = Fixture.expert("a", "Sam Okafor", kind: .staff, rate: Fixture.rate)
        XCTAssertNil(staff.rate, "the memberwise init drops a staff expert's rate")
        let contracted = Fixture.expert("b", "Priya Raman", kind: .contracted, rate: Fixture.rate)
        XCTAssertEqual(contracted.rate, Fixture.rate)
    }

    func testDecodingRefusesAStaffExpertWithARate() {
        let json = #"[{"id":"a","name":"Sam Okafor","phone":"+15550100","kind":"staff","rate":{"perHour":90,"minimumMinutes":15,"roundingMinutes":15,"currency":"USD"}}]"#
        guard case .failure(let problem) = ExpertListCodec.decode(json) else { return XCTFail("a staff rate must be refused") }
        XCTAssertTrue(problem.message.contains("rate"), problem.message)
    }

    func testAPersonalAdditionCannotCarryARateOrAKind() throws {
        // The type has no such fields at all…
        let labels = Set(Mirror(reflecting: PersonalExpert(name: "Lee Moreno", phone: "+15550101")).children.compactMap(\.label))
        XCTAssertFalse(labels.contains("rate"))
        XCTAssertFalse(labels.contains("kind"))
        XCTAssertFalse(labels.contains("onCall"))

        // …so a stored payload that tries decodes without them, and the entry is staff with no rate.
        let tampered = #"[{"id":"p1","name":"Lee Moreno","phone":"+15550101","specialties":["boiler"],"kind":"contracted","rate":{"perHour":500,"minimumMinutes":60,"roundingMinutes":60,"currency":"USD"}}]"#
        let defaults = Fixture.isolatedDefaults()
        defaults.set(Data(tampered.utf8), forKey: ExpertListStore.personalKey)
        let store = ExpertListStore(defaults: defaults, profileList: { nil })
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.source, .personal)
        XCTAssertEqual(entry.contact.kind, .staff)
        XCTAssertNil(entry.contact.rate)
        XCTAssertEqual(entry.contact.specialties, ["boiler"])

        // Saving one back writes no rate either.
        store.setPersonalExperts(store.personalExperts)
        let saved = String(data: try XCTUnwrap(defaults.data(forKey: ExpertListStore.personalKey)), encoding: .utf8) ?? ""
        XCTAssertFalse(saved.contains("rate"), saved)
        XCTAssertFalse(saved.contains("contracted"), saved)
    }

    func testTheListRoundTripsAndKeepsItsWindows() throws {
        let list = [
            Fixture.expert("a", "Sam Okafor", handle: "sam@example.test", tags: ["furnace", "Lennox"],
                           onCall: [Fixture.window(6, 22 * 60, 6 * 60)], zone: "America/Chicago"),
            Fixture.expert("b", "Priya Raman", phone: "+1 555 0102", tags: ["heat pump"], kind: .contracted,
                           rate: Fixture.rate),
        ]
        let text = ExpertListCodec.encode(list)
        XCTAssertTrue(text.contains(#""day":"fri""#), text)
        XCTAssertTrue(text.contains(#""start":"22:00""#), text)
        XCTAssertEqual(try ExpertListCodec.decode(text).get(), list)
    }

    func testAnEntryWithoutAnIdGetsAStableOne() throws {
        let json = #"[{"name":"Sam Okafor","phone":"+15550100"}]"#
        let first = try ExpertListCodec.decode(json).get()
        let second = try ExpertListCodec.decode(json).get()
        XCTAssertEqual(first.first?.id, second.first?.id)
        XCTAssertEqual(first.first?.kind, .staff)
    }

    func testABadEntryRefusesTheWholeList() {
        for json in [
            #"[{"name":"Sam Okafor"}]"#,                                         // nothing to ring
            #"[{"name":"Sam Okafor","phone":"tel:5550100?x=1"}]"#,               // not a number
            #"[{"name":"Sam Okafor","phone":"+15550100","kind":"oncall"}]"#,     // unknown kind
            #"[{"name":"Sam Okafor","phone":"+15550100","timeZone":"Mars/Base"}]"#,
            #"[{"name":"Sam Okafor","phone":"+15550100","onCall":[{"day":"fri","start":"25:00","end":"06:00"}]}]"#,
            #"[{"id":"a","name":"Sam Okafor","phone":"+15550100"},{"id":"a","name":"Priya Raman","phone":"+15550102"}]"#,
            #"{"name":"Sam Okafor"}"#,
        ] {
            guard case .failure = ExpertListCodec.decode(json) else { return XCTFail("should refuse \(json)") }
        }
    }

    // MARK: The profile key

    func testOrganizationExpertsIsProfileOwnedAndRoundTrips() throws {
        XCTAssertEqual(SettingKey.organizationExperts.kind, .profileOwned(.string))
        XCTAssertEqual(SettingKey.organizationExperts.rawValue, ExpertListStore.organizationKey)
        let list = [Fixture.expert("a", "Sam Okafor", tags: ["furnace"]),
                    Fixture.expert("b", "Priya Raman", phone: "+15550102", kind: .contracted, rate: Fixture.rate)]
        let text = ExpertListCodec.encode(list)
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Example Heating",
                                    issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: 30,
                                    settings: ["organizationExperts": RawSetting(.string(text), .default)])
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
        XCTAssertTrue(result.drops.isEmpty, "\(result.drops)")
        XCTAssertTrue(result.isLocked(.organizationExperts))
        guard case .string(let owned)? = result.owned[.organizationExperts] else { return XCTFail("not owned") }
        XCTAssertEqual(try ExpertListCodec.decode(owned).get(), list)
        // Profile-owned: what the person stored is never what a read returns.
        XCTAssertEqual(result.effectiveValue(.organizationExperts, stored: .string("[]")), .string(text))
        XCTAssertEqual(SettingKey.organizationExperts.ownedDescription, "The experts you can call for help on a job")
    }

    func testABadProfileListIsANamedDrop() {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Example Heating",
                                    issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: 30,
                                    settings: ["organizationExperts": RawSetting(.string(#"[{"name":"Sam"}]"#), .default)])
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
        XCTAssertEqual(result.drops.map(\.key), ["organizationExperts"])
        XCTAssertFalse(result.isLocked(.organizationExperts))
        let wrongType = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Example Heating",
                                      issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: 30,
                                      settings: ["organizationExperts": RawSetting(.strings(["Sam"]), .default)])
        XCTAssertEqual(ProfileApplier.apply(profile: wrongType, resolvableVaultIds: []).drops.first?.reason,
                       .wrongType(expected: .string))
    }

    // MARK: Two sources, one list

    func testWithAProfileOnlyTheProfileSetsTheOrganisationsExperts() {
        let defaults = Fixture.isolatedDefaults()
        let owner = ExpertListStore(defaults: defaults, profileList: { nil })
        XCTAssertNil(owner.setDeviceOwnerExperts([Fixture.expert("o", "Dana Ito", kind: .contracted, rate: Fixture.rate)]))
        XCTAssertEqual(owner.organizationExperts.first?.rate, Fixture.rate, "with no profile the device owner sets rates")

        let profileList = [Fixture.expert("a", "Sam Okafor")]
        let managed = ExpertListStore(defaults: defaults, profileList: { profileList })
        XCTAssertTrue(managed.organizationListIsManaged)
        XCTAssertEqual(managed.organizationExperts, profileList)
        XCTAssertNotNil(managed.setDeviceOwnerExperts([]), "a profile's list is not the phone's to change")
        XCTAssertEqual(managed.deviceOwnerExperts.map(\.id), ["o"], "the owner's list waits under the profile")

        let managedWithoutList = ExpertListStore(defaults: defaults, profileList: { [] })
        XCTAssertEqual(managedWithoutList.organizationExperts, [], "a profile without a list sets none")
    }

    func testTheMergedListMarksSourcesAndKeepsTheOrganisationsEntry() {
        let organization = [Fixture.expert("a", "Sam Okafor", phone: "+1 555 0100")]
        let personal = [PersonalExpert(id: "p1", name: "Sam O", phone: "+15550100"),
                        PersonalExpert(id: "p2", name: "Lee Moreno", phone: "+15550101")]
        let merged = ExpertListStore.merged(organization: organization, personal: personal)
        XCTAssertEqual(merged.map(\.id), ["a", "p2"])
        XCTAssertEqual(merged.map(\.source), [.organization, .personal])
    }
}

// MARK: - Choosing among three

final class ExpertPickerTests: XCTestCase {

    private let sam = Fixture.expert("sam", "Sam Okafor", tags: ["furnace", "Lennox"])
    private let priya = Fixture.expert("priya", "Priya Raman", phone: "+15550102", tags: ["furnace"])
    private let lee = Fixture.expert("lee", "Lee Moreno", phone: "+15550103", tags: ["heat pump", "refrigeration"])

    private func pick(_ request: String, job: ExpertPicker.Job = .none, experts: [EscalationContact]? = nil,
                      now: Date = Fixture.friday(15), last: String? = nil) -> ExpertPicker.Pick {
        ExpertPicker.pick(.init(request: request, job: job, experts: experts ?? [sam, priya, lee],
                                now: now, lastCalledExpertId: last))
    }

    func testSpecialtyFromTheWords() {
        let result = pick("get me a furnace expert")
        XCTAssertEqual(result.ordered.map(\.contact.id), ["sam", "priya"])
        XCTAssertEqual(result.match, .words(["furnace"]))
        XCTAssertEqual(result.sentence, "Two furnace experts. Sam is on call. Call Sam?")
    }

    func testAMultiWordSpecialtyAndPluralsMatch() {
        XCTAssertEqual(pick("anyone good with heat pumps").ordered.map(\.contact.id), ["lee"])
        XCTAssertEqual(pick("call a heat expert").match, .none, "half a tag is not the tag")
    }

    func testSpecialtyFromTheJobsEquipmentWhenTheWordsNameNone() {
        let job = ExpertPicker.Job(trades: ["refrigeration_hvac"], equipment: ["Lennox SLP99 furnace"])
        let result = pick("get me an expert", job: job)
        // The equipment names furnace, Lennox and refrigeration; only Sam holds all three? No —
        // nobody does, so the narrowest step that leaves someone is "holds any".
        XCTAssertEqual(Set(result.ordered.map(\.contact.id)), ["sam", "priya", "lee"])
        guard case .equipment(let tags) = result.match else { return XCTFail("\(result.match)") }
        XCTAssertTrue(tags.contains("Lennox"))
    }

    func testTheEquipmentNarrowsWhatTheWordsLeft() {
        let job = ExpertPicker.Job(equipment: ["Lennox SLP99"])
        let result = pick("furnace expert please", job: job)
        XCTAssertEqual(result.ordered.map(\.contact.id), ["sam"], "of the two furnace experts, Sam knows Lennox")
        XCTAssertEqual(result.match, .words(["furnace"]))
        XCTAssertEqual(result.sentence, "One furnace expert. Sam is on call. Call Sam?")
    }

    func testNoSpecialtyNamedOffersEveryone() {
        let result = pick("get me an expert")
        XCTAssertEqual(result.ordered.count, 3)
        XCTAssertEqual(result.sentence, "Three experts. Sam is on call. Call Sam?")
    }

    // MARK: On call

    func testOnCallFirstThenTheRest() {
        // Sam is on call Mondays only; Priya any time. Friday: Priya first.
        let mondays = Fixture.expert("sam", "Sam Okafor", tags: ["furnace"], onCall: [Fixture.window(2, 9 * 60, 17 * 60)],
                                     zone: "UTC")
        let result = pick("furnace expert", experts: [mondays, priya])
        XCTAssertEqual(result.ordered.map(\.contact.id), ["priya", "sam"])
        XCTAssertEqual(result.ordered.map(\.isOnCall), [true, false])
        XCTAssertEqual(result.sentence, "Two furnace experts. Priya is on call. Call Priya?")
    }

    func testNobodyOnCallIsSaid() {
        let off = Fixture.expert("sam", "Sam Okafor", tags: ["furnace"], onCall: [Fixture.window(2, 9 * 60, 17 * 60)], zone: "UTC")
        XCTAssertEqual(pick("furnace", experts: [off]).sentence,
                       "One furnace expert. Sam isn't on call now. Call Sam anyway?")
        let alsoOff = Fixture.expert("priya", "Priya Raman", phone: "+15550102", tags: ["furnace"],
                                     onCall: [Fixture.window(2, 9 * 60, 17 * 60)], zone: "UTC")
        XCTAssertEqual(pick("furnace", experts: [off, alsoOff]).sentence,
                       "Two furnace experts. None is on call now. Call Sam anyway?")
    }

    func testWindowsAreReadInTheExpertsOwnTimeZone() {
        // 09:00–17:00 Friday in Chicago (UTC−6 in November).
        let window = Fixture.window(6, 9 * 60, 17 * 60)
        let chicago = TimeZone(identifier: "America/Chicago")!
        XCTAssertFalse(window.contains(Fixture.friday(14, 59), in: chicago), "08:59 in Chicago")
        XCTAssertTrue(window.contains(Fixture.friday(15), in: chicago), "09:00 in Chicago")
        XCTAssertTrue(window.contains(Fixture.friday(22, 59), in: chicago), "16:59 in Chicago")
        XCTAssertFalse(window.contains(Fixture.friday(23), in: chicago), "17:00 in Chicago")
        // The same instant is 15:00 in London, outside a London 09:00–12:00.
        XCTAssertFalse(Fixture.window(6, 9 * 60, 12 * 60).contains(Fixture.friday(15), in: TimeZone(identifier: "Europe/London")!))
    }

    func testAWindowCrossingMidnightCoversTheSmallHours() {
        let night = Fixture.window(6, 22 * 60, 6 * 60) // Friday 22:00 to Saturday 06:00
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(night.contains(Fixture.friday(23), in: utc))
        XCTAssertTrue(night.contains(Fixture.utc(2026, 11, 7, 5, 59), in: utc), "Saturday 05:59")
        XCTAssertFalse(night.contains(Fixture.utc(2026, 11, 7, 6, 0), in: utc), "Saturday 06:00")
        XCTAssertFalse(night.contains(Fixture.friday(21, 59), in: utc))
        XCTAssertFalse(night.contains(Fixture.utc(2026, 11, 6, 3, 0), in: utc), "Friday 03:00 is Thursday night's")
        // Saturday into Sunday wraps the week.
        let saturday = Fixture.window(7, 23 * 60, 2 * 60)
        XCTAssertTrue(saturday.contains(Fixture.utc(2026, 11, 8, 1, 0), in: utc), "Sunday 01:00")
    }

    func testDaylightSavingFollowsTheWallClock() {
        // London leaves summer time on Sunday 25 October 2026. A Monday 09:00–17:00 window is
        // 08:00Z the Monday before and 09:00Z the Monday after.
        let window = Fixture.window(2, 9 * 60, 17 * 60)
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertTrue(window.contains(Fixture.utc(2026, 10, 19, 8, 0), in: london))
        XCTAssertFalse(window.contains(Fixture.utc(2026, 10, 26, 8, 0), in: london))
        XCTAssertTrue(window.contains(Fixture.utc(2026, 10, 26, 9, 0), in: london))
    }

    func testNoWindowsMeansAnyTime() {
        XCTAssertTrue(ExpertPicker.isOnCall(sam, at: Fixture.utc(2026, 11, 8, 3, 0)))
    }

    // MARK: Rota

    func testTheRotaRotatesFromTheLastExpertCalled() {
        XCTAssertEqual(pick("furnace").offered?.id, "sam")
        XCTAssertEqual(pick("furnace", last: "sam").offered?.id, "priya")
        XCTAssertEqual(pick("furnace", last: "priya").offered?.id, "sam", "past the end it wraps")
        XCTAssertEqual(pick("furnace", last: "lee").offered?.id, "sam", "a call to someone else moves the rota too")
        XCTAssertEqual(pick("furnace", last: "gone").offered?.id, "sam", "an id no longer listed starts at the top")
        XCTAssertEqual(ExpertPicker.rotaOrder([sam, priya, lee], after: "priya").map(\.id), ["lee", "sam", "priya"])
    }

    func testTheRotaPersistsPerPhone() {
        let defaults = Fixture.isolatedDefaults()
        let store = ExpertListStore(defaults: defaults, profileList: { nil })
        XCTAssertNil(store.lastCalledExpertId)
        store.lastCalledExpertId = "sam"
        XCTAssertEqual(ExpertListStore(defaults: defaults, profileList: { nil }).lastCalledExpertId, "sam")
    }

    // MARK: Fixed rules only

    /// No expert or technician is ranked by outcomes, ratings or call history: the picker's inputs
    /// have nowhere to hold one. A field added to any of these types fails here, and has to be
    /// argued for.
    func testNoRankingInputExists() {
        let input = ExpertPicker.Input(request: "", job: .none, experts: [sam], now: Date(), lastCalledExpertId: nil)
        XCTAssertEqual(Set(Mirror(reflecting: input).children.compactMap(\.label)),
                       ["request", "job", "experts", "now", "lastCalledExpertId"])
        XCTAssertEqual(Set(Mirror(reflecting: ExpertPicker.Job.none).children.compactMap(\.label)),
                       ["trades", "equipment"])
        XCTAssertEqual(Set(Mirror(reflecting: sam).children.compactMap(\.label)),
                       ["id", "name", "phone", "faceTimeHandle", "handoverChannel", "specialties", "kind",
                        "onCall", "timeZoneIdentifier", "rate",
                        // Plan KM P3, decision 10: a human-set agreement term, not a ranking input.
                        "coachingMayBecomeTeamLearning"])
        XCTAssertEqual(Set(Mirror(reflecting: Fixture.window(1, 0, 60)).children.compactMap(\.label)),
                       ["weekday", "startMinute", "endMinute"])
        let forbidden = ["score", "rating", "rank", "outcome", "history", "count", "success", "weight"]
        for label in Mirror(reflecting: sam).children.compactMap(\.label) {
            XCTAssertFalse(forbidden.contains { label.lowercased().contains($0) }, label)
        }
    }

    func testTheSentenceNamesTheExpertNeverAPronoun() {
        for request in ["furnace", "heat pump", "expert"] {
            let words = TechnicianRequest.words(pick(request).sentence)
            for pronoun in ["him", "her", "he", "she", "his", "hers", "them"] {
                XCTAssertFalse(words.contains(pronoun), pick(request).sentence)
            }
        }
    }

    func testASharedFirstNameIsSaidInFull() {
        let other = Fixture.expert("sam2", "Sam Reyes", phone: "+15550104", tags: ["furnace"])
        XCTAssertEqual(pick("furnace", experts: [sam, other]).sentence,
                       "Two furnace experts. Sam Okafor is on call. Call Sam Okafor?")
    }

    // MARK: By name

    func testByNameFindsTheExpert() {
        XCTAssertEqual(ExpertNameMatch.resolve("Sam", in: [sam, priya, lee]), .one(sam))
        XCTAssertEqual(ExpertNameMatch.resolve("call Priya Raman", in: [sam, priya, lee]), .one(priya))
        XCTAssertEqual(ExpertNameMatch.resolve("Jordan", in: [sam, priya, lee]), .none)
        let other = Fixture.expert("sam2", "Sam Reyes", phone: "+15550104")
        XCTAssertEqual(ExpertNameMatch.resolve("Sam", in: [sam, other]), .several([sam, other]))
        XCTAssertEqual(ExpertNameMatch.resolve("Sam Reyes", in: [sam, other]), .one(other))
    }

    // MARK: No answer

    func testNoAnswerOffersTheNextInTurn() {
        XCTAssertEqual(NoAnswerOffer.next(after: sam, in: [sam, priya, lee]), priya)
        XCTAssertNil(NoAnswerOffer.next(after: lee, in: [sam, priya, lee]))
        XCTAssertEqual(NoAnswerOffer.sentence(missed: sam, next: priya), "Sam didn't answer. Try Priya?")
        XCTAssertEqual(NoAnswerOffer.sentence(missed: sam, next: nil), "Sam didn't answer.")
    }
}

// MARK: - The route

final class CallRouteTests: XCTestCase {

    private func contact(phone: String? = nil, handle: String? = nil) -> EscalationContact {
        EscalationContact(id: "x", name: "Sam Okafor", phone: phone, faceTimeHandle: handle)
    }

    func testRoutesFromANumberAndAHandle() {
        XCTAssertEqual(CallRoute.make(contact(phone: "+1 (555) 010-0100"), via: .phone)?.url.absoluteString, "tel:+15550100100")
        XCTAssertEqual(CallRoute.make(contact(phone: "+15550100", handle: "Sam@Example.test"), via: .faceTime)?.url.absoluteString,
                       "facetime:sam@example.test")
        XCTAssertEqual(CallRoute.make(contact(handle: "sam.o+jobs@example.test"), via: .faceTimeAudio)?.url.absoluteString,
                       "facetime-audio:sam.o+jobs@example.test")
        XCTAssertEqual(CallRoute.make(contact(phone: "555 0100"), via: .faceTime)?.url.absoluteString, "facetime:5550100",
                       "FaceTime rings the number when there is no handle")
        XCTAssertNil(CallRoute.make(contact(handle: "sam@example.test"), via: .phone), "no number, no voice call")
        XCTAssertEqual(CallRoute.defaultVia(for: contact(handle: "sam@example.test")), .faceTime)
        XCTAssertEqual(CallRoute.defaultVia(for: contact(phone: "5550100")), .phone)
    }

    func testRefusesAnythingButACleanedNumber() {
        for raw in ["tel:5550100", "5550100?call=1", "5550100&x", "555/0100", "5550100;ext=2", "5550100,,1234",
                    "*67 5550100", "#31#5550100", "555%300100", "55501\n00", "555\u{0}0100", "\u{202E}5550100",
                    "+1+5550100", "5550+100", "١٢٣٤٥٦٧", "５５５０１００", "12", "1234567890123456", "",
                    "javascript:alert(1)", "sam@example.test", "555 0100 x", "５"] {
            XCTAssertNil(CallRoute.cleanedNumber(raw), "accepted \(raw.debugDescription)")
        }
        XCTAssertEqual(CallRoute.cleanedNumber("  +44 20 7946 0000 "), "+442079460000")
        XCTAssertEqual(CallRoute.cleanedNumber("555.010.0100"), "5550100100")
    }

    func testRefusesAnythingButACleanedHandle() {
        for raw in ["sam@example", "sam@@example.test", "@example.test", "sam@.example.test", "sam@example..test",
                    "sam @example.test", "sam@example.test?subject=x", "sam@example.test/x", "facetime:sam@example.test",
                    "sam%40example.test", "sam@exa mple.test", "sam@example.t3st", ".sam@example.test",
                    "sam..o@example.test", "sam@example.test\u{202E}", "sam;x@example.test"] {
            XCTAssertNil(CallRoute.cleanedHandle(raw), "accepted \(raw.debugDescription)")
        }
        XCTAssertEqual(CallRoute.cleanedHandle("+1 555 0100"), "+15550100")
    }

    func testTheContactSnapshotKeepsOnlyADialableNumber() {
        XCTAssertEqual(ContactSnapshot.cleanedPhone("\u{202A}+1 (555) 010-0100\u{202C}"), "+15550100100")
        XCTAssertEqual(ContactSnapshot.cleanedPhone("555-0100"), "5550100")
        XCTAssertNil(ContactSnapshot.cleanedPhone("ext"))
    }

    func testTheModelsWaysOfSayingHow() {
        XCTAssertEqual(CallVia(spoken: "FaceTime"), .faceTime)
        XCTAssertEqual(CallVia(spoken: "facetime_audio"), .faceTimeAudio)
        XCTAssertEqual(CallVia(spoken: "phone"), .phone)
        XCTAssertNil(CallVia(spoken: "carrier pigeon"))
    }
}

// MARK: - The call and the record

@MainActor
private final class FakePlacement: CallPlacing {
    var accepts = true
    private(set) var placed: [CallRoute] = []
    func place(_ route: CallRoute) async -> Bool {
        placed.append(route)
        return accepts
    }
}

@MainActor
private final class FakeCallObserver: CallObserving {
    var onChange: ((ObservedCall) -> Void)?
    func send(_ call: ObservedCall) { onChange?(call) }
}

@MainActor
final class ExpertCallTests: XCTestCase {

    private var tempRoot: URL!
    private var service: FieldSessionService!
    private var coordinator: EscalationCoordinator!
    private var placement: FakePlacement!
    private var observer: FakeCallObserver!
    private var clock = Fixture.friday(15)
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private let sam = Fixture.expert("sam", "Sam Okafor", tags: ["furnace"])
    private let priya = Fixture.expert("priya", "Priya Raman", phone: "+1 555 0102", tags: ["furnace"])

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpertCallTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = FieldSessionService(sessionsRoot: tempRoot)

        placement = FakePlacement()
        observer = FakeCallObserver()
        coordinator = EscalationCoordinator.shared
        coordinator.reset()
        coordinator.notifier = StubExpertNotifier()
        coordinator.bridge = PendingExpertBridge()
        coordinator.sessionService = service
        coordinator.placement = placement
        coordinator.now = { [unowned self] in self.clock }
        let shared = EscalationCoordinator.shared
        let monitor = ExpertCallMonitor(record: { [weak shared] in shared?.recordSeen($0) },
                                        audio: ExpertCallAudioCoordinator())
        monitor.makeObserver = { [unowned self] in self.observer }
        monitor.now = { [unowned self] in self.clock }
        coordinator.callMonitor = monitor
        list([])
    }

    override func tearDown() {
        coordinator.reset()
        coordinator.notifier = StubExpertNotifier()
        coordinator.bridge = PendingExpertBridge()
        coordinator.sessionService = .shared
        coordinator.expertList = .shared
        coordinator.placement = SystemCallPlacement()
        coordinator.now = Date.init
        let shared = EscalationCoordinator.shared
        coordinator.callMonitor = ExpertCallMonitor(record: { [weak shared] in shared?.recordSeen($0) })
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func list(_ experts: [EscalationContact], last: String? = nil) {
        let store = ExpertListStore(defaults: Fixture.isolatedDefaults(), profileList: { nil })
        store.setDeviceOwnerExperts(experts)
        store.lastCalledExpertId = last
        coordinator.expertList = store
    }

    // MARK: No experts listed: today's behaviour

    func testWithNoExpertsARequestPagesThePoolAsBefore() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        XCTAssertFalse(coordinator.hasNamedExperts)
        let reply = try await EscalateToExpertTool().execute(args: ["action": "request", "reason": "Readings disagree",
                                                                    "specialty": "furnace"])
        XCTAssertTrue(reply.contains("the expert pool has been notified"), reply)
        XCTAssertEqual(coordinator.state, .awaitingExpert(reason: "Readings disagree"))
        XCTAssertEqual(service.activeSession?.escalations.count, 1)
        XCTAssertNil(service.activeSession?.escalations.first?.expert)
        XCTAssertTrue(placement.placed.isEmpty)
    }

    func testWithNoExpertsACallPointsElsewhereAndCallsNobody() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let reply = try await EscalateToExpertTool().execute(args: ["action": "call", "expert_name": "Sam"])
        XCTAssertTrue(reply.contains("No experts are listed"), reply)
        XCTAssertTrue(placement.placed.isEmpty)
        XCTAssertEqual(service.activeSession?.escalations.count, 0)
    }

    // MARK: Experts listed

    func testARequestOffersOneAndCallsNobody() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam, priya])
        let reply = try await EscalateToExpertTool().execute(args: ["action": "request", "specialty": "furnace",
                                                                    "reason": "pressure switch keeps tripping"])
        XCTAssertTrue(reply.hasPrefix("Two furnace experts. Sam is on call. Call Sam?"), reply)
        XCTAssertTrue(placement.placed.isEmpty)
        XCTAssertEqual(service.activeSession?.escalations.count, 0, "an offer is a question, not an escalation")
        XCTAssertEqual(coordinator.lastPickOrder.map(\.id), ["sam", "priya"])
    }

    func testByNameSkipsThePicker() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        // The rota would offer Priya; by name calls Sam all the same, and the picker never runs.
        list([sam, priya], last: "sam")
        let reply = try await EscalateToExpertTool().execute(args: ["action": "call", "expert_name": "Sam"])
        XCTAssertEqual(reply, "Calling Sam. Your phone will ask you to tap Call.")
        XCTAssertFalse(reply.lowercased().contains("connected"))
        XCTAssertEqual(placement.placed.map(\.url.absoluteString), ["tel:+15550100"])
        XCTAssertTrue(coordinator.lastPickOrder.isEmpty, "by name never consults the picker")

        let escalation = try XCTUnwrap(service.activeSession?.escalations.last)
        XCTAssertEqual(escalation.expert, ExpertSnapshot(id: "sam", name: "Sam Okafor", kind: .staff))
        XCTAssertEqual(escalation.callVia, "phone")
        XCTAssertEqual(coordinator.expertList.lastCalledExpertId, "sam", "the rota moves on")
    }

    func testACallWithoutANameCallsTheOffer() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam, priya], last: "sam")
        _ = try await EscalateToExpertTool().execute(args: ["action": "call", "specialty": "furnace", "via": "facetime"])
        XCTAssertEqual(placement.placed.map(\.url.absoluteString), ["facetime:+15550102"])
        XCTAssertEqual(service.activeSession?.escalations.last?.expert?.id, "priya")
    }

    func testAnAmbiguousOrUnknownNameCallsNobody() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam, Fixture.expert("sam2", "Sam Reyes", phone: "+15550104")])
        let ambiguous = try await EscalateToExpertTool().execute(args: ["action": "call", "expert_name": "Sam"])
        XCTAssertTrue(ambiguous.contains("Sam Okafor") && ambiguous.contains("Sam Reyes"), ambiguous)
        let unknown = try await EscalateToExpertTool().execute(args: ["action": "call", "expert_name": "Jordan"])
        XCTAssertTrue(unknown.contains("Nobody called 'Jordan'"), unknown)
        XCTAssertTrue(placement.placed.isEmpty)
    }

    func testARefusedPlacementRecordsNothing() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam])
        placement.accepts = false
        let outcome = await coordinator.callExpert(sam, via: .phone, reason: "x")
        XCTAssertEqual(outcome, .refused("Your phone couldn't start the call to Sam."))
        XCTAssertEqual(service.activeSession?.escalations.count, 0)
        XCTAssertNil(coordinator.expertList.lastCalledExpertId)
    }

    func testTheEntitlementIsCheckedAtTheBoundary() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam])
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        let outcome = await coordinator.callExpert(sam, via: .phone, reason: "x")
        XCTAssertEqual(outcome, .refused("Field Assist isn't unlocked on this device."))
        XCTAssertTrue(placement.placed.isEmpty)
    }

    // MARK: The observed call

    func testTheRecordCarriesTheObservedCallTimes() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam, priya])
        _ = await coordinator.callExpert(sam, via: .phone, reason: "Called Sam")
        let id = UUID()
        clock = Fixture.friday(15, 1)
        observer.send(ObservedCall(id: UUID(), isOutgoing: false, hasConnected: false, hasEnded: false))
        XCTAssertNil(service.activeSession?.escalations.last?.callStartedAt, "an incoming call is not this one")
        observer.send(ObservedCall(id: id, isOutgoing: true, hasConnected: false, hasEnded: false))
        clock = Fixture.friday(15, 2)
        observer.send(ObservedCall(id: id, isOutgoing: true, hasConnected: true, hasEnded: false))
        clock = Fixture.friday(15, 9)
        observer.send(ObservedCall(id: id, isOutgoing: true, hasConnected: true, hasEnded: true))

        let escalation = try XCTUnwrap(service.activeSession?.escalations.last)
        XCTAssertEqual(escalation.callStartedAt, Fixture.friday(15, 1))
        XCTAssertEqual(escalation.callConnectedAt, Fixture.friday(15, 2))
        XCTAssertEqual(escalation.callEndedAt, Fixture.friday(15, 9))
        XCTAssertNil(coordinator.noAnswerOffer)
        XCTAssertFalse(coordinator.callMonitor.audio.isCallActive, "the voice loop is handed back")
    }

    func testAnUnansweredCallOffersTheNext() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        list([sam, priya])
        _ = coordinator.offerExpert(request: "furnace", job: .none)
        _ = await coordinator.callExpert(sam, via: .phone, reason: "Called Sam")
        let id = UUID()
        observer.send(ObservedCall(id: id, isOutgoing: true, hasConnected: false, hasEnded: false))
        XCTAssertTrue(coordinator.callMonitor.audio.isCallActive, "the voice loop pauses for the call")
        observer.send(ObservedCall(id: id, isOutgoing: true, hasConnected: false, hasEnded: true))
        XCTAssertEqual(coordinator.noAnswerOffer, "Sam didn't answer. Try Priya?")
        XCTAssertNil(service.activeSession?.escalations.last?.callConnectedAt)
        XCTAssertNotNil(service.activeSession?.escalations.last?.callEndedAt)
        XCTAssertFalse(coordinator.callMonitor.audio.isCallActive)

        // A yes calls Priya with no name passed.
        _ = try await EscalateToExpertTool().execute(args: ["action": "call"])
        XCTAssertEqual(placement.placed.last?.url.absoluteString, "tel:+15550102")
    }

    func testACallLongAfterThePlacementIsNotThisOne() {
        var watch = ExpertCallWatch(expertId: "sam", placedAt: Fixture.friday(15))
        XCTAssertEqual(watch.observe(ObservedCall(id: UUID(), isOutgoing: true, hasConnected: false, hasEnded: false),
                                     at: Fixture.friday(15, 5)), [])
        XCTAssertTrue(watch.isFinished(at: Fixture.friday(15, 5)))
    }

    // MARK: The gate

    func testCallingByNamePassesTheGate() {
        XCTAssertTrue(EscalateToExpertTool.pagesAnExpert(tool: "escalate_to_expert", args: ["action": "call"]))
        XCTAssertNil(EscalateToExpertTool.refusal(said: "call Sam", previousReply: nil, expertName: "Sam"))
        XCTAssertNil(EscalateToExpertTool.refusal(said: "FaceTime Sam Okafor", previousReply: nil, expertName: "Sam Okafor"))
        XCTAssertNil(EscalateToExpertTool.refusal(said: "yes", previousReply: "Two furnace experts. Sam is on call. Call Sam?",
                                                  expertName: "Sam"))
        XCTAssertNil(EscalateToExpertTool.refusal(said: "yeah", previousReply: "Sam didn't answer. Try Priya?",
                                                  expertName: "Priya"))
        XCTAssertEqual(EscalateToExpertTool.refusal(said: "don't call Sam", previousReply: nil, expertName: "Sam"),
                       EscalateToExpertTool.notRequested)
        XCTAssertEqual(EscalateToExpertTool.refusal(said: "what's the static pressure", previousReply: nil, expertName: "Sam"),
                       EscalateToExpertTool.notRequested)
        XCTAssertEqual(EscalateToExpertTool.refusal(said: "yes", previousReply: "Sam said the hose was clear.",
                                                    expertName: "Sam"),
                       EscalateToExpertTool.notRequested, "a reply that only mentions Sam offers nothing")
    }

    func testTheApprovalNamesWhoIsCalled() {
        XCTAssertEqual(PromptInjectionPolicy.actionSummary(toolName: "escalate_to_expert",
                                                           args: ["action": "call", "expert_name": "Sam"]), "Call Sam")
        XCTAssertEqual(PromptInjectionPolicy.actionSummary(toolName: "escalate_to_expert",
                                                           args: ["action": "call", "expert_name": "Sam", "via": "facetime"]),
                       "Call Sam by FaceTime")
    }

    // MARK: Backward compatibility

    func testAnEscalationSavedBeforeExpertsDecodes() throws {
        let old = #"{"timestamp":"2026-10-01T09:30:00Z","reason":"Readings contradict the flowchart","resolvedAt":"2026-10-01T09:45:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let escalation = try decoder.decode(FieldSession.Escalation.self, from: Data(old.utf8))
        XCTAssertEqual(escalation.reason, "Readings contradict the flowchart")
        XCTAssertNotNil(escalation.resolvedAt)
        XCTAssertNil(escalation.expert)
        XCTAssertNil(escalation.callVia)
        XCTAssertNil(escalation.callStartedAt)
        XCTAssertNil(escalation.callConnectedAt)
        XCTAssertNil(escalation.callEndedAt)
    }

    func testASessionSavedBeforeExpertsDecodes() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        service.recordEscalation(reason: "Need a human")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(service.activeSession)) as? [String: Any])
        // Strip every key this plan added, as a file written by an earlier build would lack them.
        let escalations = try XCTUnwrap(object["escalations"] as? [[String: Any]])
        object["escalations"] = escalations.map { entry in
            entry.filter { !["expert", "callVia", "callStartedAt", "callConnectedAt", "callEndedAt"].contains($0.key) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FieldSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.escalations.map(\.reason), ["Need a human"])
        XCTAssertNil(decoded.escalations.first?.expert)
    }

    func testTheRecordKeepsNoRateOrNumber() throws {
        let contracted = Fixture.expert("c", "Dana Ito", phone: "+15550105", kind: .contracted, rate: Fixture.rate)
        let encoder = JSONEncoder()
        let text = String(data: try encoder.encode(contracted.snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("90"), text)
        XCTAssertFalse(text.contains("5550105"), text)
        XCTAssertEqual(Set(Mirror(reflecting: contracted.snapshot).children.compactMap(\.label)), ["id", "name", "kind"])
    }
}
