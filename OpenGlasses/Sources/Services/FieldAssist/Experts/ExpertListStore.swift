import Foundation

/// Where the expert list lives on the phone (Plan KM P0): two sources, one list.
///
/// - **The organisation's experts.** A profile sets them with the profile-owned key
///   `organizationExperts`, and then only the profile does. With no profile the device owner is the
///   organisation (a sole operator has no office) and sets them here, rates and all, stored under
///   the same key, so the clamp-on-read rule (`PolicyEnvelope`) puts the profile's list over it
///   and removing the profile brings the owner's back.
/// - **The technician's own additions** (`PersonalExpert`): always staff, never a rate.
///
/// Plus the rota position: the id of the expert this phone called last.
///
/// The defaults are injectable so tests never touch the app's own preferences.
final class ExpertListStore: @unchecked Sendable {
    static let shared = ExpertListStore()

    static let organizationKey = SettingKey.organizationExperts.rawValue
    static let personalKey = "fieldAssistPersonalExperts"
    static let rotaKey = "fieldAssistExpertRotaLastCalled"
    static let maxPersonal = 50

    private let defaults: UserDefaults
    /// Reads the profile in force; injectable for tests. Returns the organisation's list when the
    /// profile sets one, `.some([])` when a profile is in force without one, nil when unmanaged.
    private let profileList: () -> [EscalationContact]?

    init(defaults: UserDefaults = .standard,
         profileList: @escaping () -> [EscalationContact]? = ExpertListStore.listFromProfile) {
        self.defaults = defaults
        self.profileList = profileList
    }

    // MARK: - The profile

    /// The profile's list, read through the envelope. A profile in force that sets no list gives an
    /// empty one: with a profile, only the profile sets the organisation's experts.
    static func listFromProfile() -> [EscalationContact]? {
        guard PolicyEnvelope.isManaged else { return nil }
        guard case .string(let text)? = PolicyEnvelope.current.owned[.organizationExperts],
              case .success(let list) = ExpertListCodec.decode(text) else { return [] }
        return list
    }

    /// Whether the organisation's rows are the profile's, and so read-only here.
    var organizationListIsManaged: Bool { profileList() != nil }

    // MARK: - The organisation's list

    /// The organisation's experts: the profile's, or with no profile the device owner's.
    var organizationExperts: [EscalationContact] {
        if let managed = profileList() { return managed }
        return deviceOwnerExperts
    }

    /// The device owner's list, as stored, whether or not a profile is over it.
    var deviceOwnerExperts: [EscalationContact] {
        guard let text = defaults.string(forKey: Self.organizationKey),
              case .success(let list) = ExpertListCodec.decode(text) else { return [] }
        return list
    }

    /// Replace the device owner's list. Refused while a profile owns the organisation's experts,
    /// and refused for a list that would not decode back.
    @discardableResult
    func setDeviceOwnerExperts(_ list: [EscalationContact]) -> ExpertListProblem? {
        guard !organizationListIsManaged else { return ExpertListProblem("your organisation sets this list") }
        let text = ExpertListCodec.encode(list)
        if case .failure(let problem) = ExpertListCodec.decode(text) { return problem }
        defaults.set(text, forKey: Self.organizationKey)
        return nil
    }

    // MARK: - The technician's own

    var personalExperts: [PersonalExpert] {
        guard let data = defaults.data(forKey: Self.personalKey),
              let list = try? JSONDecoder().decode([PersonalExpert].self, from: data) else { return [] }
        return list
    }

    /// Replace the technician's own list. Each entry must stand as a contact (a name and a number
    /// or handle that can be called).
    @discardableResult
    func setPersonalExperts(_ list: [PersonalExpert]) -> ExpertListProblem? {
        if list.count > Self.maxPersonal { return ExpertListProblem("more than \(Self.maxPersonal) experts") }
        if let problem = list.lazy.compactMap(\.contact.problem).first { return ExpertListProblem(problem) }
        guard let data = try? JSONEncoder().encode(list) else { return ExpertListProblem("the list could not be saved") }
        defaults.set(data, forKey: Self.personalKey)
        return nil
    }

    // MARK: - One list

    /// The organisation's experts, then the technician's own, each marked with its source. A
    /// personal entry that rings the same number or handle as an organisation entry is left out:
    /// the organisation's entry is the one that counts.
    var entries: [ExpertListEntry] {
        Self.merged(organization: organizationExperts, personal: personalExperts)
    }

    var contacts: [EscalationContact] { entries.map(\.contact) }

    static func merged(organization: [EscalationContact], personal: [PersonalExpert]) -> [ExpertListEntry] {
        var rows = organization.map { ExpertListEntry(contact: $0, source: .organization) }
        var taken = Set(organization.flatMap(Self.ringKeys))
        var ids = Set(organization.map(\.id))
        for expert in personal {
            let contact = expert.contact
            let keys = Self.ringKeys(contact)
            guard ids.insert(contact.id).inserted, taken.isDisjoint(with: keys) else { continue }
            taken.formUnion(keys)
            rows.append(ExpertListEntry(contact: contact, source: .personal))
        }
        return rows
    }

    private static func ringKeys(_ contact: EscalationContact) -> [String] {
        [contact.phone.flatMap(CallRoute.cleanedNumber), contact.faceTimeHandle.flatMap(CallRoute.cleanedHandle)]
            .compactMap { $0 }
    }

    // MARK: - The rota

    var lastCalledExpertId: String? {
        get { defaults.string(forKey: Self.rotaKey) }
        set { defaults.set(newValue, forKey: Self.rotaKey) }
    }

    // MARK: - Erasure

    /// Remove the technician's own experts, the device owner's list and the rota position. A
    /// profile's list is the profile's, and goes when the profile does.
    func removeAll() {
        defaults.removeObject(forKey: Self.personalKey)
        defaults.removeObject(forKey: Self.organizationKey)
        defaults.removeObject(forKey: Self.rotaKey)
    }
}
