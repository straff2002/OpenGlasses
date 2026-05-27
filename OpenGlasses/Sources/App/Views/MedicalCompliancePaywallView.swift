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
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
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
                VStack(alignment: .leading, spacing: 16) {
                    featureRow(icon: "lock.doc.fill", title: "Encryption at Rest",
                               detail: "All recordings and transcripts encrypted with NSFileProtectionComplete")
                    featureRow(icon: "faceid", title: "Biometric App Lock",
                               detail: "Face ID / Touch ID required every time the app opens")
                    featureRow(icon: "list.clipboard.fill", title: "Audit Logging",
                               detail: "Every data access event logged with timestamps — exportable")
                    featureRow(icon: "arrow.up.doc.fill", title: "Medical Export",
                               detail: "FHIR R4, HL7, PDF export to Epic, Cerner, and more")
                    featureRow(icon: "calendar.badge.clock", title: "Data Retention",
                               detail: "Configurable auto-purge with secure deletion")
                    featureRow(icon: "icloud.slash.fill", title: "Prevent Data Leakage",
                               detail: "Cloud tools disabled, iCloud backup excluded")
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
                                    .tint(.white)
                            }
                            Text("Subscribe")
                                .font(.headline)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                    }
                    .disabled(storeKit.isPurchasing)
                    .padding(.horizontal, 24)
                }

                if let error = storeKit.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .navigationTitle("Medical Compliance")
        .navigationBarTitleDisplayMode(.inline)
        .alert("No Subscription Found", isPresented: $showRestoreAlert) {
            Button("OK") {}
        } message: {
            Text("No active Medical Compliance subscription was found for this Apple ID.")
        }
    }

    // MARK: - Subviews

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subscriptionCard(product: Product) -> some View {
        let isSelected = (selectedProduct?.id ?? storeKit.annualProduct?.id) == product.id
        let isAnnual = product.id == StoreKitService.medicalAnnualId

        return Button {
            selectedProduct = product
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(isAnnual ? "Annual" : "Monthly")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isAnnual {
                            Text("Best Value")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
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
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.title2)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
    }
}
