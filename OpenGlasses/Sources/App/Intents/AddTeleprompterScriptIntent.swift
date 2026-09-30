import AppIntents

/// Import a teleprompter script from anywhere text lives, via the Shortcuts app:
/// *Find Notes / Reminders / Files → OpenGlasses: Add Teleprompter Script*. This is the
/// confirmed pull-only path for Apple Notes (iOS has no public API to read Notes directly).
///
/// The text is a free-form `String` parameter, which is fine for an App Intent **invoked
/// from the Shortcuts app** — it only breaks when interpolated into a *spoken* AppShortcut
/// phrase, so this intent is intentionally **not** registered in `OpenGlassesShortcuts`.
struct AddTeleprompterScriptIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Teleprompter Script"
    static var description = IntentDescription(
        "Save text — for example from a note, a reminder, or a file — as a teleprompter script in Avenkin."
    )

    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { true }

    @Parameter(
        title: "Script Text",
        description: "The script to save",
        requestValueDialog: "What's the script text?"
    )
    var text: String

    @Parameter(title: "Title", description: "Optional name for the script")
    var title: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let appState = try await IntentSupport.awaitConnectedAppState()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentError.emptyScript }

        let saved = appState.teleprompterStore.add(title: title ?? "", text: trimmed)
        let dialog = "Saved teleprompter script \u{201C}\(saved.title)\u{201D}."
        return .result(value: saved.title, dialog: IntentDialog(stringLiteral: dialog))
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case emptyScript

        var localizedStringResource: LocalizedStringResource {
            "The script text was empty."
        }
    }
}
