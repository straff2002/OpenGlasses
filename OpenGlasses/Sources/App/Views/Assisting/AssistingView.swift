import SwiftUI

/// Assisting (Plan KM §7, P2): the jobs sent to this phone's owner for their advice, and their
/// expert card.
///
/// Reached from Everyday whatever else is installed — it needs no Field Assist — and shown on its
/// own when a handover is opened. One section per organisation, newest first, and nothing that
/// searches across them. Each row opens a read-only view of that one handover.
struct AssistingView: View {
    @ObservedObject var service: AssistingService
    @ObservedObject private var store: AssistingHandoverStore

    init(service: AssistingService = .shared) {
        self.service = service
        _store = ObservedObject(wrappedValue: service.store)
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ExpertCardView(cards: service.cards)
                } label: {
                    SettingsLinkLabel(title: String(localized: "Your Expert Card"),
                                      subtitle: service.cards.card == nil
                                          ? String(localized: "So organisations can add you and match your replies")
                                          : String(localized: "Share it as a file or a code"),
                                      icon: "person.text.rectangle")
                }
            } footer: {
                Text("Organisations you advise add you to their experts list from your card. Your rate is agreed with each of them; the card never carries one.")
            }

            if store.held.isEmpty {
                Section {
                    Text("Job handovers sent to you appear here when you open the .ogcase file from Messages, Mail or Files.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(store.groups) { group in
                Section {
                    ForEach(group.handovers) { held in
                        NavigationLink {
                            AssistingHandoverView(service: service, handoverId: held.id)
                        } label: {
                            AssistingHandoverRow(held: held)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { group.handovers[$0].id }.forEach(service.delete)
                    }
                } header: {
                    Text(group.organisation.isEmpty ? String(localized: "Sender not named") : group.organisation)
                }
            }

            if !store.held.isEmpty {
                Section {
                    Text("Each handover stays on this phone for the days its organisation set after you tap Done, then it's deleted. Nothing from one reaches the assistant, its memory or search, and none is shown beside another organisation's. Anyone can forward a file, so treat each as confidential to the organisation it names.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .ogFormStyle()
        .navigationTitle("Assisting")
        .onAppear { store.purgeExpired() }
    }
}

private struct AssistingHandoverRow: View {
    let held: HeldHandover

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        held.handover.job.reference.map { String(localized: "Job \($0)") } ?? String(localized: "Job handover")
    }

    private var detail: String {
        var parts = [String(localized: "Update \(held.handover.generation)")]
        if let clock = held.clock {
            if clock.isDone {
                parts.append(held.replySentAt == nil ? String(localized: "Done, reply not sent") : String(localized: "Done, reply sent"))
            } else if clock.isPaused {
                parts.append(String(localized: "Paused"))
            } else {
                parts.append(String(localized: "Clock running"))
            }
        } else {
            parts.append(String(localized: "Not taken"))
        }
        return parts.joined(separator: " · ")
    }
}
