import SwiftUI

/// The running procedure's current step on the phone (Plan MN §4). Works with or without the
/// assistant: the title, the safety note, the instruction and where the run is; the answer control
/// for the step's kind with targets big enough for gloves; the read-back, the corrective note and
/// an override with a reason; Next, Back and the branches the person chooses; and the trail so far.
///
/// A run started by voice or on the lens shows here too — the screen reads the session, not a run
/// of its own. Photos come through the job photo path (`JobPhotoEvidenceService`), never a camera
/// tap of the screen's own. Every decision is the runner's; this only shows it and asks.
struct ProcedureStepScreen: View {
    @ObservedObject private var sessions = FieldSessionService.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    /// What is being typed on the number pad, or in the text or code field.
    @State private var entry = ""
    @State private var note = ""
    @State private var overriding = false
    @State private var overrideBranch: String?
    @State private var overrideReason = ""
    /// The runner's last refusal or re-ask, said in its own words.
    @State private var problem: String?
    @State private var takingPhoto = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = sessions.activeProcedurePresentation {
                    content(presentation)
                } else {
                    finished
                }
            }
            .background(OGTheme.canvas.ignoresSafeArea())
            .tint(accent)
            .navigationTitle(sessions.activeProcedureTitle ?? String(localized: "Procedure"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Close").font(.body) }
                        .accessibilityHint("Closes the step screen. The procedure keeps running.")
                }
            }
            .sheet(isPresented: $takingPhoto) {
                PhoneCameraView(prompt: String(localized: "Photo for this step")) { data in
                    takingPhoto = false
                    let outcome = appState.jobPhotoEvidence.attach(imageData: data, origin: .phoneCamera)
                    problem = outcome.problem
                } onCancel: {
                    takingPhoto = false
                }
            }
        }
        .accessibilityIdentifier("procedure-step-screen")
    }

    // MARK: - The step

    private func content(_ p: ProcedureStepPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modeCard(p)
                // Plan JI §7a: talk-through, off by default, for this run.
                TalkThroughCard(service: appState.talkThrough)
                stepCard(p)
                if p.answer != nil || p.recorded != nil { answerCard(p) }
                routeCard(p)
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(OGTheme.warnLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("procedure-problem")
                }
                navigationButtons(p)
                if !p.trail.isEmpty { trailCard(p) }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: p.step.id) { _, _ in resetForNewStep() }
    }

    /// Whether the assistant or no model runs it, why, and the person's choice where it is theirs.
    @ViewBuilder
    private func modeCard(_ p: ProcedureStepPresentation) -> some View {
        if let procedure = sessions.activeProcedure {
            let decision = ProcedureRunModeEnvironment.decision(
                for: procedure, isOnline: appState.reachability.isOnline,
                personChoice: sessions.procedureRunModeChoice)
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(decision.line)
                        .font(.footnote)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    if decision.personCanChoose {
                        Toggle(isOn: Binding(
                            get: { sessions.procedureRunModeChoice == .noModel },
                            set: { sessions.procedureRunModeChoice = $0 ? .noModel : nil })) {
                            Text("Run without the assistant")
                                .font(.body)
                        }
                        .frame(minHeight: OGMetrics.minTouchTarget)
                        .accessibilityHint("The steps, the answers and the routes the rules decide stay the same. Nothing is sent to a model.")
                    }
                    if decision.mode == .noModel, !ProcedureRunModeEnvironment.supportsOnDeviceRecognition {
                        Text("Speech can't be recognised on this phone in this language, so answer on this screen.")
                            .font(.footnote)
                            .foregroundStyle(OGTheme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        Task { await appState.speakProcedureStep() }
                    } label: {
                        Label("Read the step aloud", systemImage: "speaker.wave.2")
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    }
                    .accessibilityHint("Says the step with the phone's own voice.")
                }
            }
        }
    }

    private func stepCard(_ p: ProcedureStepPresentation) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(p.position.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                    .accessibilityIdentifier("procedure-position")
                Text(p.step.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if p.trail.isEmpty {
                    ForEach(Array(p.safetyNotes.enumerated()), id: \.offset) { _, line in
                        safetyLine(line)
                    }
                }
                if let safety = p.step.safetyNote, !safety.isEmpty { safetyLine(safety) }
                Text(p.step.instruction)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func safetyLine(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(OGTheme.warnLabel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Safety: \(text)"))
    }

    // MARK: - The answer

    @ViewBuilder
    private func answerCard(_ p: ProcedureStepPresentation) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                if let pending = p.pendingReadBack {
                    readBack(pending)
                } else if let recorded = p.recorded {
                    recordedRow(p, recorded)
                    if p.needsCorrectiveNote { correctiveNote(recorded) }
                } else if let answer = p.answer {
                    control(answer, p)
                }
            }
        }
    }

    private func readBack(_ pending: PendingReadBack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            bigButton(String(localized: "Yes, that's right"), prominent: true) {
                run { try sessions.confirmProcedureReadBack(true) }
            }
            .accessibilityHint("Records the answer as it was read back.")
            bigButton(String(localized: "No, I'll give it again"), prominent: false) {
                run { try sessions.confirmProcedureReadBack(false) }
            }
            .accessibilityHint("Drops the answer so it can be given again.")
        }
    }

    private func recordedRow(_ p: ProcedureStepPresentation, _ recorded: RecordedProcedureAnswer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: recorded.value.specStatus == .out ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(recorded.value.specStatus == .out ? OGTheme.warnLabel : OGTheme.okLabel)
                    .accessibilityHidden(true)
                Text(p.recordedLine ?? "")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("procedure-recorded")
            }
            if let note = recorded.note {
                Text("Note: \(note)")
                    .font(.callout)
                    .foregroundStyle(OGTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entryMethodLine(recorded.method))
                .font(.caption)
                .foregroundStyle(OGTheme.secondaryLabel)
        }
        .accessibilityElement(children: .combine)
    }

    private func entryMethodLine(_ method: ProcedureAnswerMethod) -> String {
        switch method {
        case .typed: return String(localized: "Entered on the phone")
        case .spoken: return String(localized: "Said aloud")
        case .lens: return String(localized: "Chosen on the glasses")
        case .scanned: return String(localized: "Scanned")
        case .photo: return String(localized: "Photos from this step")
        }
    }

    private func correctiveNote(_ recorded: RecordedProcedureAnswer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ProcedureRunner.notePrompt(recorded))
                .font(.callout)
                .foregroundStyle(OGTheme.warnLabel)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $note, axis: .vertical) {
                Text("What was done about it")
            }
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .focused($fieldFocused)
            .accessibilityLabel("Corrective note")
            .accessibilityIdentifier("procedure-note-field")
            bigButton(String(localized: "Add the note"), prominent: true) {
                let words = note
                run { try sessions.answerProcedure(value: nil, method: .typed, note: words) }
            }
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityHint("Records the note with the reading. The run goes on once it has one.")
        }
    }

    @ViewBuilder
    private func control(_ answer: StepAnswer, _ p: ProcedureStepPresentation) -> some View {
        Text(answerHeading(answer))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
        if let hint = p.specHint {
            Text(hint)
                .font(.callout)
                .foregroundStyle(OGTheme.secondaryLabel)
                .accessibilityIdentifier("procedure-spec-hint")
        }
        switch answer.kind {
        case .number?:
            NumberPad(entry: $entry, unit: answer.unit, label: answer.displayLabel,
                      allowsNegative: (answer.plausibleRange?.lowerBound ?? 0) < 0)
            bigButton(String(localized: "Record \(answer.displayLabel)"), prominent: true) { recordEntry() }
                .disabled(entry.isEmpty)
                .accessibilityIdentifier("procedure-record")
        case .choice?, .yesNo?:
            ForEach(answer.buttons, id: \.id) { option in
                bigButton(option.label, prominent: false) {
                    run { try sessions.answerProcedure(value: option.id, method: .typed) }
                }
                .accessibilityLabel(String(localized: "\(answer.displayLabel): \(option.label)"))
            }
        case .text?, .code?:
            TextField(text: $entry, axis: answer.kind == .text ? .vertical : .horizontal) {
                Text(answer.kind == .code ? "Type the code" : "Type the answer")
            }
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .textInputAutocapitalization(answer.kind == .code ? .characters : .sentences)
            .autocorrectionDisabled(answer.kind == .code)
            .focused($fieldFocused)
            .accessibilityLabel(answer.displayLabel)
            bigButton(String(localized: "Record \(answer.displayLabel)"), prominent: true) { recordEntry() }
                .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .photo?:
            Text(p.photosSinceStep == 1
                 ? String(localized: "1 photo taken on this step.")
                 : String(localized: "\(p.photosSinceStep) photos taken on this step."))
                .font(.callout)
                .foregroundStyle(OGTheme.secondaryLabel)
            bigButton(String(localized: "Take a photo"), prominent: false) { takingPhoto = true }
                .accessibilityHint("Uses the phone's camera. The picture is filed against this job and attached to this step.")
            bigButton(String(localized: "Attach the photos"), prominent: true) {
                run { try sessions.answerProcedure(value: nil, method: .photo) }
            }
            .disabled(p.photosSinceStep == 0)
            .accessibilityHint("Attaches the photos taken since this step began. They are kept as evidence and not assessed.")
        case nil:
            EmptyView()
        }
    }

    private func answerHeading(_ answer: StepAnswer) -> String {
        let unit = answer.unit.map { " (\($0))" } ?? ""
        return String(localized: "\(answer.displayLabel)\(unit)")
    }

    private func recordEntry() {
        let typed = entry
        run { try sessions.answerProcedure(value: typed, method: .typed) }
    }

    // MARK: - The route

    @ViewBuilder
    private func routeCard(_ p: ProcedureStepPresentation) -> some View {
        let showsRule = p.ruleLine != nil
        let choices = p.routeChoices
        if showsRule || !choices.isEmpty || (p.offersOverride && p.pendingReadBack == nil) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    if let rule = p.ruleLine {
                        Text("The reading decides: \(rule).")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("procedure-rule-line")
                    }
                    if let reason = p.noRuleMatchedReason {
                        Text("\(reason). Choose the route.")
                            .font(.callout)
                            .foregroundStyle(OGTheme.warnLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !choices.isEmpty {
                        Text("Choose the route")
                            .font(.headline)
                    }
                    ForEach(choices) { branch in
                        bigButton(branch.condition, prominent: false) {
                            run { try sessions.advanceProcedure(choice: branch.id) }
                        }
                        .accessibilityHint("Takes this route to the next step.")
                    }
                    if p.offersOverride, p.noRuleMatchedReason == nil { overrideControls(p) }
                }
            }
        }
    }

    @ViewBuilder
    private func overrideControls(_ p: ProcedureStepPresentation) -> some View {
        if overriding {
            VStack(alignment: .leading, spacing: 10) {
                Text("Take another route")
                    .font(.headline)
                Picker(selection: $overrideBranch) {
                    Text("Choose a route").tag(String?.none)
                    ForEach(p.step.branches.filter { $0.id != p.ruleBranchId }) { branch in
                        Text(branch.condition).tag(Optional(branch.id))
                    }
                } label: {
                    Text("Route")
                }
                .pickerStyle(.inline)
                .accessibilityLabel("Route to take instead")
                TextField(text: $overrideReason, axis: .vertical) {
                    Text("Why — in your words")
                }
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityLabel("Reason for taking another route")
                .accessibilityIdentifier("procedure-override-reason")
                bigButton(String(localized: "Take this route"), prominent: true) {
                    guard let branch = overrideBranch else { return }
                    let reason = overrideReason
                    run { try sessions.overrideProcedure(branch: branch, reason: reason) }
                }
                .disabled(overrideBranch == nil || overrideReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("Goes on by this route. The override and your reason are on the record.")
                Button("Keep the rule's route") {
                    overriding = false
                    overrideBranch = nil
                    overrideReason = ""
                }
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
        } else {
            Button {
                overriding = true
            } label: {
                Text("Take another route…")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint("Overrides the rule, with your reason. It is flagged on the record.")
        }
    }

    // MARK: - Next and Back

    @ViewBuilder
    private func navigationButtons(_ p: ProcedureStepPresentation) -> some View {
        VStack(spacing: 10) {
            if p.step.needsConfirmation {
                bigButton(String(localized: "The check passed — finish"), prominent: true) {
                    finish(p, confirmed: true)
                }
                .accessibilityHint("Finishes the procedure with the check confirmed.")
                bigButton(String(localized: "Finish, the check is still to do"), prominent: false) {
                    finish(p, confirmed: false)
                }
                .accessibilityHint("Finishes the procedure and leaves the check open on the job.")
            } else if !(p.routeChoices.count > 1 && p.step.defaultNext == nil) {
                bigButton(p.step.terminal ? String(localized: "Finish") : String(localized: "Next"), prominent: true) {
                    run { try sessions.advanceProcedureAttachingPhotos() }
                }
                .accessibilityIdentifier("procedure-next")
                .accessibilityHint(p.step.terminal ? "Finishes the procedure." : "Goes on to the next step.")
            }
            if p.canGoBack {
                bigButton(String(localized: "Back"), prominent: false) {
                    run { try sessions.procedureBack() }
                }
                .accessibilityHint("Goes back to the step before. Its answer is given again.")
            }
        }
    }

    private func finish(_ p: ProcedureStepPresentation, confirmed: Bool) {
        do {
            _ = try sessions.completeProcedure(outcome: p.step.outcome ?? "resolved", confirmed: confirmed)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - The trail

    private func trailCard(_ p: ProcedureStepPresentation) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("So far")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(p.trail) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.id). \(entry.title)")
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = entry.answerLine {
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(entry.outOfSpec ? OGTheme.warnLabel : OGTheme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let note = entry.note {
                            Text("Note: \(note)")
                                .font(.footnote)
                                .foregroundStyle(OGTheme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Finished

    private var finished: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .accessibilityHidden(true)
            if let last = sessions.lastFinishedProcedure {
                Text("\(last.title) is finished.")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Outcome: \(last.outcome)")
                    .font(.callout)
                    .foregroundStyle(OGTheme.secondaryLabel)
            } else {
                Text("No procedure is running.")
                    .font(.title3.weight(.semibold))
            }
            bigButton(String(localized: "Done"), prominent: true) { dismiss() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// A full-width target big enough for a gloved finger.
    private func bigButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProcedureButtonStyle(prominent: prominent))
    }

    /// Run one of the session's procedure calls and show what it said.
    private func run(_ call: () throws -> Any) {
        do {
            let outcome = try call()
            if let result = outcome as? ProcedureRunner.AnswerResult {
                switch result {
                case .recorded, .needsNote:
                    problem = nil
                    entry = ""
                    note = ""
                case .readBack:
                    problem = nil
                case .askAgain(let line), .notAccepted(let line):
                    problem = line
                }
            } else {
                problem = nil
            }
            fieldFocused = false
        } catch {
            problem = error.localizedDescription
        }
    }

    private func resetForNewStep() {
        entry = ""
        note = ""
        overriding = false
        overrideBranch = nil
        overrideReason = ""
        problem = nil
    }
}

/// A big full-width procedure button: the accent fill for the step's main action, the card ground
/// with an accent outline for the others. At least 60 points tall, more as the text grows.
struct ProcedureButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.appAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 60

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return configuration.label
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: max(minHeight, 60))
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .overlay {
                if !prominent { shape.strokeBorder(isEnabled ? accent : Color.secondary.opacity(0.4), lineWidth: 2) }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }

    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(Color.secondary) }
        return prominent ? AnyShapeStyle(OGTheme.onAccentLabel(accent)) : AnyShapeStyle(OGTheme.tintedAccentLabel(accent))
    }

    private var background: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(Color(.quaternarySystemFill)) }
        return prominent ? AnyShapeStyle(accent) : AnyShapeStyle(OGTheme.card)
    }
}

