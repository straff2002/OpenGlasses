import SwiftUI

/// The Apple Weather credit Apple requires wherever WeatherKit data is displayed: the combined mark
/// (or the service name as text until the mark has loaded) and a link to the legal attribution
/// page. Drawn under My Day's weather row, at the foot of a chat thread that answered a weather
/// question, and in Settings → About Weather Data.
struct WeatherAttributionView: View {
    @ObservedObject private var store = WeatherAttributionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            credit
            Link("Legal", destination: store.info.legalPageURL)
                .font(.caption2)
                .accessibilityLabel("Weather data legal attribution")
            Spacer(minLength: 0)
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var credit: some View {
        if let mark = store.mark(darkAppearance: colorScheme == .dark) {
            Image(uiImage: mark)
                .resizable()
                .scaledToFit()
                .frame(height: 12)
                .accessibilityLabel(Text(verbatim: store.info.serviceName))
        } else {
            Text(verbatim: store.info.serviceName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Works with your iPhone → About Weather Data.
struct WeatherDataAboutView: View {
    var body: some View {
        Form {
            Section {
                WeatherAttributionView()
                    .padding(.vertical, 4)
            } footer: {
                Text("Weather answers, rain in the next hour, severe-weather alerts and the weather in My Day come from Apple Weather. To get them, Avenkin sends Apple your approximate location, rounded to about a kilometre, or the place you asked about. With Medical Local Only on, Avenkin doesn't look up the weather.")
            }
        }
        .navigationTitle("About Weather Data")
        .ogFormStyle()
    }
}
