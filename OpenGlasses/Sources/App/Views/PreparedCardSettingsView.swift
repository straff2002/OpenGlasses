import SwiftUI

/// My Day › Ready-to-send cards (Plan KT §5.6): the cards' switch, one switch per kind, short
/// night's thresholds, the lock-screen text, the Google calendar help, and — with Field Assist —
/// the job cards and "Text customers from cards", which an organisation can pin off.
struct PreparedCardSettingsView: View {
    @ObservedObject var service: MyDayService

    @AppStorage("preparedCardsEnabled") private var enabled = true
    @AppStorage("preparedCardLockScreenText") private var lockScreenText = false
    @AppStorage("fieldAssistEnabled") private var fieldAssistEnabled = false
    @State private var kinds: [PreparedCardKind: Bool] = [:]
    @State private var customerTexts = Config.preparedCardCustomerTexts
    @State private var sleepMinutes = Config.preparedCardShortNightMinutes
    @State private var earlyMeeting = Self.date(minutes: Config.preparedCardEarlyMeetingMinutes)
    @State private var showingGoogleHelp = false

    private static let personalKinds: [PreparedCardKind] = [.leaveBy, .runningLate, .meetingFollowUp, .fitItIn]
    private static let jobKinds: [PreparedCardKind] = [.jobOnMyWay, .jobRunningLate, .jobReportOwed,
                                                       .jobPartsOwed, .jobSignOffOwed]

    private var healthOn: Bool { AIFeatureGate.isEnabled(.healthSummaries) }
    private var customerTextsLocked: Bool { PolicyEnvelope.isLocked(.preparedCardCustomerTexts) }

    var body: some View {
        Form {
            Section {
                Toggle("Ready-to-send cards", isOn: $enabled)
            } footer: {
                Text("Cards join what My Day already knows into one thing to do, with any message written for you to check. Nothing is sent until you tap Send in Messages or Mail. Off, My Day shows its list only.")
            }

            if enabled {
                Section("Cards") {
                    ForEach(Self.personalKinds, id: \.self) { kind in
                        Toggle(kind.settingsName, isOn: binding(kind))
                    }
                }

                Section {
                    Toggle(PreparedCardKind.shortNight.settingsName, isOn: binding(.shortNight))
                        .disabled(!healthOn)
                    if kinds[.shortNight] ?? false {
                        Stepper(value: $sleepMinutes, in: 180...600, step: 30) {
                            Text("Slept less than \(Self.hoursText(sleepMinutes))")
                        }
                        DatePicker("Meeting before", selection: $earlyMeeting, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text(healthOn
                         ? "After a short night, offers to ask to move an early meeting you didn't organise. The message never mentions sleep, and sleep is never shown on the lock screen or said aloud unless you ask."
                         : "Needs Health Summaries on first, under Health & Fitness.")
                }

                if fieldAssistEnabled && Config.fieldAssistUnlocked {
                    Section {
                        ForEach(Self.jobKinds, id: \.self) { kind in
                            Toggle(kind.settingsName, isOn: binding(kind))
                        }
                        Toggle("Text customers from cards", isOn: $customerTexts)
                            .disabled(customerTextsLocked)
                    } header: {
                        Text("Job day")
                    } footer: {
                        Text(customerTextsLocked
                             ? "Your organisation has turned off texting customers from cards."
                             : "A text to a customer opens in your own Messages, from your number, for you to send.")
                    }
                }

                Section {
                    Toggle("Show card text on the lock screen", isOn: $lockScreenText)
                } footer: {
                    Text("Off, a card's notification says only that something is ready in My Day. A draft is never on the lock screen.")
                }

                if service.googleCalendarMissing {
                    Section {
                        Button("Add your Google calendar") { showingGoogleHelp = true }
                    } footer: {
                        Text("Add your Google account to iPhone's Calendar and its events show up in My Day. No Google sign-in happens in this app.")
                    }
                }
            }
        }
        .navigationTitle("Ready-to-send cards")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingGoogleHelp) { GoogleCalendarHelpSheet() }
        .onAppear {
            kinds = Dictionary(uniqueKeysWithValues: PreparedCardKind.allCases.map { ($0, Config.preparedCardKindEnabled($0)) })
        }
        .onChange(of: enabled) { _, _ in service.rejoinCards() }
        .onChange(of: customerTexts) { _, value in
            Config.preparedCardCustomerTexts = value
            service.rejoinCards()
        }
        .onChange(of: sleepMinutes) { _, value in
            Config.preparedCardShortNightMinutes = value
            service.rejoinCards()
        }
        .onChange(of: earlyMeeting) { _, value in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            Config.preparedCardEarlyMeetingMinutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 30)
            service.rejoinCards()
        }
    }

    private func binding(_ kind: PreparedCardKind) -> Binding<Bool> {
        Binding(
            get: { kinds[kind] ?? Config.preparedCardKindEnabled(kind) },
            set: { value in
                kinds[kind] = value
                Config.setPreparedCardKind(kind, enabled: value)
                service.rejoinCards()
            })
    }

    private static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func hoursText(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes / 60) h"
    }
}
