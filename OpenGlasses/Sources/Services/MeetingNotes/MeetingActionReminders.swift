import Foundation

/// The Reminders side of an action item (Plan MX P5), behind a seam so adding once is tested
/// without EventKit. `EventKitDayStore` is the app's one EventKit owner, and its permission flow
/// (ask once, then read the setting) is the Reminders tool's.
@MainActor
protocol MeetingReminderSaving {
    func requestRemindersAccess() async throws -> Bool
    func saveReminder(title: String, dueDate: Date?, hasTime: Bool, notes: String?) throws
}

extension EventKitDayStore: MeetingReminderSaving {}

/// Adds one action item of a saved meeting summary to Reminders, once.
@MainActor
enum MeetingActionReminders {

    enum Outcome: Equatable {
        /// Added; the record as it is now saved.
        case added(MeetingActionItemsRecord)
        /// It was added before; nothing was created.
        case alreadyAdded
        /// Reminders access is off.
        case noAccess
        /// EventKit refused the save, or the note is gone.
        case failed
    }

    /// Add the item at `index` of the note with `meetingId`. The note is read again first, so a
    /// second press — or a second screen — finds it already added; it is marked added only once
    /// the reminder is saved.
    static func add(index: Int, meetingId: String, meetingTitle: String?, saver: MeetingReminderSaving,
                    defaults: UserDefaults = .standard, now: Date = Date()) async -> Outcome {
        guard let current = record(meetingId: meetingId, defaults: defaults) else { return .failed }
        guard current.canAdd(index) else { return .alreadyAdded }
        guard (try? await saver.requestRemindersAccess()) == true else { return .noAccess }
        // The permission sheet may have taken a while: read again before creating anything.
        guard var fresh = record(meetingId: meetingId, defaults: defaults), fresh.canAdd(index) else {
            return .alreadyAdded
        }
        let draft = MeetingReminderDraft.make(item: fresh.entries[index].item, meetingTitle: meetingTitle, now: now)
        do {
            try saver.saveReminder(title: draft.title, dueDate: draft.dueDate, hasTime: draft.dueDate != nil,
                                   notes: draft.notes)
        } catch {
            PrivacyLog.store(.meetingNotes, .writeFailed, detail: PrivacyToken("reminder"),
                             error: SafeErrorSummary(error))
            return .failed
        }
        fresh.markAdded(index)
        let encoded = fresh.encoded()
        let saved = SavedNotesStore.update(whereKey: MeetingActionItemsRecord.meetingIdKey, is: meetingId,
                                           defaults: defaults) { note in
            note[MeetingActionItemsRecord.noteKey] = encoded
        }
        PrivacyLog.store(.meetingNotes, .appended, count: 1, detail: PrivacyToken("reminder"))
        return saved ? .added(fresh) : .failed
    }

    /// The saved note's action items, read from the note itself.
    static func record(meetingId: String, defaults: UserDefaults = .standard) -> MeetingActionItemsRecord? {
        let note = SavedNotesStore.load(defaults: defaults)
            .first { $0[MeetingActionItemsRecord.meetingIdKey] == meetingId }
        return MeetingActionItemsRecord.decode(note?[MeetingActionItemsRecord.noteKey])
    }
}
