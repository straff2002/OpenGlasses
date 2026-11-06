import SwiftUI
import Contacts
import ContactsUI

/// Settings › Field Assist › Experts (Plan KM P0): who "get me a furnace expert" and "call Sam" can
/// reach.
///
/// - With a profile, the organisation's rows are the profile's and read-only here, and the
///   technician's own additions sit below them.
/// - With no profile, the device owner is the organisation: one list, with kind, on-call hours and,
///   for a contracted expert, the rate the statement is figured at.
///
/// People are added from Contacts with `CNContactPickerViewController`, which runs outside the app
/// and needs no Contacts permission; what is kept is a snapshot of the name, number and email, not
/// the contact's identifier, which would not survive a restore or a second phone.
struct FieldAssistExpertsView: View {
    private let store = ExpertListStore.shared

    @State private var organization: [EscalationContact] = []
    @State private var personal: [PersonalExpert] = []
    @State private var managed = false
    @State private var pickingFor: ExpertListEntry.Source?
    @State private var problem: String?

    var body: some View {
        Form {
            if managed {
                managedOrganizationSection
            } else {
                ownerSection
            }
            if managed || !personal.isEmpty {
                personalSection
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Experts")
        .navigationBarTitleDisplayMode(.inline)
        .background(ContactPickerPresenter(isPresented: Binding(
            get: { pickingFor != nil },
            set: { if !$0 { pickingFor = nil } }
        )) { snapshot in
            add(snapshot)
        })
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .orgPolicyDidChange)) { _ in reload() }
    }

    // MARK: - Sections

    private var managedOrganizationSection: some View {
        Section {
            if organization.isEmpty {
                Text("Your organisation hasn't listed any experts.")
                    .foregroundStyle(.secondary)
            }
            ForEach(organization) { contact in
                ExpertRow(contact: contact, showsKind: true)
            }
        } header: {
            Text("From \(ManagedLockReason.organization)")
        } footer: {
            ManagedLockNote(organization: ManagedLockReason.organization)
        }
    }

    private var ownerSection: some View {
        Section {
            ForEach(organization) { contact in
                NavigationLink {
                    ExpertEditorView(draft: ExpertDraft(contact), ownerFields: true) { saved in
                        replaceOwner(saved)
                    }
                } label: {
                    ExpertRow(contact: contact, showsKind: true)
                }
            }
            .onDelete { offsets in
                var list = organization
                list.remove(atOffsets: offsets)
                saveOwner(list)
            }
            Button {
                pickingFor = .organization
            } label: {
                Label("Add from Contacts", systemImage: "person.crop.circle.badge.plus")
            }
        } header: {
            Text("Experts")
        } footer: {
            Text("Say \u{201C}get me a furnace expert\u{201D} or \u{201C}call Sam\u{201D} on a job. With no organisation profile on this phone, you set this list: what each expert knows, when they're on call, and for a contracted expert the rate their time is figured at on statements. The app never charges or pays anyone.")
        }
    }

