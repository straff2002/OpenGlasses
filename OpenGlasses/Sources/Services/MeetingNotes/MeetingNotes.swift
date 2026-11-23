import Foundation

/// The notes of one meeting as the model wrote them (Plan MX P4): a short title, an overview, what
/// was explicitly agreed, and what someone committed to doing. Pure values, so the prompt, the
/// parsing and the checks against the transcript are all tested headlessly.
///
/// Many meetings have no decisions and no action items; empty lists are the honest answer, and
/// what the keyword extraction this replaces could never give (any "should" or "will" became an
/// action item).
struct MeetingNotes: Codable, Equatable, Sendable {
    var title: String
    var overview: String
    var decisions: [String]
    var actionItems: [MeetingActionItem]

    init(title: String = "", overview: String = "", decisions: [String] = [],
         actionItems: [MeetingActionItem] = []) {
        self.title = title
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
    }

    /// Nothing worth showing came back.
    var isEmpty: Bool {
        title.isEmpty && overview.isEmpty && decisions.isEmpty && actionItems.isEmpty
    }
}

/// One thing someone committed to doing. `owner` and `due` are the words said in the meeting,
/// kept only when they appear in the transcript (`MeetingNotesVerifier`).
struct MeetingActionItem: Codable, Equatable, Hashable, Sendable {
    var task: String
    var owner: String?
    var due: String?

    init(task: String, owner: String? = nil, due: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
    }

    /// What a list, the saved note, the spoken summary and a prepared card's draft read:
    /// "Send the revised budget (Ana, by Friday)". The task alone when neither was said.
    var readable: String {
        var extras: [String] = []
        if let owner, !owner.isEmpty { extras.append(owner) }
        if let due, !due.isEmpty { extras.append(Self.duePhrase(due)) }
        guard !extras.isEmpty else { return task }
        return "\(task) (\(extras.joined(separator: ", ")))"
    }

    /// Words a due already starts with, so "by Friday" is not read as "by by Friday".
    private static let dueLeads: Set<String> = [
        "by", "before", "until", "till", "on", "in", "at", "next", "this", "within", "after",
        "end", "tomorrow", "today", "tonight", "asap",
    ]

    static func duePhrase(_ due: String) -> String {
        let first = due.split(separator: " ").first.map { $0.lowercased() } ?? ""
        // Only an English due gets the "by"; a due in another language stays as it was said.
        let isASCII = due.unicodeScalars.allSatisfy { $0.isASCII }
        return dueLeads.contains(first) || !isASCII ? due : "by \(due)"
    }
}

/// Which notes a summary carries: the model's, or the phone's keyword extraction (the fallback).
enum MeetingNotesSource: String, Codable, Sendable {
    case model
    case phone
}
