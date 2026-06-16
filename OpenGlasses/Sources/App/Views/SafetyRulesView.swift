import SwiftUI

/// View/toggle the deterministic agent safety rules (Plan S). These run before any agent action
/// in `SafetySupervisor`, independent of the model — so a constraint holds even if the model is
/// confused or talked into an action. Settings persist via `SafetySettings` and take effect on
/// the next tool call.
struct SafetyRulesView: View {
    @EnvironmentObject var appState: AppState

    @State private var ruleEnabled: [String: Bool] = [:]
    @State private var quietStart = SafetySettings.quietHoursStart
    @State private var quietEnd = SafetySettings.quietHoursEnd
    @State private var stepBudget = SafetySettings.stepBudget
    @State private var hasHome = SafetySettings.homeRegion != nil
    @State private var homeRadius = SafetySettings.homeRegion?.radius ?? 150
    @State private var homeError: String?

    var body: some View {
        List {
            Section {
                ForEach(SafetyRuleKind.allCases) { kind in
                    Toggle(isOn: ruleBinding(kind)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Safety Rules")
            } footer: {
                Text("Deterministic checks that run before any agent action — even if the model is talked into one. A blocked action is withheld; a confirm action asks for a spoken “confirm”.")
            }

            Section("Quiet Hours") {
                Stepper("Start \(twoDigit(quietStart)):00", value: $quietStart, in: 0...23)
                    .onChange(of: quietStart) { _, _ in SafetySettings.setQuietHours(start: quietStart, end: quietEnd) }
                Stepper("End \(twoDigit(quietEnd)):00", value: $quietEnd, in: 0...23)
                    .onChange(of: quietEnd) { _, _ in SafetySettings.setQuietHours(start: quietStart, end: quietEnd) }
                Text("During this window the quiet-hours rule confirms before any message is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Plan Step Budget") {
                Stepper("Max \(stepBudget) steps per plan", value: $stepBudget, in: 1...20)
                    .onChange(of: stepBudget) { _, _ in SafetySettings.setStepBudget(stepBudget) }
            }

            Section {
                Toggle("Use my current location as home", isOn: $hasHome)
                    .onChange(of: hasHome) { _, on in setHome(on) }
                if hasHome {
                    Stepper("Radius \(Int(homeRadius)) m", value: $homeRadius, in: 50...2000, step: 50)
                        .onChange(of: homeRadius) { _, r in updateHomeRadius(r) }
                }
                if let homeError {
                    Text(homeError).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Home Region (geofence)")
            } footer: {
                Text("The geofence rule blocks smart-home / Home Assistant actuation when you're outside this region. Turn the rule on above after setting a home.")
            }
        }
        .navigationTitle("Agent Safety")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Bindings / actions

    private func ruleBinding(_ kind: SafetyRuleKind) -> Binding<Bool> {
        Binding(
            get: { ruleEnabled[kind.rawValue] ?? SafetySettings.isRuleEnabled(kind) },
            set: { ruleEnabled[kind.rawValue] = $0; SafetySettings.setRuleEnabled(kind, $0) }
        )
    }

    private func setHome(_ on: Bool) {
        homeError = nil
        guard on else {
            SafetySettings.setHomeRegion(nil)
            return
        }
        guard let loc = appState.locationService.currentLocation else {
            hasHome = false
            homeError = "No location available yet. Allow location access and try again."
            return
        }
        SafetySettings.setHomeRegion(HomeRegion(latitude: loc.coordinate.latitude,
                                                longitude: loc.coordinate.longitude,
                                                radius: homeRadius))
    }

    private func updateHomeRadius(_ radius: Double) {
        guard let home = SafetySettings.homeRegion else { return }
        SafetySettings.setHomeRegion(HomeRegion(latitude: home.latitude, longitude: home.longitude, radius: radius))
    }

    private func twoDigit(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