    private var personalSection: some View {
        Section {
            ForEach(personal) { expert in
                NavigationLink {
                    ExpertEditorView(draft: ExpertDraft(expert.contact), ownerFields: false) { saved in
                        replacePersonal(saved)
                    }
                } label: {
                    ExpertRow(contact: expert.contact, showsKind: false)
                }
            }
            .onDelete { offsets in
                var list = personal
                list.remove(atOffsets: offsets)
                savePersonal(list)
            }
            if managed {
                Button {
                    pickingFor = .personal
                } label: {
                    Label("Add from Contacts", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: {
            Text("Added by You")
        } footer: {
            Text("Colleagues you add are on your phone only. They're always staff, with no rate.")
        }
    }

    // MARK: - Changes

    private func reload() {
        managed = store.organizationListIsManaged
        organization = store.organizationExperts
        personal = store.personalExperts
    }

    private func add(_ snapshot: ContactSnapshot) {
        let source = pickingFor ?? (managed ? .personal : .organization)
        pickingFor = nil
        switch source {
        case .organization where !managed:
            let contact = EscalationContact(id: UUID().uuidString, name: snapshot.name, phone: snapshot.phone,
                                            faceTimeHandle: snapshot.email, timeZoneIdentifier: TimeZone.current.identifier)
            saveOwner(organization + [contact])
        default:
            let expert = PersonalExpert(name: snapshot.name, phone: snapshot.phone, faceTimeHandle: snapshot.email)
            savePersonal(personal + [expert])
        }
    }

    private func replaceOwner(_ contact: EscalationContact) {
        saveOwner(organization.map { $0.id == contact.id ? contact : $0 })
    }

    private func replacePersonal(_ contact: EscalationContact) {
        // Only the fields a personal addition has are kept: never a kind, a rate or on-call hours.
        savePersonal(personal.map {
            $0.id == contact.id
                ? PersonalExpert(id: $0.id, name: contact.name, phone: contact.phone,
                                 faceTimeHandle: contact.faceTimeHandle, handoverChannel: contact.handoverChannel,
                                 specialties: contact.specialties)
                : $0
        })
    }

    private func saveOwner(_ list: [EscalationContact]) {
        problem = store.setDeviceOwnerExperts(list)?.message
        reload()
    }

    private func savePersonal(_ list: [PersonalExpert]) {
        problem = store.setPersonalExperts(list)?.message
        reload()
    }
}

// MARK: - A row

private struct ExpertRow: View {
    let contact: EscalationContact
    let showsKind: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(contact.name)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if !contact.specialties.isEmpty { parts.append(contact.specialties.joined(separator: ", ")) }
        if showsKind {
            parts.append(contact.kind == .staff ? String(localized: "Staff") : String(localized: "Contracted"))
            if !contact.onCall.isEmpty { parts.append(String(localized: "Set hours")) }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The editor

/// An expert as the editor holds it: text fields as typed, turned into a contact on save.
struct ExpertDraft: Equatable {
    struct Window: Equatable, Identifiable {
        let id = UUID()
        var weekday: Int
        var start: Int
        var end: Int
    }

    var id: String
    var name: String
    var phone: String
    var faceTimeHandle: String
    var specialties: String
    var channel: EscalationContact.HandoverChannel?
    var kind: EscalationContact.Kind
    var windows: [Window]
    var timeZoneIdentifier: String
    var perHour: String
    var minimumMinutes: Int
    var roundingMinutes: Int
    var currency: String

    init(_ contact: EscalationContact) {
        id = contact.id
        name = contact.name
        phone = contact.phone ?? ""
        faceTimeHandle = contact.faceTimeHandle ?? ""
        specialties = contact.specialties.joined(separator: ", ")
        channel = contact.handoverChannel
        kind = contact.kind
        windows = contact.onCall.map { Window(weekday: $0.weekday, start: $0.startMinute, end: $0.endMinute) }
        timeZoneIdentifier = contact.timeZoneIdentifier ?? TimeZone.current.identifier
        perHour = contact.rate.map { "\($0.perHour)" } ?? ""
        minimumMinutes = contact.rate?.minimumMinutes ?? 15
        roundingMinutes = contact.rate?.roundingMinutes ?? 15
        currency = contact.rate?.currency ?? (Locale.current.currency?.identifier ?? "USD")
    }

    /// The contact this draft describes. The owner's fields are read only when `ownerFields`.
    func contact(ownerFields: Bool) -> EscalationContact {
        guard ownerFields else {
            return EscalationContact(id: id, name: name, phone: phone, faceTimeHandle: faceTimeHandle,
                                     handoverChannel: channel, specialties: ExpertSpecialty.parse(specialties))
        }
        let rate: EscalationContact.Rate? = kind == .contracted
            ? Decimal(string: perHour.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")).map {
                EscalationContact.Rate(perHour: $0, minimumMinutes: minimumMinutes,
                                       roundingMinutes: roundingMinutes, currency: currency.uppercased())
            }
            : nil
        return EscalationContact(id: id, name: name, phone: phone, faceTimeHandle: faceTimeHandle,
                                 handoverChannel: channel, specialties: ExpertSpecialty.parse(specialties),
                                 kind: kind,
                                 onCall: windows.compactMap { OnCallWindow(weekday: $0.weekday, startMinute: $0.start,
                                                                           endMinute: $0.end == 0 ? 1440 : $0.end) },
                                 timeZoneIdentifier: timeZoneIdentifier, rate: rate)
    }
}

private struct ExpertEditorView: View {
    @State var draft: ExpertDraft
    let ownerFields: Bool
    let onSave: (EscalationContact) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .textContentType(.name)
                TextField("Phone number", text: $draft.phone)
                    .keyboardType(.phonePad)
                TextField("FaceTime email or number", text: $draft.faceTimeHandle)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Contact")
            }

            Section {
                TextField("furnace, heat pump, Lennox", text: $draft.specialties, axis: .vertical)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Specialties")
            } footer: {
                Text("Separate them with commas. \u{201C}Get me a furnace expert\u{201D} offers the experts tagged furnace first, then those whose tags match the unit on the job.")
            }

            Section {
                Picker("Send jobs by", selection: $draft.channel) {
                    Text("Not set").tag(EscalationContact.HandoverChannel?.none)
                    Text("Messages").tag(EscalationContact.HandoverChannel?.some(.messages))
                    Text("WhatsApp").tag(EscalationContact.HandoverChannel?.some(.whatsApp))
                    Text("Email").tag(EscalationContact.HandoverChannel?.some(.email))
                    Text("AirDrop").tag(EscalationContact.HandoverChannel?.some(.airDrop))
                }
            }

            if ownerFields {
                ownerSections
            }

            if let problem = draft.contact(ownerFields: ownerFields).problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? String(localized: "Expert") : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft.contact(ownerFields: ownerFields))
                    dismiss()
                }
                .disabled(draft.contact(ownerFields: ownerFields).problem != nil)
            }
        }
    }

