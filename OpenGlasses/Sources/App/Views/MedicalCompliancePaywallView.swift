import SwiftUI
import StoreKit

/// Paywall for Medical Compliance subscription.
/// Shows subscription benefits, pricing, and purchase options.
/// If already subscribed, passes through to HIPAASettingsView.
struct MedicalCompliancePaywallView: View {
    @ObservedObject var storeKit = StoreKitService.shared
    @ObservedObject var hipaaService: HIPAAComplianceService
    @ObservedObject var exportService: MedicalExportService
    @State private var selectedProduct: Product?
    @State private var showRestoreAlert = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroGlyph: CGFloat = 56
    @Environment(\.appAccent) private var accent

    var body: some View {
        if storeKit.canAccessMedicalCompliance {
            HIPAASettingsView(hipaaService: hipaaService, exportService: exportService)
        } else {
            paywallContent
        }
    }

    private var paywallContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero
                VStack(spacing: 12) {
                    Image(systemName: "cross.case.fill")
                        .font(.system(size: heroGlyph))
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .padding(.top, 20)

                    Text("Medical Compliance")
                        .font(.title.bold())

                    Text("Professional-grade safeguards for clinical recordings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Features
                OGCard {
                    featureRow(icon: "lock.doc.fill", title: "Encryption at Rest",
                               detail: "All recordings and transcripts encrypted with NSFileProtectionComplete")
                    OGDivider()
                    featureRow(icon: "faceid", title: "Biometric App Lock",
                               detail: "Face ID / Touch ID required every time the app opens")
                    OGDivider()
                    featureRow(icon: "list.clipboard.fill", title: "Audit Logging",
                               detail: "Every data access event logged with timestamps — exportable")
                    OGDivider()
                    featureRow(icon: "arrow.up.doc.fill", title: "Medical Export",
                               detail: "FHIR R4, HL7, PDF export to Epic, Cerner, and more")
                    OGDivider()
                    featureRow(icon: "calendar.badge.clock", title: "Data Retention",
                               detail: "Configurable auto-purge with secure deletion")
                    OGDivider()
                    featureRow(icon: "icloud.slash.fill", title: "Prevent Data Leakage",
                               detail: "Cloud tools disabled, iCloud backup excluded")
                    OGDivider()
                    featureRow(icon: "globe", title: "International Frameworks",
                               detail: "HIPAA, GDPR, AU Privacy Act, NZ HIPC, PIPEDA, UK DPA")
                }
                .padding(.horizontal, 24)

                // Subscription Options
                VStack(spacing: 12) {
                    if storeKit.products.isEmpty {
                        ProgressView("Loading plans...")
                            .padding()
                    } else {
                        ForEach(storeKit.products, id: \.id) { product in
                            subscriptionCard(product: product)
                        }
                    }
                }
                .padding(.horizontal, 20)

                // Purchase Button
                if let product = selectedProduct ?? storeKit.annualProduct ?? storeKit.monthlyProduct {
                    Button {
                        Task { await storeKit.purchase(product) }
                    } label: {
                        HStack {
                            if storeKit.isPurchasing {
                                ProgressView()
                                    .tint(OGTheme.onAccentLabel(accent))
                            }
                            Text("Subscribe")
                        }
                    }
                    .buttonStyle(.ogProminent)
                    .disabled(storeKit.isPurchasing)
                    .padding(.horizontal, 24)
                }

                if let error = storeKit.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(OGTheme.errorLabel)
                        .padding(.horizontal)
                }

                // Restore / Legal
                VStack(spacing: 8) {
                    Button("Restore Purchases") {
                        Task {
                            await storeKit.restorePurchases()
                            if !storeKit.isMedicalComplianceActive {
                                showRestoreAlert = true
                            }
                        }
                    }
                    .font(.subheadline)

                    Text("Subscription renews automatically. Cancel anytime in Settings → Apple ID → Subscriptions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 24)
            }
        }
        .background(OGTheme.canvas.ignoresSafeArea())
        .navigationTitle("Medical Compliance")
        .navigationBarTitleDisplayMode(.inline)
        .alert("No Subscription Found", isPresented: $showRestoreAlert) {
            Button("OK") {}
        } message: {
            Text("No active Medical Compliance subscription was found for this Apple ID.")
        }
    }

    // MARK: - Subviews

    private func featureRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        OGRow(title, icon: icon, subtitle: detail, showsChevron: false) { EmptyView() }
    }

    private func subscriptionCard(product: Product) -> some View {
        let isSelected = (selectedProduct?.id ?? storeKit.annualProduct?.id) == product.id
        let isAnnual = product.id == StoreKitService.medicalAnnualId

        return Button {
            selectedProduct = product
        } label: {
            OGCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(isAnnual ? "Annual" : "Monthly")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if isAnnual {
                                OGBadge(text: "Best Value", prominent: true)
                            }
                        }
                        Text(product.displayPrice + (isAnnual ? "/year" : "/month"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if isAnnual, let monthly = storeKit.monthlyProduct {
                            let monthlyAnnualized = monthly.price * 12
                            let savings = monthlyAnnualized - product.price
                            if savings > 0 {
                                Text("Save \(savings.formatted(.currency(code: product.priceFormatStyle.currencyCode)))/year")
                                    .font(.caption)
                                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? OGTheme.tintedAccentLabel(accent) : .secondary)
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                .padding()
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isSelected ? accent : OGTheme.hairline, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
