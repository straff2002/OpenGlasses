import Foundation

/// Ephemeral: never encode this in the ledger. Delivery/publishing is a P1 responsibility.
public struct IssuedCode {
    public let code: String
    public let record: IssuanceRecord
    public let payload: IssuedLicensePayload
    public func profileDocument(profileId: String, keyID: String, signer: ByteSigner) throws -> String {
        try IssuanceWire.minimalProfile(id: profileId, licensee: payload.licensee,
                                       issued: payload.issued, code: code, keyID: keyID, signer: signer)
    }
}
public enum SalesError: Error, Equatable {
    case duplicateId, invalidRenewal, invalidOrder, invalidPayment, confirmationRequired, unknownInvoice, invalidCredit
}
/// Single-writer value core. The terminal holds a process lock through read, sign, append and fsync.
/// A service must provide the same transaction boundary before returning any artefact.
public struct SalesBook {
    public internal(set) var ledger: Ledger
    public init(ledger: Ledger = Ledger()) throws { try ledger.verify(); self.ledger = ledger }
    func mint(_ payload: IssuedLicensePayload, id: String, grant: PartnerGrant, operatorId: String,
                      replaces: String?, orderId: String?, phase: IssuanceRecord.Phase, signer: ByteSigner) throws -> IssuedCode {
        guard !ledger.issuances.contains(where: { $0.issuanceId == id }) else { throw SalesError.duplicateId }
        let code = try IssuanceWire.code(payload, signer: signer)
        let record = try IssuanceRecord(id: id, partner: grant, operatorId: operatorId, payload: payload,
                                        code: code, replaces: replaces, orderId: orderId, phase: phase)
        return IssuedCode(code: code, record: record, payload: payload)
    }
    /// EI's manual policy path, including exact like-for-like lost-code reissues.
    @discardableResult public mutating func issue(id: String, request: IssuanceRequest, grant: PartnerGrant,
                                                  catalog: VerifiedPackCatalog, operatorId: String, now: Date,
                                                  signer: ByteSigner) throws -> IssuedCode {
        let payload = try IssuancePolicy.validate(request, grant: grant, ledger: ledger, catalog: catalog, now: now).get()
        let old = ledger.issuances.first { $0.issuanceId == request.replaces }
        // Sales must flow through payment; a manual replacement cannot extend a provisional term.
        let result = try mint(payload, id: id, grant: grant, operatorId: operatorId, replaces: request.replaces,
                              orderId: old?.orderId, phase: old?.phase ?? .manual, signer: signer)
        try ledger.append(.issuance(result.record)); return result
    }
    /// New sales get 35 days, renewals get no provisional. A pilot raises no invoice.
    @discardableResult public mutating func order(id: String, request: IssuanceRequest, grant: PartnerGrant,
                                                  catalog: VerifiedPackCatalog, profileId: String, bankDetails: String,
                                                  renewalOf: String? = nil, operatorId: String, now: Date,
                                                  signer: ByteSigner) throws -> IssuedCode? {
        let (order, invoice, issued) = try prepareOrder(id: id, request: request, grant: grant, catalog: catalog, profileId: profileId,
                                                        bankDetails: bankDetails, renewalOf: renewalOf, customerId: nil,
                                                        operatorId: operatorId, now: now, signer: signer)
        try ledger.append(.sale(order, invoice, issued?.record)); return issued
    }
    /// Validates and builds an order, its invoice and its first code without recording anything.
    func prepareOrder(id: String, request: IssuanceRequest, grant: PartnerGrant, catalog: VerifiedPackCatalog,
                      profileId: String, bankDetails: String, renewalOf: String?, customerId: String?,
                      operatorId: String, now: Date, signer: ByteSigner) throws -> (Order, Invoice?, IssuedCode?) {
        guard !id.isEmpty, !profileId.isEmpty, !operatorId.isEmpty,
              !ledger.orders.contains(where: { $0.id == id }), request.replaces == nil,
              request.profile != nil, let days = request.termDays, request.expiry == nil else {
            throw SalesError.invalidOrder
        }
        _ = try IssuancePolicy.validate(request, grant: grant, ledger: ledger, catalog: catalog, now: now).get()
        var start = now
        if let renewalOf {
            guard request.plan != "pilot", let prior = ledger.orders.first(where: { $0.id == renewalOf }),
                  prior.partnerId == grant.partnerId, prior.request.licensee == request.licensee,
                  prior.profileId == profileId, prior.request.profile == request.profile, prior.customerId == customerId,
                  ledger.invoices.first(where: { $0.orderId == prior.id }).map(ledger.isPaid) == true,
                  now <= prior.fullExpiry.addingTimeInterval(-35 * IssuancePolicy.day),
                  !ledger.orders.contains(where: { $0.renewalOf == prior.id }) else { throw SalesError.invalidRenewal }
            start = prior.fullExpiry
        }
        let fullExpiry = start.addingTimeInterval(Double(days) * IssuancePolicy.day)
        let order = Order(id: id, partnerId: grant.partnerId, grantVersion: grant.version, issuedAt: now,
                          grant: grant, request: request, profileId: profileId, fullExpiry: fullExpiry, renewalOf: renewalOf,
                          customerId: customerId, increaseOf: nil)
        var invoice: Invoice?
        if request.plan != "pilot" {
            // Short terms would let the provisional outlive the paid term.
            guard days >= 35, !bankDetails.isEmpty else { throw SalesError.invalidOrder }
            guard !grant.prices.currency.isEmpty, !grant.prices.taxTreatment.isEmpty,
                  let unit = grant.prices.perSeatByTermDays[days], unit > 0 else { throw IssuanceRefusal.missingPrice }
            let (total, overflow) = unit.multipliedReportingOverflow(by: Int64(request.seats))
            guard !overflow else { throw IssuanceRefusal.invalidRequest }
            invoice = Invoice(number: Ledger.invoiceNumber(ledger.invoices.count + 1), orderId: id,
                              partnerId: grant.partnerId, issuedAt: now, dueAt: now.addingTimeInterval(30 * IssuancePolicy.day),
                              seats: request.seats, termDays: days, unitMinor: unit, totalMinor: total,
                              currency: grant.prices.currency, taxTreatment: grant.prices.taxTreatment, bankDetails: bankDetails,
                              coTermedDays: nil)
        }
        var issued: IssuedCode?
        if renewalOf == nil {
            let expiry = request.plan == "pilot" ? fullExpiry : now.addingTimeInterval(35 * IssuancePolicy.day)
            let payload = IssuedLicensePayload(licensee: request.licensee, issued: now, expires: expiry,
                                               tier: request.tier, plan: request.plan, seats: request.seats, reference: id,
                                               packs: request.packs.isEmpty ? nil : request.packs.sorted(), profile: request.profile,
                                               seatCheck: request.seatCheck == true ? true : nil)
            issued = try mint(payload, id: id + "/initial", grant: grant, operatorId: operatorId, replaces: nil,
                              orderId: id, phase: request.plan == "pilot" ? .pilot : .provisional, signer: signer)
        }
        return (order, invoice, issued)
    }
    /// Explicit vendor confirmation is required because a full code is irrevocable offline.
    @discardableResult public mutating func recordPayment(_ payment: Payment, confirmed: Bool, operatorId: String,
                                                          now: Date, signer: ByteSigner) throws -> IssuedCode? {
        guard confirmed else { throw SalesError.confirmationRequired }
        guard let invoice = ledger.invoices.first(where: { $0.number == payment.invoiceNumber }),
              let order = ledger.orders.first(where: { $0.id == invoice.orderId }) else { throw SalesError.unknownInvoice }
        guard !payment.id.isEmpty, !operatorId.isEmpty, !payment.bankReference.isEmpty,
              payment.amountMinor > 0, payment.receivedAt >= invoice.issuedAt, payment.receivedAt <= now,
              !ledger.payments.contains(where: { $0.id == payment.id }),
              !ledger.isPaid(invoice),
              ledger.creditsMinor(invoice) == 0 || payment.amountMinor <= ledger.balance(invoice) else { throw SalesError.invalidPayment }
        let (paid, overflow) = ledger.paymentsMinor(invoice).addingReportingOverflow(payment.amountMinor)
        guard !overflow else { throw SalesError.invalidPayment }
        var issued: IssuedCode?
        if paid >= invoice.totalMinor && ledger.creditsMinor(invoice) == 0 {
            // A late payment never moves the full expiry. Even a spent term is not extended.
            // A seat increase replaces the code it co-terms with, carrying its seats plus the increase.
            let base = order.increaseOf.flatMap { id in ledger.issuances.first { $0.issuanceId == id } }
            if order.increaseOf != nil {
                guard let base, let customer = order.customerId, ledger.currentIssuance(for: customer)?.issuanceId == base.issuanceId else {
                    throw SalesError.invalidOrder
                }
            }
            let (seats, overflow) = (base?.seats ?? 0).addingReportingOverflow(order.request.seats)
            guard !overflow else { throw SalesError.invalidOrder }
            let payload = IssuedLicensePayload(licensee: order.request.licensee, issued: now, expires: order.fullExpiry,
                                               tier: order.request.tier, plan: order.request.plan, seats: seats,
                                               reference: order.id, packs: order.request.packs.isEmpty ? nil : order.request.packs.sorted(),
                                               profile: order.request.profile,
                                               seatCheck: order.request.seatCheck == true ? true : nil)
            let previous = base ?? ledger.issuances.last { $0.orderId == order.id }
            issued = try mint(payload, id: order.id + "/full", grant: order.grant, operatorId: operatorId,
                              replaces: previous?.issuanceId, orderId: order.id, phase: .full, signer: signer)
        }
        try ledger.append(.payment(payment, issued?.record)); return issued
    }
    public mutating func credit(_ note: CreditNote, now: Date) throws {
        guard let invoice = ledger.invoices.first(where: { $0.number == note.invoiceNumber }) else { throw SalesError.unknownInvoice }
        guard !note.id.isEmpty, !note.reason.isEmpty, note.amountMinor > 0, note.amountMinor <= invoice.totalMinor - ledger.creditsMinor(invoice),
              note.issuedAt >= invoice.issuedAt, note.issuedAt <= now,
              !ledger.credits.contains(where: { $0.id == note.id }) else { throw SalesError.invalidCredit }
        try ledger.append(.credit(note))
    }
}
