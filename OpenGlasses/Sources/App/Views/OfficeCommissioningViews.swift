import SwiftUI

/// Mounts the office-code flow over the root view, as `OrgEnrolmentOverlay` does for a profile.
/// Its own `@ObservedObject`, so a stage change repaints.
struct OfficeCommissioningOverlay: View {
    @ObservedObject var service: OfficeCommissioningService

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { service.stage != .idle },
                set: { if !$0 { service.dismiss() } })) {
                OfficeCommissioningSheet(service: service)
            }
    }
}

/// Joining an office by its code: the comparison code while the office decides, then the
/// organisation's own review, then the outcome.
struct OfficeCommissioningSheet: View {
    @ObservedObject var service: OfficeCommissioningService

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Join Avenkin Office")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { service.dismiss() } label: {
                            if isFinished {
                                Text("Done")
                            } else if case .modelKey = service.stage {
                                Text("Later")
                            } else {
                                Text("Cancel")
                            }
                        }
                        .disabled(service.stage.isBusy)
                    }
                }
        }
        .interactiveDismissDisabled(!isFinished)
    }

    private var isFinished: Bool {
        switch service.stage {
        case .notStarted, .refused, .expired, .paired, .failed: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch service.stage {
        case .idle:
            EmptyView()

        case .checking:
            OfficeCommissioningProgress(text: Text("Checking the office's code…"))

        case .sending:
            OfficeCommissioningProgress(text: Text("Sending this phone's details to the office…"))

        case .waiting(let code):
            OGScrollPage {
                OGSection(header: "Check this matches the office screen",
                          footer: "Someone at the office approves this phone on their screen. Keep this screen open until they do.") {
                    OfficeComparisonCode(code: code)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 12)
                }
                if let expiry = service.expiresAt {
                    OGNotice(text: "If nobody approves it by \(expiry, style: .time), ask the office for a new code.",
                             systemImage: "clock")
                }
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for the office…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }

        case .networkFailure:
            OfficeCommissioningOutcome(
                systemImage: "wifi.exclamationmark",
                title: Text("Couldn't reach the office"),
                detail: Text("Check this phone is on the same network as the office computer, then try again. Trying again sends the same details, so the office still sees the same code.")) {
                Button("Try Again") { service.retry() }
                    .buttonStyle(.ogProminent)
            }

        case .notStarted(let reason):
            OfficeCommissioningOutcome(systemImage: "exclamationmark.triangle",
                                       title: Text("This phone can't join the office"),
                                       detail: Self.text(for: reason))

        case .refused(let reason):
            OfficeCommissioningOutcome(systemImage: "hand.raised",
                                       title: Text("The office didn't add this phone"),
                                       detail: Self.text(for: reason))

        case .expired:
            OfficeCommissioningOutcome(
                systemImage: "clock",
                title: Text("The office's code has expired"),
                detail: Text("Nothing on this phone changed. Ask the office for a new code and scan it again."))

        case .reviewing(let review):
            OrgProfileReviewList(review: review) { service.confirm() }

        case .pairing:
            OfficeCommissioningProgress(text: Text("Joining the office…"))

        case .modelKey(let model, let organization):
            OrgModelKeyPage(model: model, organization: organization,
                            submit: { service.submitModelKey($0) },
                            later: { service.deferModelKey() })

        case .paired(let name, officeConnected: true):
            OfficeCommissioningOutcome(
                systemImage: "building.2",
                title: Text(verbatim: name),
                detail: Text("This phone is now managed by \(name) and paired with its office. Settings it locks show its name, and the device owner can remove the profile from Settings."))

        case .paired(let name, officeConnected: false):
            OfficeCommissioningOutcome(
                systemImage: "building.2",
                title: Text(verbatim: name),
                detail: Text("This phone is now managed by \(name) and paired with its office, but it couldn't reach the office yet. On the office's network, open Field Assist settings, then Pair with Avenkin Office, and use Test office connection."))

        case .failed(let failure):
            OfficeCommissioningOutcome(systemImage: "exclamationmark.triangle",
                                       title: Text("This phone didn't join the office"),
                                       detail: Self.text(for: failure))
        }
    }

    static func text(for reason: OfficeCommissioningFlow.NotStarted) -> Text {
        switch reason {
        case .unsupportedBuild:
            return Text("This version of Avenkin can't join an office by scanning its code. Ask your organisation for an Avenkin Office setup file instead.")
        case .malformed:
            return Text("That isn't an Avenkin Office code this phone can use. Ask the office to show the code again.")
        case .expired:
            return Text("The office's code has expired. Ask the office for a new code and scan it again.")
        case .enrolledElsewhere(let organization?):
            return Text("This phone is managed by \(organization), which is a different organisation from this office. The device owner has to remove that first, from Settings.")
        case .enrolledElsewhere(nil):
            return Text("This phone is managed by a different organisation from this office. The device owner has to remove that first, from Settings.")
        case .noIdentity:
            return Text("This phone couldn't read its own office identity. Restart Avenkin and scan the code again.")
        }
    }

    static func text(for reason: OfficeCommissioning.RefusalReason) -> Text {
        switch reason {
        case .expired:
            return Text("The code expired before the office approved this phone. Ask the office for a new code.")
        case .alreadyUsed:
            return Text("That code has already been used. Each code adds one phone: ask the office for a new one.")
        case .wrongOrganisation:
            return Text("The office says this phone belongs to a different organisation.")
        case .refusedByPerson:
            return Text("Someone at the office declined this phone. Nothing on this phone changed.")
        case .policy:
            return Text("The office's settings don't allow this phone to join. Ask your administrator.")
        }
    }

    static func text(for failure: OfficeCommissioningFlow.Failure) -> Text {
        switch failure {
        case .couldNotAnswer:
            return Text("This phone couldn't prepare its answer to the office. Scan the code again.")
        case .unreadableAnswer:
            return Text("The office's answer couldn't be read. Ask the office for a new code and scan it again.")
        case .approvalForAnotherPhone:
            return Text("The office approved a different phone. Nothing on this phone changed. Ask the office for a new code.")
        case .otherOrganisationsSetup:
            return Text("The office sent the setup for a different organisation from its code. Nothing on this phone changed.")
        case .setupDidNotVerify(let message):
            return Text(verbatim: message)
        case .bindingDidNotVerify:
            return Text("The office's pairing isn't signed by the administrator your organisation named, so nothing was applied. Ask your administrator.")
        case .notApplied(let message):
            return Text(verbatim: message)
        case .bindingNotKept:
            return Text("Your organisation's profile is in force, but this phone couldn't keep its pairing with the office. Ask the office to add this phone again.")
        }
    }
}

/// The code both screens show, large, in its three groups.
struct OfficeComparisonCode: View {
    let code: String

    var body: some View {
        let groups = OfficeCommissioningFlow.comparisonGroups(code) ?? [code]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { groupTexts(groups) }
            VStack(spacing: 6) { groupTexts(groups) }
        }
        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Comparison code"))
        // Spelled out a character at a time, a pause between groups, so it can be compared aloud.
        .accessibilityValue(Text(verbatim: groups.map { $0.map(String.init).joined(separator: " ") }
            .joined(separator: ", ")))
    }

    @ViewBuilder private func groupTexts(_ groups: [String]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            Text(verbatim: group)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct OfficeCommissioningProgress: View {
    let text: Text

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            text
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OGTheme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}

private struct OfficeCommissioningOutcome<Actions: View>: View {
    let systemImage: String
    let title: Text
    let detail: Text
    @ViewBuilder var actions: () -> Actions

    init(systemImage: String, title: Text, detail: Text,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        OGScrollPage {
            OGCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label { title.font(.headline) } icon: { Image(systemName: systemImage) }
                    detail
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            actions()
        }
    }
}
