import Foundation

/// A Canadian province or territory, as Medical Compliance's Canada entry offers it (Plan NJ §8,
/// Decision 6).
enum CanadianJurisdiction: String, CaseIterable, Identifiable, Sendable {
    case britishColumbia = "BC"
    case alberta = "AB"
    case saskatchewan = "SK"
    case manitoba = "MB"
    case ontario = "ON"
    case quebec = "QC"
    case newBrunswick = "NB"
    case novaScotia = "NS"
    case princeEdwardIsland = "PE"
    case newfoundlandAndLabrador = "NL"
    case yukon = "YT"
    case northwestTerritories = "NT"
    case nunavut = "NU"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .britishColumbia: return String(localized: "British Columbia")
        case .alberta: return String(localized: "Alberta")
        case .saskatchewan: return String(localized: "Saskatchewan")
        case .manitoba: return String(localized: "Manitoba")
        case .ontario: return String(localized: "Ontario")
        case .quebec: return String(localized: "Quebec")
        case .newBrunswick: return String(localized: "New Brunswick")
        case .novaScotia: return String(localized: "Nova Scotia")
        case .princeEdwardIsland: return String(localized: "Prince Edward Island")
        case .newfoundlandAndLabrador: return String(localized: "Newfoundland and Labrador")
        case .yukon: return String(localized: "Yukon")
        case .northwestTerritories: return String(localized: "Northwest Territories")
        case .nunavut: return String(localized: "Nunavut")
        }
    }

    /// Where the Canada entry remembers the clinic's choice. A setting on this phone, not a fact
    /// about anyone.
    static let defaultsKey = "medicalComplianceCanadianJurisdiction"
}

/// Who a privacy breach of health information is reported to.
enum CanadianBreachRecipient: String, CaseIterable, Sendable {
    /// The person the information is about.
    case individual
    /// The province's or territory's own information and privacy commissioner (or review officer).
    case commissioner
    /// The Office of the Privacy Commissioner of Canada, under PIPEDA.
    case federalCommissioner
    case minister
    case ombudsman
    /// New Brunswick's Ombud.
    case ombud
    /// Quebec's Commission d'accès à l'information.
    case accessCommission
}

/// What a jurisdiction asks before a system handles health information.
enum CanadianPIADuty: String, Sendable {
    case none
    /// Alberta: a privacy impact assessment submitted to the Commissioner first.
    case submitToCommissioner
    /// Quebec: an assessment before health information leaves Quebec.
    case beforeLeavingProvince
}

/// The act that governs a private clinic's health information in each province and territory, and
/// what it asks of the clinic (Plan NJ §8, from a 2026-11-27 research report on Canadian
/// health-privacy law; not legal advice). Pure.
///
/// None of it is needed for a stock list that is inventory-only: a vaccine, lot, expiry and
/// quantity describe vials, not people. The duties say so where it is the case.
struct CanadianHealthAct: Equatable, Sendable {
    let jurisdiction: CanadianJurisdiction
    /// The act's name, in full.
    let act: String
    /// How it is usually shortened.
    let shortName: String
    /// What the act calls a supplier that handles the clinic's health information.
    let vendorTerm: String
    /// The agreement that supplier needs.
    let agreement: String
    /// Who a breach is reported to; empty where the act sets no mandatory notice.
    let breachRecipients: [CanadianBreachRecipient]
    /// The breach rule, said as the act says it.
    let breachNotice: String
    /// The act asks for a record of user activity on electronic health information.
    let userActivityLog: Bool
    let pia: CanadianPIADuty
    /// The federal act probably applies too (PEI is not on the substantially-similar list;
    /// Nunavut has no act of its own for a private clinic).
    let pipedaAlsoApplies: Bool

    /// "Not needed while the list is inventory-only", said wherever a duty is.
    static var notNeededWhileInventoryOnly: String {
        String(localized: "not needed while the stock list is inventory-only",
               comment: "Medical Compliance: a duty that applies only once patient data reaches the app.")
    }

    // MARK: - The table

