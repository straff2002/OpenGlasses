import SwiftUI

/// Settings → Everyday → Memory → Goals (Plan IW P2): the wearer's goals with their progress, each
/// opening its steps. Everything here can be read, changed and deleted; none of it needs Agent
/// Mode. Thin over `GoalsScreenModel`, which holds every rule.
struct GoalsView: View {
    @StateObject private var model: GoalsScreenModel
    @State private var showAdd = false

    init(model: @autoclosure @escaping () -> GoalsScreenModel) {
        _model = StateObject(wrappedValue: model())
    }

    /// The screen over the wearer's goals, acting through the running app.
    init() {
        self.init(model: GoalsScreenModel(store: .shared, environment: .live))
    }

    var body: some View {
        Form {
            if model.isUnreadable {
                Section {
                    OGNotice(text: "Your goals can't be opened right now. Unlock your iPhone and try again.")
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }

            if model.showsEmptyState {
                Section {
                    ContentUnavailableView {
                        Label("No goals yet", systemImage: "target")
                    } description: {
                        Text("Tell me something you want to get done, like \u{201C}make a goal: clear the garage by the twentieth\u{201D}, and I'll break it into steps and keep track of it with you.")
                    } actions: {
                        if model.canAdd {
                            Button("Add a goal") { showAdd = true }
                                .buttonStyle(.ogProminentCompact)
                        }
                    }
                }
            }

            let open = model.openGoals
            if !open.isEmpty {
                Section {
                    ForEach(open) { goal in
                        goalLink(goal)
                    }
                } header: {
                    Text("On the go")
                }
            }

            let finished = model.finishedGoals
            if !finished.isEmpty {
                Section {
                    ForEach(finished) { goal in
                        goalLink(goal)
                    }
                } header: {
                    Text("Finished")
                } footer: {
                    Text("Finished goals are kept for 90 days, then removed.")
                }
            }

            if !model.showsEmptyState {
                Section {
                    EmptyView()
                } footer: {
                    Text("Goals stay on this iPhone. Ask \u{201C}how's my goal going?\u{201D} or \u{201C}what's next?\u{201D} at any time.")
                }
            }
        }
        .navigationTitle("Goals")
        .ogFormStyle()
        .toolbar {
            if model.canAdd && !model.showsEmptyState {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a goal")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddGoalSheet(model: model)
        }
    }

    private func goalLink(_ goal: GoalsScreenModel.GoalSummary) -> some View {
        NavigationLink {
            GoalDetailView(model: model, goalID: goal.id)
        } label: {
            HStack(spacing: 12) {
                GoalProgressRing(fraction: goal.fraction, muted: goal.state != .active)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: goal.title)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "\(goal.progressText) · \(goal.status)")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A goal's progress as a ring: done steps over counted steps. Decorative — the row's text says
/// the same numbers, so VoiceOver reads those instead.
struct GoalProgressRing: View {
    let fraction: Double
    var muted = false
    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.quaternarySystemFill), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(muted ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(accent),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - One goal

/// One goal's page on its own — reached from a row elsewhere (an Activity entry, a My Day row)
/// rather than from the Goals list, so it owns its model.
struct GoalPage: View {
    let goalID: UUID
    @StateObject private var model = GoalsScreenModel(store: .shared, environment: .live)

    var body: some View {
        GoalDetailView(model: model, goalID: goalID)
    }
}

/// One goal's page: its steps with Done, Skip and the step's own offer, the check-in picker, its
/// details, and pause, finish, set aside or delete.
struct GoalDetailView: View {
    @ObservedObject var model: GoalsScreenModel
    let goalID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var newStep = ""
    @State private var renamingStep: GoalStep?
    @State private var stepTitleDraft = ""
    @State private var titleDraft = ""
    @State private var whyDraft = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let goal = model.goal(goalID) {
                content(goal)
            } else {
                ContentUnavailableView("This goal is gone", systemImage: "target",
                                       description: Text("It was deleted, or finished long enough ago to be removed."))
            }
        }
        .navigationTitle(model.goal(goalID)?.title ?? String(localized: "Goal", comment: "Goal page title fallback."))
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }

    @ViewBuilder
    private func content(_ goal: Goal) -> some View {
        let summary = model.summary(goal)
        Form {
            Section {
                HStack(spacing: 14) {
                    GoalProgressRing(fraction: summary.fraction, muted: goal.state != .active)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: summary.progressText)
                            .font(.headline)
                        Text(verbatim: summary.status)
                            .font(.footnote)
                            .foregroundStyle(OGTheme.secondaryLabel)
                    }
                }
                .accessibilityElement(children: .combine)
                if let why = goal.why {
                    Text(verbatim: why)
                        .font(.body)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            stepsSection(goal)
            checkInSection(goal)
            detailsSection(goal)
            actionsSection(goal)
        }
        .alert("Goal", isPresented: Binding(get: { model.runResult != nil },
                                            set: { if !$0 { model.runResult = nil } })) {
            Button("OK") { model.runResult = nil }
        } message: {
            Text(verbatim: model.runResult ?? "")
        }
        .alert("Rename step", isPresented: Binding(get: { renamingStep != nil },
                                                   set: { if !$0 { renamingStep = nil } })) {
            TextField("Step", text: $stepTitleDraft)
            Button("Save") {
                if let step = renamingStep { model.renameStep(step.id, of: goalID, to: stepTitleDraft) }
                renamingStep = nil
            }
            Button("Cancel", role: .cancel) { renamingStep = nil }
        }
        .confirmationDialog("Delete this goal?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete goal", role: .destructive) {
                model.delete(goalID)
                dismiss()
            }
        } message: {
            Text("Its steps and check-ins go too. This can't be undone.")
        }
    }

    // MARK: Steps

    private func stepsSection(_ goal: Goal) -> some View {
        Section {
            ForEach(model.steps(of: goalID)) { row in
                stepRow(row, goal: goal)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            model.removeStep(row.id, from: goalID)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        Button {
                            stepTitleDraft = row.title
                            renamingStep = goal.steps.first { $0.id == row.id }
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
            }
            HStack {
                TextField("Add a step", text: $newStep)
                    .submitLabel(.done)
                    .onSubmit(addStep)
                Button("Add", action: addStep)
                    .buttonStyle(.borderless)
                    .disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Swipe a step to rename or remove it. I only do a step's suggestion when you press it, and you're asked first wherever you usually would be.")
        }
    }

    private func addStep() {
        if model.addStep(newStep, to: goalID) { newStep = "" }
    }

    @ViewBuilder
    private func stepRow(_ row: GoalsScreenModel.StepRow, goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: stepSymbol(row))
                    .foregroundStyle(row.state == .done ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title)
                        .font(.body)
                        .strikethrough(row.state == .skipped)
                        .fixedSize(horizontal: false, vertical: true)
                    let status = [row.isNext ? String(localized: "Next", comment: "Goals screen: the next step.") : nil,
                                  row.status].compactMap { $0 }
                    if !status.isEmpty {
                        Text(verbatim: status.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(OGTheme.secondaryLabel)
                    }
                    if let question = row.question {
                        Text(verbatim: question)
                            .font(.footnote)
                            .foregroundStyle(OGTheme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            stepButtons(row, goal: goal)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stepButtons(_ row: GoalsScreenModel.StepRow, goal: Goal) -> some View {
        if row.state.isActionable {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { stepButtonSet(row) }
                VStack(alignment: .leading, spacing: 8) { stepButtonSet(row) }
            }
            if case .blocked(_, let reason) = row.offer {
                Text(verbatim: reason)
                    .font(.footnote)
                    .foregroundStyle(OGTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Button("Reopen") { model.setStep(row.id, of: goalID, to: .open) }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Reopen \(row.title)"))
        }
    }

    @ViewBuilder
    private func stepButtonSet(_ row: GoalsScreenModel.StepRow) -> some View {
        switch row.offer {
        case .runnable(let title):
            Button {
                Task { await model.doIt(row.id, of: goalID) }
            } label: {
                if model.runningStepID == row.id {
                    ProgressView()
                } else {
                    Text(verbatim: title)
                }
            }
            .buttonStyle(.ogProminentCompact)
            .disabled(model.runningStepID != nil)
            .accessibilityLabel(Text(verbatim: "\(title), \(row.title)"))
        case .blocked(let title, _):
            Button {} label: { Text(verbatim: title) }
                .buttonStyle(.ogProminentCompact)
                .disabled(true)
        case .none:
            EmptyView()
        }
        Button("Done") { model.setStep(row.id, of: goalID, to: .done) }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Mark \(row.title) done"))
        Button("Skip") { model.setStep(row.id, of: goalID, to: .skipped) }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Skip \(row.title)"))
    }

    private func stepSymbol(_ row: GoalsScreenModel.StepRow) -> String {
        switch row.state {
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .open, .next: return row.isNext ? "arrow.forward.circle" : "circle"
        }
    }

    // MARK: Check-ins

    private func checkInSection(_ goal: Goal) -> some View {
        Section {
            Picker("Check in", selection: Binding(
                get: { goal.checkIn },
                set: { model.setCadence($0, for: goalID) }
            )) {
                ForEach(model.cadenceChoices(for: goalID), id: \.codeValue) { cadence in
                    Text(verbatim: GoalsScreenModel.cadenceLabel(cadence)).tag(cadence)
                }
            }
            if let note = model.checkInNote(for: goalID) {
                Text(verbatim: note)
                    .font(.footnote)
                    .foregroundStyle(OGTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Check-ins")
        } footer: {
            Text("A check-in is one sentence when you're wearing your glasses, and a line in your digest otherwise — at most two goal check-ins a day.")
        }
    }

    // MARK: Details

    private func detailsSection(_ goal: Goal) -> some View {
        Section {
            TextField("Name", text: $titleDraft)
                .submitLabel(.done)
                .onSubmit(commitDetails)
            TextField("Why it matters (optional)", text: $whyDraft)
                .submitLabel(.done)
                .onSubmit(commitDetails)
            Toggle("Due date", isOn: Binding(
                get: { goal.dueAt != nil },
                set: { on in
                    model.setDue(goalID, to: on ? Calendar.current.date(byAdding: .day, value: 7, to: Date()) : nil)
                }
            ))
            if let due = goal.dueAt {
                DatePicker("Due by", selection: Binding(
                    get: { due },
                    set: { model.setDue(goalID, to: $0) }
                ), in: Date()..., displayedComponents: .date)
            }
        } header: {
            Text("Details")
        }
        .onAppear {
            titleDraft = goal.title
            whyDraft = goal.why ?? ""
        }
        .onDisappear(perform: commitDetails)
    }

    /// Keep the typed name and reason. A name that is empty or too long is not kept; the field
    /// goes back to the stored one.
    private func commitDetails() {
        guard let goal = model.goal(goalID) else { return }
        if titleDraft != goal.title, !model.rename(goalID, to: titleDraft) { titleDraft = goal.title }
        if whyDraft != (goal.why ?? ""), !model.setWhy(goalID, to: whyDraft) { whyDraft = goal.why ?? "" }
    }

    // MARK: Goal actions

    @ViewBuilder
    private func actionsSection(_ goal: Goal) -> some View {
        Section {
            switch goal.state {
            case .active:
                Button("Pause") { model.setState(.paused, for: goalID) }
                Button("Mark the goal done") { model.setState(.done, for: goalID) }
                Button("Set it aside") { model.setState(.abandoned, for: goalID) }
            case .paused:
                Button("Pick it back up") { model.setState(.active, for: goalID) }
                Button("Mark the goal done") { model.setState(.done, for: goalID) }
                Button("Set it aside") { model.setState(.abandoned, for: goalID) }
            case .done, .abandoned:
                Button("Pick it back up") { model.setState(.active, for: goalID) }
            }
            Button("Delete goal", role: .destructive) { confirmDelete = true }
        }
    }
}

extension CheckInCadence: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(codeValue) }
}

// MARK: - Adding a goal

/// A goal typed in rather than spoken. Hidden when the `goals` tool is off or an organisation
/// closed it; the list stays.
struct AddGoalSheet: View {
    @ObservedObject var model: GoalsScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GoalsScreenModel.NewGoal()
    @State private var hasDue = false
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to get done?", text: $draft.title, axis: .vertical)
                    TextField("Why it matters (optional)", text: $draft.why, axis: .vertical)
                }
                Section {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Due by", selection: $due, in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    Text("With a due date, I'll check in two days before it. You can change that on the goal.")
                }
                Section {
                    ForEach(draft.steps.indices, id: \.self) { index in
                        TextField("Step \(index + 1)", text: $draft.steps[index])
                    }
                    if draft.steps.count < GoalsScreenModel.maximumSteps {
                        Button("Add another step") { draft.steps.append("") }
                    }
                } header: {
                    Text("Steps")
                }
                if let problem {
                    Section {
                        OGNotice(text: problem, systemImage: "exclamationmark.circle")
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
            }
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .ogFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        draft.dueAt = hasDue ? due : nil
        switch model.add(draft) {
        case .added:
            dismiss()
        case .invalid(let reason):
            problem = reason
        case .full:
            problem = String(localized: "You have fifty goals already. Finish one or set one aside first.",
                             comment: "Goals screen: the goal store is full.")
        case .unavailable:
            problem = String(localized: "Goals can't be saved right now.", comment: "Goals screen: the store is unavailable.")
        }
    }
}
