import SwiftUI

// Plan KT §4.3 and §5.6 — "Your style", the one-time consent for writing drafts with the cloud
// model, and the learner's suggestion on the My Day page.

extension DraftCloudTarget: Identifiable {
    var id: String { consentKey }
}

/// My Day › Ready-to-send cards › Your style: the note drafts follow.
struct WritingStyleSettingsView: View {
    @ObservedObject var store: WritingStyleStore = .shared

    var body: some View {
        Form {
            if let suggestion = store.suggestion {
                Section {
                    StyleSuggestionLine(suggestion: suggestion, store: store)
                }
            }

            Section {
                Picker("Greeting", selection: binding(\.greeting)) {
                    Text("As the draft has it").tag(WritingStyle.Greeting.asWritten)
                    Text("“Hi” and their name").tag(WritingStyle.Greeting.hiName)
                    Text("None").tag(WritingStyle.Greeting.none)
                }
                TextField("Sign-off", text: binding(\.signOff), prompt: Text("For example: Cheers"))
                    .textInputAutocapitalization(.sentences)
                Picker("Length", selection: binding(\.length)) {
                    Text("Short").tag(WritingStyle.Length.short)
                    Text("As needed").tag(WritingStyle.Length.asNeeded)
                }
                Picker("Tone", selection: binding(\.formality)) {
                    Text("Casual").tag(WritingStyle.Formality.casual)
                    Text("Neutral").tag(WritingStyle.Formality.neutral)
                    Text("Formal").tag(WritingStyle.Formality.formal)
                }
                Toggle("Emoji", isOn: binding(\.emoji))
            } footer: {
                Text("Drafts on your cards follow this. A simple draft, written without a model, keeps its plain wording.")
            }

            Section {
                TextField("Anything else", text: binding(\.freeLine),
                          prompt: Text("For example: I never use exclamation marks"), axis: .vertical)
                    .lineLimit(1...3)
            } footer: {
                Text("When you change a draft before sending it, the app counts what kind of change it was, never the words, and after three of the same may suggest a change here.")
            }

            if !store.style.isStandard {
                Section {
                    Button("Reset style", role: .destructive) {
                        store.update { $0 = .standard }
                    }
                }
            }
        }
        .navigationTitle("Your style")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding<Value>(_ path: WritableKeyPath<WritingStyle, Value>) -> Binding<Value> {
        Binding(get: { store.style[keyPath: path] },
                set: { value in store.update { $0[keyPath: path] = value } })
    }
}

/// "Use {provider} to write drafts?" — asked once per model, naming what is sent.
struct DraftCloudConsentSheet: View {
    let target: DraftCloudTarget
    let onAnswer: (Bool) -> Void

    private var sent: [String] {
        var items = [
            String(localized: "The plain draft the card wrote", comment: "Draft consent: one thing sent to the cloud model."),
            String(localized: "The card's facts, such as times and places", comment: "Draft consent: one thing sent to the cloud model."),
            String(localized: "The first name of the person it's to", comment: "Draft consent: one thing sent to the cloud model."),
            String(localized: "Your style note", comment: "Draft consent: one thing sent to the cloud model."),
        ]
        if !target.isBlockedForCaptionText {
            items.append(String(localized: "For a meeting recap, the things agreed", comment: "Draft consent: one thing sent to the cloud model."))
        }
        return items
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sent, id: \.self) { item in
                        Label(item, systemImage: "arrow.up.circle")
                    }
                } header: {
                    Text("When no model on this iPhone can write a card's draft, \(target.providerName) gets:")
                        .textCase(nil)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("It never gets an email address or a phone number, your conversations, your memories or anything else in the app. \(target.providerName) handles it under your account's own terms.")
                        if target.isBlockedForCaptionText {
                            Text("Meeting recaps hold other people's words, so they are never sent to \(target.providerName).")
                        }
                        Text("You can change this in My Day settings at any time.")
                    }
                }
            }
            .navigationTitle("Use \(target.providerName) to write drafts?")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        onAnswer(true)
                    } label: {
                        Text("Use \(target.providerName)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not now") { onAnswer(false) }
                        .frame(minHeight: OGMetrics.minTouchTarget)
                }
                .padding()
            }
        }
        .interactiveDismissDisabled()
    }
}

/// The learner's proposal: accept it, or let it go.
struct StyleSuggestionLine: View {
    let suggestion: StyleSuggestion
    @ObservedObject var store: WritingStyleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.question)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Yes") { store.accept(suggestion) }
                    .buttonStyle(.bordered)
                Button("Not now") { store.ignore(suggestion) }
                    .buttonStyle(.bordered)
            }
            .font(.footnote.weight(.semibold))
        }
        .accessibilityElement(children: .contain)
    }
}
