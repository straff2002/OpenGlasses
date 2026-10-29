import Foundation

/// `Date <=` and `Date >=`, defined here so the app never calls Foundation's.
///
/// The iOS 27.2 SDK marks both operators `@backDeployed(before: iOS 27.2)`. A call site compiles
/// to a thunk: below 27.2 it runs an inlined copy, at 27.2 and above it calls Foundation's exported
/// symbol, which the app imports weakly. The early iOS 27.2 betas (24B5084k, 24B5089g) report 27.2
/// but do not export that symbol, so the thunk jumps to address zero — `EXC_BAD_ACCESS`,
/// `CODESIGNING 2 Invalid Page` — and the first comparison at launch (`RetentionScheduler.isDue`,
/// `DiagnosticBreadcrumbStore.retained`) killed the app before its first frame, every launch.
///
/// Inside this module these declarations shadow Foundation's identical ones, so every `<=`/`>=` on
/// two dates in app code resolves here and the binary carries no weak import of either. Both are
/// written in terms of `<`, which is not back-deployed. `@_disfavoredOverload` matters only to a
/// module that imports this one (the test bundle, through `@testable import`): it sees both
/// declarations, and without the attribute every date comparison there is ambiguous; with it,
/// Foundation's wins there, which is harmless because tests never run on a 27.2 beta. Generic
/// code (`max()`, `sorted()`, `ClosedRange<Date>`) uses Foundation's own `Comparable` witness in
/// the OS and was never affected.
///
/// Check with `nm -m` on a Release binary: no `weak external` `Foundation.Date` symbol should
/// remain. Safe to delete once the deployment target is iOS 27.2 or later.
extension Date {
    @_disfavoredOverload
    static func <= (lhs: Date, rhs: Date) -> Bool { !(rhs < lhs) }
    @_disfavoredOverload
    static func >= (lhs: Date, rhs: Date) -> Bool { !(lhs < rhs) }
}
