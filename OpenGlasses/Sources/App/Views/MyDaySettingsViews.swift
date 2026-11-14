import SwiftUI

// My Day's own settings (Plan KH P2), moved from Works with your iPhone. The switch itself is the
// My Day & Routines group's parent on the Everyday screen; these screens open only while it is on.

/// What the briefing covers, and how leave-by times are worked out.
struct MyDayContentsSettingsView: View {
    @AppStorage("myDayCalendarIncluded") private var myDayCalendarIncluded = true
    @AppStorage("myDayRemindersIncluded") private var myDayRemindersIncluded = true
    @AppStorage("myDayWeatherIncluded") private var myDayWeatherIncluded = true
    @AppStorage("myDayTravelIncluded") private var myDayTravelIncluded = true
    @AppStorage("myDayDigestIncluded") private var myDayDigestIncluded = true
    @AppStorage("myDayGoalsIncluded") private var myDayGoalsIncluded = true
    @AppStorage("myDayTransportMode") private var myDayTransportMode = MyDayTransportMode.walking.rawValue
    @AppStorage("myDayTravelBufferMinutes") private var myDayTravelBufferMinutes = 10
    @AppStorage("myDayTravelOrigin") private var myDayTravelOrigin = MyDayTravelOrigin.currentLocation.rawValue
    @AppStorage("myDayHomeAddress") private var myDayHomeAddress = ""
    @AppStorage("myDayWorkAddress") private var myDayWorkAddress = ""

