import SwiftUI

/// Whether a list's rows would share an id. Pure.
///
/// Two rows of one `ForEach` with the same id make UIKit's list update assert ("invalid number of
/// items in section"), which is how build 688 crashed. `RowIdentityGuardTests` stops a new
/// text-keyed loop reaching a list unexamined; this is the run-time half, for the lists whose data
/// is not constant.
enum RowIdentity {
    /// How many rows repeat an id already used by an earlier row: zero when every id is distinct.
    static func repeats<ID: Hashable>(in ids: [ID]) -> Int {
        var seen = Set<ID>()
        var repeated = 0
        for id in ids where !seen.insert(id).inserted { repeated += 1 }
        return repeated
    }
}

extension View {
    /// Log `listRowsRepeated` with this screen's token and the count when `ids` repeats one —
    /// never the ids themselves. It never changes what is shown: a list keyed by position stays
    /// safe whatever it holds, and this only says that the data behind it repeats.
    func uniqueRowsCheck<ID: Hashable>(_ ids: [ID], file: StaticString = #fileID) -> some View {
        let count = RowIdentity.repeats(in: ids)
        return onAppear { RowIdentityReporter.report(count, file: file) }
            .onChange(of: count) { _, newCount in RowIdentityReporter.report(newCount, file: file) }
    }
}

/// The run-time event, kept apart from the view so the token rule is the same as
/// `diagnosticScreen`'s: the call site's file name, fixed code vocabulary.
enum RowIdentityReporter {
    static func report(_ count: Int, file: StaticString) {
        guard count > 0 else { return }
        PrivacyLog.app(.listRowsRepeated, detail: screenToken(file), count: count)
    }

    static func screenToken(_ file: StaticString) -> PrivacyToken {
        let name = String(describing: file).split(separator: "/").last ?? "unknown"
        return PrivacyToken(String(name))
    }
}
