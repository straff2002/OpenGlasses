import Foundation

/// Plan ND — what a renewal does to one starting value, given what the person has done with it.
///
/// Before ND a renewal wrote only keys the profile had never written on this phone, so a default the
/// company changed in the portal never reached a phone that already had the old one. The rule now:
/// **a default the person never touched follows the company; one they chose stays theirs.** "Never
/// touched" is judged against the value the profile last wrote here, not against the app's own
/// default — a person who picked the app default on purpose has still chosen.
///
/// Owned values and ceilings never come here: they are clamped on read, so the person's own value
/// underneath is untouched whatever the profile says.
enum StartingValueFollow {

    enum Decision: Equatable, Sendable {
        /// Write the company's value; from now on it is the value the profile last wrote.
        case write(ProfileValue)
        /// The stored value already is the company's: record it as written, write nothing.
        case adopt(ProfileValue)
        /// The person chose another value; it stays, and the managed page offers the company's.
        case keepPersonsChoice
        /// Nothing changed.
        case nothing
    }

    /// - Parameters:
    ///   - profileValue: the starting value the renewed profile carries.
    ///   - lastWritten: what the profile last wrote for this key on this phone, if known.
    ///   - wroteBefore: whether the profile has ever written this key here.
    ///   - stored: what is stored for the key now (nil: nothing stored).
    static func decide(profileValue: ProfileValue, lastWritten: ProfileValue?, wroteBefore: Bool,
                       stored: ProfileValue?) -> Decision {
        guard wroteBefore else {
            // A key the profile sets for the first time on a phone already enrolled.
            guard let stored else { return .write(profileValue) }
            return stored == profileValue ? .adopt(profileValue) : .keepPersonsChoice
        }
        if lastWritten == profileValue {
            return .nothing
        }
        if stored == profileValue {
            return .adopt(profileValue)
        }
        // Unknown last value (a record migrated without it): the person's, to be safe.
        guard let lastWritten, stored == lastWritten else { return .keepPersonsChoice }
        return .write(profileValue)
    }

    /// The values the profile last wrote, for a record written before ND kept them: each key the
    /// profile wrote is taken to hold the value the profile in force carries for it. Where the
    /// person's stored value differs from that, `decide` then keeps the person's — the safe reading.
    static func migratedLastWritten(wroteKeys: [String],
                                    profileInForce: [SettingKey: ProfileValue]) -> [String: ProfileValue] {
        var out: [String: ProfileValue] = [:]
        for name in wroteKeys {
            guard let key = SettingKey(rawValue: name), let value = profileInForce[key] else { continue }
            out[name] = value
        }
        return out
    }

    /// One starting value the person has set differently from the company's default, for the managed
    /// page's "You chose … The company default is now …" row.
    struct KeptChoice: Equatable, Sendable, Identifiable {
        let key: SettingKey
        let personsValue: ProfileValue
        let companyValue: ProfileValue
        var id: String { key.rawValue }
    }

    /// The starting values whose stored value is the person's own and differs from the company's.
    /// A key with nothing stored is not listed: it reads the app's default, and there is no choice of
    /// the person's to name.
    static func keptChoices(companyValues: [SettingKey: ProfileValue],
                            stored: (SettingKey) -> ProfileValue?) -> [KeptChoice] {
        companyValues.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { key in
            guard let company = companyValues[key], let mine = stored(key), mine != company else { return nil }
            return KeptChoice(key: key, personsValue: mine, companyValue: company)
        }
    }
}