    static func act(for jurisdiction: CanadianJurisdiction) -> CanadianHealthAct {
        switch jurisdiction {
        case .britishColumbia:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Information Protection Act"), shortName: "PIPA",
                         vendorTerm: String(localized: "service provider"),
                         agreement: String(localized: "a written service agreement"),
                         breachRecipients: [],
                         breachNotice: String(localized: "No mandatory breach notice for a private clinic."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .alberta:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Health Information Act"), shortName: "HIA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "an information manager agreement"),
                         breachRecipients: [.commissioner, .minister, .individual],
                         breachNotice: String(localized: "Report a breach to the Commissioner, the Minister and the individual."),
                         userActivityLog: false, pia: .submitToCommissioner, pipedaAlsoApplies: false)
        case .saskatchewan:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Health Information Protection Act"), shortName: "HIPA",
                         vendorTerm: String(localized: "information management service provider"),
                         agreement: String(localized: "a written agreement with the service provider"),
                         breachRecipients: [],
                         breachNotice: String(localized: "No statutory breach notice."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .manitoba:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Health Information Act"), shortName: "PHIA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "a written information manager agreement"),
                         breachRecipients: [.ombudsman, .individual],
                         breachNotice: String(localized: "Report a breach to the Ombudsman and the individual."),
                         userActivityLog: true, pia: .none, pipedaAlsoApplies: false)
        case .ontario:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Health Information Protection Act"), shortName: "PHIPA",
                         vendorTerm: String(localized: "agent or electronic service provider"),
                         agreement: String(localized: "an agreement under the act's electronic service provider rules"),
                         breachRecipients: [.individual, .commissioner],
                         breachNotice: String(localized: "Tell the individual, and the Information and Privacy Commissioner of Ontario in the cases the regulation sets out."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .quebec:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Act respecting health and social services information"), shortName: "R-22.1",
                         vendorTerm: String(localized: "service provider"),
                         agreement: String(localized: "a written mandate or service contract"),
                         breachRecipients: [.accessCommission, .minister],
                         breachNotice: String(localized: "Report a confidentiality incident to the Commission d'accès à l'information and the Minister."),
                         userActivityLog: false, pia: .beforeLeavingProvince, pipedaAlsoApplies: false)
        case .newBrunswick:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Health Information Privacy and Access Act"), shortName: "PHIPAA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "a written information manager agreement"),
                         breachRecipients: [.ombud],
                         breachNotice: String(localized: "Report a breach to the Ombud."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .novaScotia:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Health Information Act"), shortName: "PHIA",
                         vendorTerm: String(localized: "agent or information manager"),
                         agreement: String(localized: "a written agreement with the information manager"),
                         breachRecipients: [.individual, .commissioner],
                         breachNotice: String(localized: "Tell the individual, or the provincial Information and Privacy Commissioner if the individual is not told."),
                         userActivityLog: true, pia: .none, pipedaAlsoApplies: false)
        case .princeEdwardIsland:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Health Information Act"), shortName: "HIA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "a written information manager agreement"),
                         breachRecipients: [.commissioner],
                         breachNotice: String(localized: "Report a breach to the Information and Privacy Commissioner."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: true)
        case .newfoundlandAndLabrador:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Health Information Act"), shortName: "PHIA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "a written information manager agreement"),
                         breachRecipients: [.commissioner],
                         breachNotice: String(localized: "Report a material breach to the Information and Privacy Commissioner."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .yukon:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Health Information Privacy and Management Act"), shortName: "HIPMA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "a written information manager agreement"),
                         breachRecipients: [.individual, .commissioner],
                         breachNotice: String(localized: "Report a breach as the act sets out, to the individual and the Information and Privacy Commissioner."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .northwestTerritories:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Health Information Act"), shortName: "HIA",
                         vendorTerm: String(localized: "information manager"),
                         agreement: String(localized: "a written information manager agreement"),
                         breachRecipients: [.individual, .commissioner],
                         breachNotice: String(localized: "Report a breach as the act sets out, to the individual and the Information and Privacy Commissioner."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: false)
        case .nunavut:
            return .init(jurisdiction: jurisdiction,
                         act: String(localized: "Personal Information Protection and Electronic Documents Act"), shortName: "PIPEDA",
                         vendorTerm: String(localized: "service provider"),
                         agreement: String(localized: "a contract that gives comparable protection"),
                         breachRecipients: [.federalCommissioner, .individual],
                         breachNotice: String(localized: "Report a breach with a real risk of significant harm to the Office of the Privacy Commissioner of Canada and the individual."),
                         userActivityLog: false, pia: .none, pipedaAlsoApplies: true)
        }
    }

    static var all: [CanadianHealthAct] { CanadianJurisdiction.allCases.map(act(for:)) }

    // MARK: - Duties

    /// "Health Information Act (HIA)".
    var title: String { "\(act) (\(shortName))" }

    /// The clinic's duties under the act, each saying plainly when an inventory-only stock list
    /// does not need it.
    var duties: [String] {
        let inventoryOnly = Self.notNeededWhileInventoryOnly
        var lines = [
            String(localized: "\(agreement.capitalisedFirst) with each \(vendorTerm) before any patient data reaches it: \(inventoryOnly).",
                   comment: "Medical Compliance › Canada: the supplier agreement duty."),
            breachNotice,
        ]
        switch pia {
        case .none: break
        case .submitToCommissioner:
            lines.append(String(localized: "A privacy impact assessment submitted to the Commissioner before a new system uses health information: \(inventoryOnly)."))
        case .beforeLeavingProvince:
            lines.append(String(localized: "A privacy impact assessment before health information leaves Quebec: \(inventoryOnly)."))
        }
        if userActivityLog {
            lines.append(String(localized: "A record of user activity on electronic health information: \(inventoryOnly)."))
        }
        if pipedaAlsoApplies {
            lines.append(String(localized: "PIPEDA probably applies too: keep a record of every breach for 24 months."))
        }
        return lines
    }
}

private extension String {
    /// "An information manager agreement" from "an information manager agreement".
    var capitalisedFirst: String { prefix(1).uppercased() + dropFirst() }
}
