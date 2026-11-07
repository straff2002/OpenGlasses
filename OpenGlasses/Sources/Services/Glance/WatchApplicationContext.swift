import Foundation

/// The rule every application-context push follows (Plans GM, KS).
///
/// The context is one dictionary and latest wins: a key a push leaves out is cleared on the watch.
/// So the status (with `job` while a job is open), the map cards (`surfaces`) and today's calendar
/// and weather (`today`) always travel together, and a value that is nil is *removed* rather than
/// left as whatever the base happened to carry. Pure.
enum WatchApplicationContext {

    static func fold(_ base: [String: Any], surfaces: Data?, today: Data?) -> [String: Any] {
        var context = base
        context[GlanceWire.contextKey] = surfaces
        context[WatchTodayWire.contextKey] = today
        return context
    }
}