    var body: some View {
        Form {
            Section {
                Toggle("Calendar", isOn: $myDayCalendarIncluded)
                Toggle("Reminders", isOn: $myDayRemindersIncluded)
                Toggle("Weather", isOn: $myDayWeatherIncluded)
                Toggle("Travel time", isOn: $myDayTravelIncluded)
                    .disabled(!myDayCalendarIncluded)
                Toggle("Actionable updates", isOn: $myDayDigestIncluded)
                Toggle("Goals", isOn: $myDayGoalsIncluded)
            } header: {
                Text("Included in My Day")
            } footer: {
                Text("Calendar includes Apple, Outlook, Microsoft 365, and other accounts that are available in the iPhone Calendar app. My Day does not connect directly to the Outlook app.")
            }

            if myDayCalendarIncluded && myDayTravelIncluded {
                Section {
                    Picker("Travel mode", selection: $myDayTransportMode) {
                        ForEach(MyDayTransportMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }

                    Stepper(
                        "Leave-by buffer: \(myDayTravelBufferMinutes) min",
                        value: $myDayTravelBufferMinutes,
                        in: 0...60,
                        step: 5
                    )

                    Picker("Start from", selection: $myDayTravelOrigin) {
                        ForEach(MyDayTravelOrigin.allCases, id: \.rawValue) { origin in
                            Text(origin.displayName).tag(origin.rawValue)
                        }
                    }

                    if myDayTravelOrigin == MyDayTravelOrigin.home.rawValue {
                        TextField("Home address", text: $myDayHomeAddress)
                            .textContentType(.fullStreetAddress)
                            .autocorrectionDisabled()
                    } else if myDayTravelOrigin == MyDayTravelOrigin.work.rawValue {
                        TextField("Work address", text: $myDayWorkAddress)
                            .textContentType(.fullStreetAddress)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Leave By")
                } footer: {
                    Text("Maps estimates only the next event with a physical location. Event locations and routes are not saved by Avenkin.")
                }
            }
        }
        .navigationTitle("What's in My Day")
        .ogFormStyle()
    }
}

/// When the briefing arrives by itself.
struct MyDayDeliverySettingsView: View {
    @AppStorage("myDayMorningDeliveryEnabled") private var myDayMorningDeliveryEnabled = false
    @AppStorage("myDayMorningDeliveryMinutes") private var myDayMorningDeliveryMinutes = 8 * 60
    @AppStorage("myDayEveningDeliveryEnabled") private var myDayEveningDeliveryEnabled = false
    @AppStorage("myDayEveningDeliveryMinutes") private var myDayEveningDeliveryMinutes = 19 * 60
    /// Plan LE: off by default (decision 2). Its time is stored only once the wearer picks one.
    @AppStorage("myDayCheckInEnabled") private var myDayCheckInEnabled = false
    @State private var myDayCheckInMinutes: Int? = Config.myDayCheckInMinutes
    @AppStorage("myDayScheduledSpeechEnabled") private var myDayScheduledSpeechEnabled = false
    @AppStorage("myDayQuietHoursEnabled") private var myDayQuietHoursEnabled = true
    @AppStorage("myDayQuietStartMinutes") private var myDayQuietStartMinutes = 22 * 60
    @AppStorage("myDayQuietEndMinutes") private var myDayQuietEndMinutes = 7 * 60
    @State private var didResetMyDayHistory = false

    var body: some View {
        Form {
            Section {
                Toggle("Morning briefing", isOn: $myDayMorningDeliveryEnabled)
                if myDayMorningDeliveryEnabled {
                    DatePicker(
                        "Morning time",
                        selection: timeBinding($myDayMorningDeliveryMinutes),
                        displayedComponents: .hourAndMinute
                    )
                }

                Toggle("Evening preparation", isOn: $myDayEveningDeliveryEnabled)
                if myDayEveningDeliveryEnabled {
                    DatePicker(
                        "Evening time",
                        selection: timeBinding($myDayEveningDeliveryMinutes),
                        displayedComponents: .hourAndMinute
                    )
                }

                Toggle("Evening check-in", isOn: $myDayCheckInEnabled)
                if myDayCheckInEnabled {
                    DatePicker(
                        "Check-in time",
                        selection: timeBinding(checkInMinutesBinding),
                        displayedComponents: .hourAndMinute
                    )
                }

                Toggle("Speak scheduled briefings", isOn: $myDayScheduledSpeechEnabled)
                    .disabled(!myDayMorningDeliveryEnabled && !myDayEveningDeliveryEnabled
                              && !myDayCheckInEnabled)

                Toggle("Quiet hours", isOn: $myDayQuietHoursEnabled)
                if myDayQuietHoursEnabled {
                    DatePicker(
                        "Quiet from",
                        selection: timeBinding($myDayQuietStartMinutes),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "Quiet until",
                        selection: timeBinding($myDayQuietEndMinutes),
                        displayedComponents: .hourAndMinute
                    )
                }
            } header: {
                Text("Scheduled Delivery")
            } footer: {
                Text("The evening check-in says what from today is still waiting on you, and stays quiet when nothing is. Delivered while Avenkin is active. Open My Day once to resolve Calendar and Reminders access before scheduled delivery. Speech is private-by-default: it only plays while you are present, outside quiet hours, online, and out of power reserve.")
            }

            Section {
                Button(didResetMyDayHistory ? "Delivery history reset" : "Reset delivery history") {
                    Config.resetMyDayDeliveryHistory()
                    didResetMyDayHistory = true
                }
                .disabled(didResetMyDayHistory)
            } footer: {
                Text("Resets content-free occurrence markers only. It does not delete Calendar, Reminders, routes, or digest items.")
            }
        }
        .navigationTitle("Scheduled Delivery")
        .ogFormStyle()
    }

    /// The check-in's time as the picker shows it: the wearer's own, else 17:00 with Field Assist on
    /// and 21:00 without (decision 9). Nothing is stored until the wearer moves it, so the default
    /// keeps following Field Assist until then.
    private var checkInMinutesBinding: Binding<Int> {
        Binding(
            get: {
                MyDayCheckInDefaults.shown(stored: myDayCheckInMinutes, fieldAssistOn: Config.fieldAssistActive)
            },
            set: { minutes in
                Config.myDayCheckInMinutes = minutes
                myDayCheckInMinutes = Config.myDayCheckInMinutes
            }
        )
    }

    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let value = min(23 * 60 + 59, max(0, minutes.wrappedValue))
                return Calendar.current.date(
                    bySettingHour: value / 60,
                    minute: value % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
