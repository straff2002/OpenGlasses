import StoreKit
import SwiftUI

// Plan NH — the Standard subscription: its paywall, opened from the exhausted line, the Home line
// and the notification; and Settings › Subscription, with the current plan, today's minutes and the
// plans above. Laid out like the My Manuals paywall.

/// What the Standard paywall says it includes.
enum StandardPaywallCopy {
    static var headline: String { String(localized: "No daily limit") }
    static var summary: String {
        String(localized: "Standard removes the 15-minute daily limit on the assistant, on every model you use. Without a subscription, 15 minutes a day are free and come back at midnight. My Manuals, Field Assist and Medical Compliance include no daily limit too.")
    }
    static var renewal: String {
        String(localized: "Subscriptions renew automatically at the displayed price unless cancelled in your Apple Account subscription settings. Any introductory offer applies only to eligible subscribers.")
    }
    static var noneFound: String {
        String(localized: "No active subscription was found for this App Store account.")
    }
}

/// The plan rows: each product's price and period from StoreKit, its offer line where the account
/// is eligible, then the renewal terms and the Privacy Policy and Terms of Use links.
struct StandardPlanButtons: View {
    @ObservedObject var store: StoreKitService
    var onPurchased: (() -> Void)? = nil

    var body: some View {
        if store.isLoadingProducts { ProgressView("Loading in-app plans…") }
        ForEach(store.standardProducts, id: \.id) { product in
            Button {
                Task {
                    await store.purchase(product)
                    if store.standardSubscription != nil { onPurchased?() }
                }
            } label: {
                Text(product.id == StoreKitService.standardAnnualId
                     ? "Subscribe annually · \(Self.pricePerPeriod(product))"
                     : "Subscribe monthly · \(Self.pricePerPeriod(product))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isPurchasing || store.isRestoring)
            if let terms = store.offerTerms(for: product) {
                Text(terms.line())
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        if let error = store.standardCatalogError { Text(error).font(.caption).foregroundStyle(.secondary) }
        if !store.isLoadingProducts, store.standardProducts.count < StoreKitService.standardCatalogProductIds.count {
            Button("Retry loading in-app plans") { Task { await store.loadProducts() } }
        }
        Text(StandardPaywallCopy.renewal).font(.footnote)
        Link("Privacy Policy", destination: PublicSite.privacy)
        Link("Terms of Use", destination: PublicSite.termsOfUse)
    }

    /// "$3.99/month", from the product's own price and period.
    static func pricePerPeriod(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        let unit: SubscriptionOfferTerms.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .month
        }
        return SubscriptionOfferTerms.pricePerPeriod(product.displayPrice, .init(value: period.value, unit: unit))
    }
}

/// The paywall's content: what Standard includes, the plans, Restore.
struct StandardPaywallSection: View {
    @ObservedObject var store: StoreKitService
    var onAccess: (() -> Void)? = nil
    @State private var restoreNotice: String?

    var body: some View {
        Section {
            Label(StandardPaywallCopy.headline, systemImage: "infinity")
                .font(.headline)
            Text(StandardPaywallCopy.summary)
            StandardPlanButtons(store: store) { onAccess?() }
            Button("Restore purchases") {
                Task {
                    await store.restorePurchases()
                    AllowanceService.shared.refresh()
                    if store.standardSubscription != nil { onAccess?() }
                    restoreNotice = store.purchaseError
                        ?? (store.hasActivePaidPlan ? store.restoreMessage : StandardPaywallCopy.noneFound)
                }
            }
            .disabled(store.isRestoring)
            if let notice = restoreNotice ?? store.purchaseError { Text(notice).font(.caption) }
        }
    }
}

/// The subscription sheet: the paywall with a Close.
struct StandardSubscriptionSheet: View {
    @ObservedObject var store: StoreKitService = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                StandardPaywallSection(store: store) { dismiss() }
            }
            .navigationTitle("Standard")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { if store.standardProducts.isEmpty { await store.loadProducts() } }
        }
    }
}

/// Settings › Subscription: the current plan, today's minutes, and the plans above it.
struct SubscriptionSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = StoreKitService.shared
    @ObservedObject private var allowance = AllowanceService.shared

    var body: some View {
        Form {
            Section("Your plan") {
                LabeledContent("Plan", value: currentPlan)
                if allowance.isExempt {
                    Text(exemptNote).font(.footnote).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Used today",
                                   value: String(localized: "\(allowance.usedTodaySeconds / 60) of 15 min"))
                    if let status = allowance.homeStatus {
                        Text(status.text)
                            .font(.footnote)
                            .foregroundStyle(status.isLow ? OGTheme.warnLabel : Color.secondary)
                    }
                }
                if store.standardSubscription != nil {
                    Button("Manage subscription") { Task { await store.showManageSubscription() } }
                }
            }
            if !store.hasActivePaidPlan {
                StandardPaywallSection(store: store)
            }
            Section {
                NavigationLink {
                    SettingsCategoryScreen(appState: appState, id: .myManuals)
                } label: {
                    SettingsLinkLabel(.myManuals)
                }
                NavigationLink {
                    SettingsCategoryScreen(appState: appState, id: .fieldAssist)
                } label: {
                    SettingsLinkLabel(.fieldAssist)
                }
            } header: {
                Text("Plans above Standard")
            } footer: {
                Text("Each includes no daily limit.")
            }
        }
        .navigationTitle("Subscription")
        .onAppear { allowance.refresh() }
        .task { if store.standardProducts.isEmpty { await store.loadProducts() } }
    }

    private var currentPlan: String {
        let fieldAssist = FieldAssistEntitlement.shared.decision()
        if fieldAssist.isGranted, let tier = fieldAssist.tier, tier >= .solo {
            return String(localized: "Field Assist · \(tier.label)")
        }
        if store.myManualsSubscription != nil { return String(localized: "My Manuals") }
        if store.isMedicalComplianceActive { return String(localized: "Medical Compliance") }
        if let standard = store.standardSubscription {
            return String(localized: "Standard · \(standard.planName)")
        }
        if let organisation = PolicyEnvelope.organizationName {
            return String(localized: "Provided by \(organisation)")
        }
        return String(localized: "Free · 15 minutes a day")
    }

    private var exemptNote: String {
        let reasons = AllowanceExemption.reasons(allowance.exemptionInputs(utterance: nil))
        if reasons.contains(.paidTier) { return String(localized: "Your plan includes no daily limit.") }
        if reasons.contains(.accessibility) {
            return String(localized: "No daily limit while VoiceOver, Accessibility or an assistive mode is on.")
        }
        if reasons.contains(.unmeteredBuild) {
            return String(localized: "No daily limit on this test build. The Developer panel can meter it as a store build.")
        }
        return String(localized: "No daily limit right now.")
    }
}

/// The Home card's line: "n min left today", amber below three minutes, a tap away from the sheet.
/// Hidden for an exempt user and before any turn has run today.
struct AllowanceHomeLine: View {
    @ObservedObject var allowance: AllowanceService
    let open: () -> Void

    var body: some View {
        if let status = allowance.homeStatus {
            Button(action: open) {
                Text(status.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.isLow ? OGTheme.warnLabel : OGTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the subscription plans")
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}

extension StoreKitService {
    /// Any store subscription that includes no daily limit (Plan NH decision 6). Licences and
    /// organisation profiles are read by `AllowanceExemption`, not here.
    var hasActivePaidPlan: Bool {
        standardSubscription != nil || myManualsSubscription != nil || isFieldAssistPurchased
            || isMedicalComplianceActive
    }
}