/// The number pad for a number answer: big keys, the reading as typed with its unit beside it,
/// and the locale's own decimal separator.
private struct NumberPad: View {
    @Binding var entry: String
    let unit: String?
    let label: String
    let allowsNegative: Bool

    private var separator: String { Locale.current.decimalSeparator ?? "." }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.isEmpty ? "–" : entry)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.isEmpty ? OGTheme.secondaryLabel : Color(.label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .font(.title2)
                        .foregroundStyle(OGTheme.secondaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(entry.isEmpty
                                ? String(localized: "Nothing entered")
                                : (unit.map { "\(entry) \($0)" } ?? entry))
            .accessibilityIdentifier("procedure-number-display")

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { key("1"); key("2"); key("3") }
                GridRow { key("4"); key("5"); key("6") }
                GridRow { key("7"); key("8"); key("9") }
                GridRow {
                    if allowsNegative {
                        keyButton("±", spoken: String(localized: "Change sign", comment: "Number pad key that makes the reading negative or positive")) { toggleSign() }
                    } else {
                        keyButton(separator, spoken: String(localized: "Decimal point")) { addSeparator() }
                    }
                    key("0")
                    keyButton("⌫", spoken: String(localized: "Delete")) {
                        if !entry.isEmpty { entry.removeLast() }
                    }
                }
                if allowsNegative {
                    GridRow {
                        keyButton(separator, spoken: String(localized: "Decimal point")) { addSeparator() }
                            .gridCellColumns(3)
                    }
                }
            }
        }
    }

    private func key(_ digit: String) -> some View {
        keyButton(digit, spoken: digit) {
            guard entry.count < 12 else { return }
            entry += digit
        }
    }

    private func keyButton(_ face: String, spoken: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(face)
                .font(.title.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(.label))
        .background(OGTheme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(spoken)
    }

    private func addSeparator() {
        guard !entry.contains(separator) else { return }
        entry += entry.isEmpty || entry == "-" ? "0" + separator : separator
    }

    private func toggleSign() {
        if entry.hasPrefix("-") { entry.removeFirst() } else { entry = "-" + entry }
    }
}

/// The running procedure on the open job (Plan MN §4): where it is, and the way into its step
/// screen. Draws nothing with no procedure running — whether it was started here, by voice or on
/// the lens. The screen's sheet hangs on the job page, not here, so it stays up to show the end
/// of a run after this row has gone.
struct ActiveProcedureSection: View {
    @ObservedObject private var sessions = FieldSessionService.shared
    @Environment(\.appAccent) private var accent
    @Binding var showingStep: Bool

    var body: some View {
        if let p = sessions.activeProcedurePresentation {
            Section {
                Button {
                    showingStep = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.procedureTitle)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color(.label))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(p.position.text): \(p.step.title)")
                                .font(.subheadline)
                                .foregroundStyle(Color(.label))
                                .fixedSize(horizontal: false, vertical: true)
                            if let recorded = p.recordedLine {
                                Text(recorded)
                                    .font(.caption)
                                    .foregroundStyle(OGTheme.secondaryLabel)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: OGMetrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "\(p.procedureTitle). \(p.position.text): \(p.step.title)."))
                .accessibilityHint("Opens the step, with its answer and the way on.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("procedure-open-step")
            } header: {
                Text("Procedure")
            }
        }
    }
}