    @ViewBuilder private var ownerSections: some View {
        Section {
            Picker("Kind", selection: $draft.kind) {
                Text("Staff").tag(EscalationContact.Kind.staff)
                Text("Contracted").tag(EscalationContact.Kind.contracted)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Staff are your own people. A contracted expert is paid under your own agreement with them.")
        }

        Section {
            ForEach($draft.windows) { $window in
                OnCallWindowRow(window: $window)
            }
            .onDelete { draft.windows.remove(atOffsets: $0) }
            Button {
                draft.windows.append(.init(weekday: 2, start: 9 * 60, end: 17 * 60))
            } label: {
                Label("Add hours", systemImage: "plus")
            }
            Picker("Time zone", selection: $draft.timeZoneIdentifier) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                    Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("On Call")
        } footer: {
            Text("No hours means on call any time. Hours are in the expert's own time zone; an end before the start runs past midnight.")
        }

        if draft.kind == .contracted {
            Section {
                HStack {
                    Text("Per hour")
                    Spacer()
                    TextField("0", text: $draft.perHour)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    TextField("USD", text: $draft.currency)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(width: 56)
                }
                Stepper("Minimum \(draft.minimumMinutes) min", value: $draft.minimumMinutes, in: 0...480, step: 5)
                Stepper("Round up to \(draft.roundingMinutes) min", value: $draft.roundingMinutes, in: 1...60)
            } header: {
                Text("Rate")
            } footer: {
                Text("Used only to figure the expert's time on statements. Technicians see minutes, never the rate, and the app never charges anything.")
            }
        }
    }
}

private struct OnCallWindowRow: View {
    @Binding var window: ExpertDraft.Window

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Day", selection: $window.weekday) {
                ForEach(1...7, id: \.self) { day in
                    Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                }
            }
            DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
            DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute)
        }
    }

    private func time(_ keyPath: WritableKeyPath<ExpertDraft.Window, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = window[keyPath: keyPath] % 1440
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                             of: Date(timeIntervalSinceReferenceDate: 0)) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                window[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}

// MARK: - The contact picker

/// What is kept of a contact picked in Contacts: the name, one number, one email. Never the
/// contact's identifier.
struct ContactSnapshot: Equatable {
    let name: String
    let phone: String?
    let email: String?

    /// A number as Contacts stores it, reduced to the digits and a leading `+` — Contacts adds
    /// direction marks and spacing that `CallRoute` would rightly refuse.
    static func cleanedPhone(_ raw: String) -> String? {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let leadingPlus = raw.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{202A}\u{202C}\u{200E}\u{200F}")))
            .hasPrefix("+")
        return CallRoute.cleanedNumber((leadingPlus ? "+" : "") + digits)
    }

    init(name: String, phone: String?, email: String?) {
        self.name = name
        self.phone = phone
        self.email = email
    }

    init(_ contact: CNContact) {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)
        let fallback = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        name = formatted ?? (fallback.isEmpty ? contact.organizationName : fallback)
        let numbers = contact.isKeyAvailable(CNContactPhoneNumbersKey) ? contact.phoneNumbers : []
        let mobile = numbers.first { [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone].contains($0.label ?? "") }
        phone = (mobile ?? numbers.first).flatMap { Self.cleanedPhone($0.value.stringValue) }
        let emails = contact.isKeyAvailable(CNContactEmailAddressesKey) ? contact.emailAddresses : []
        email = emails.first.flatMap { CallRoute.cleanedHandle(String($0.value)) }
    }
}

/// Presents `CNContactPickerViewController` from a zero-size host. The picker runs out of process,
/// so the app gets only the contact the person tapped, and asks for no Contacts permission.
private struct ContactPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (ContactSnapshot) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, host.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0")
        DispatchQueue.main.async { host.present(picker, animated: true) }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPickerPresenter

        init(_ parent: ContactPickerPresenter) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let snapshot = ContactSnapshot(contact)
            parent.isPresented = false
            guard !snapshot.name.isEmpty, snapshot.phone != nil || snapshot.email != nil else { return }
            parent.onPick(snapshot)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }
    }
}
