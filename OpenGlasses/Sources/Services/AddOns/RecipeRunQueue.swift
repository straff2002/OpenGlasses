import Foundation

/// One run at a time per add-on. A call that arrives while that add-on is running waits its turn
/// (first come, first served); at most `maxWaiting` may wait, and a further call is told "busy"
/// at once rather than piling up. Different add-ons never wait for each other.
actor RecipeRunQueue {

    enum Admission<Value: Sendable>: Sendable {
        case ran(Value)
        case busy
    }

    static let maxWaiting = 2

    private var running: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    init() {}

    /// Run `body` for `addOnID` once it is that add-on's turn, or return `.busy` straight away when
    /// the add-on already has a run going and `maxWaiting` calls queued behind it.
    func run<Value: Sendable>(addOnID: String, _ body: @Sendable () async -> Value) async -> Admission<Value> {
        if running.contains(addOnID) {
            guard waiting[addOnID, default: []].count < Self.maxWaiting else { return .busy }
            // `finish` hands the add-on straight to the first waiter, so it stays marked running.
            await withCheckedContinuation { continuation in
                waiting[addOnID, default: []].append(continuation)
            }
        } else {
            running.insert(addOnID)
        }
        let value = await body()
        finish(addOnID)
        return .ran(value)
    }

    private func finish(_ addOnID: String) {
        if var queue = waiting[addOnID], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[addOnID] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            running.remove(addOnID)
        }
    }

    func isRunning(_ addOnID: String) -> Bool { running.contains(addOnID) }
    func waitingCount(for addOnID: String) -> Int { waiting[addOnID]?.count ?? 0 }
}
