import SwiftUI

/// Plan LC §1: offered once, when Meta Ray-Ban Display glasses connect with the HUD off. The
/// display turns on only from **Turn on**; **Not now** leaves it off and is never asked again (the
/// switch stays in Devices & Privacy › Glasses).
struct DisplayOfferBanner: View {
    let turnOn: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(DisplayOfferPolicy.title, systemImage: "eyeglasses")
                .font(.headline)
            Text(DisplayOfferPolicy.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(String(localized: "Turn on", comment: "Display offer: turn the in-lens display on."),
                       action: turnOn)
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "Not now", comment: "Display offer: leave the in-lens display off."),
                       action: notNow)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .accessibilityElement(children: .contain)
    }
}
