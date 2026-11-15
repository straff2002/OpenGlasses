import SwiftUI

/// Shared by the home quick action and each conversation's selection strip.
struct ManualPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ConversationStore
    let threadID: String?
    @ObservedObject private var library = PersonalManualLibrary.shared
    @State private var selected = Set<String>()
    @State private var loadedSelection = false
    @State private var notice: String?
    @State private var reading: PersonalManualLibrary.Manual?
    @State private var managing = false
    @AppStorage("myManualsEnabled") private var answersEnabled = true

    private var missing: Set<String> { selected.subtracting(library.available.map(\.id)) }

    var body: some View {
        NavigationStack {
            List {
                if PersonalManualLibrary.canManage {
                    Section {
                        if library.available.isEmpty {
                            Text("Add your manuals, then choose which ones to use in this chat.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(library.available) { manual in
                            Button {
                                if selected.contains(manual.id) { selected.remove(manual.id) }
                                else { selected.insert(manual.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(manual.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(manual.id) ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(manual.document.title).foregroundStyle(.primary)
                                        Text(library.isIndexed(manual) ? (manual.document.personalReadingCopy == true ? "Ready · text reading copy" : "Ready") : "Needs indexing in Manage manuals")
                                            .font(.caption).foregroundStyle(.secondary)
                                        // The publisher/source and stable suffix distinguish duplicate titles.
                                        Text(manual.manifest.name + " · " + manual.label.suffix(10))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(manual.document.title)
                            .accessibilityValue(selected.contains(manual.id) ? "Selected" : "Not selected")
                            .accessibilityHint("Double-tap to change selection. Open the actions menu to read the manual.")
                            .contextMenu { Button("Read manual") { reading = manual } }
                            .accessibilityAction(named: "Read manual") { reading = manual }
                        }
                        if !missing.isEmpty {
                            Button("Remove unavailable selections (\(missing.count))") { selected.subtract(missing) }
                        }
                    } header: {
                        Text(selected.count == 1 ? "1 manual selected" : "\(selected.count) manuals selected")
                    } footer: {
                        Text("Choose one or more books, such as workshop and electrical manuals for the same car. Answers search your selection and cite each book and page separately. With no selection, name a manual in your question.")
                    }
                    if !answersEnabled {
                        Section {
                            Toggle("Use my manuals in answers", isOn: $answersEnabled)
                        } footer: {
                            Text(MyManualsPaywallCopy.disclosure)
                        }
                    }
                    Section {
                        Button("Clear selection") { selected.removeAll() }.disabled(selected.isEmpty)
                        Button("Manage manuals") { managing = true }
                    }
                } else {
                    Text("My Manuals is unavailable in the current mode. Your organisation or Field Assist session manages its own manuals.")
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            }
            .navigationTitle("My Manuals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: apply)
                        .disabled(!PersonalManualLibrary.canManage || store.isLocked || appState.isProcessing || appState.llmService.isProcessing || !missing.isEmpty)
                }
            }
            .onAppear {
                guard !loadedSelection else { return }
                loadedSelection = true
                selected = Set(store.threads.first { $0.id == threadID }?.manualIDs ?? [])
            }
            .sheet(isPresented: $managing) {
                NavigationStack {
                    MyManualsView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { managing = false } } }
                }
            }
            .sheet(item: $reading) { manual in
                NavigationStack {
                    PersonalManualPDFView(url: PersonalManualLibrary.canManage ? manual.pdf : nil)
                        .navigationTitle(manual.document.title)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { reading = nil } } }
                }
            }
        }
    }

    private func apply() {
        guard PersonalManualLibrary.canManage, !store.isLocked, !appState.isProcessing,
              !appState.llmService.isProcessing, missing.isEmpty else { return }
        // Plan LU P1b: a private conversation starts no thread, and changes none it isn't in.
        guard !appState.privateConversation.isActive else {
            notice = PrivateConversationLines.noManualsWhilePrivate
            return
        }
        var id = threadID
        if id == nil {
            guard store.activeThreadId == nil else {
                notice = String(localized: "The conversation changed. Close this picker and choose manuals again.")
                return
            }
            if selected.isEmpty { dismiss(); return }
            id = store.startThread(mode: appState.currentMode.rawValue, personaId: appState.activePersona?.id).id
        }
        guard let id, store.setManualIDs(Array(selected), for: id) else {
            notice = String(localized: "This conversation is unavailable. Close this picker and try again.")
            return
        }
        library.selectionDidChange()
        dismiss()
    }
}

struct ManualSelectionButton: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: ConversationStore
    let threadID: String?
    @ObservedObject private var library = PersonalManualLibrary.shared
    @AppStorage("myManualsEnabled") private var answersEnabled = true

    private var ids: [String] { store.threads.first { $0.id == threadID }?.manualIDs ?? [] }
    private var titles: String {
        library.manuals.filter { ids.contains($0.id) }.map(\.document.title).joined(separator: ", ")
    }
    private var label: String {
        if !answersEnabled { return String(localized: "Manual answers off") }
        if ids.isEmpty { return String(localized: "Choose manuals") }
        guard ids.count == 1 else { return String(localized: "\(ids.count) manuals selected") }
        return titles.isEmpty ? String(localized: "Selected manual unavailable") : titles
    }

    var body: some View {
        // Plan LU P1b: not in a private conversation. It has no thread to keep a choice on, and
        // the stored thread under it is not the one being talked in.
        if PersonalManualLibrary.canManage, !appState.privateConversation.isActive {
            Button {
                appState.manualPickerThreadID = threadID
                appState.showManualPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
                        if ids.count > 1 { Text(titles).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isLocked || appState.isProcessing || appState.llmService.isProcessing)
            .accessibilityLabel("My Manuals, \(label)")
            .accessibilityHint("Choose one or more manuals for this chat.")
        }
    }
}
