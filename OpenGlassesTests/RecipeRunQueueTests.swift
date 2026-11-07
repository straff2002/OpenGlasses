import XCTest
@testable import OpenGlasses

/// One run at a time per add-on; two may wait; a further call is busy at once. No sleeps: runs
/// are held open on a gate the test releases, and the test yields until the queue reaches the
/// state it is waiting for.
final class RecipeRunQueueTests: XCTestCase {

    /// A one-shot latch a run awaits until the test opens it.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Records the order runs start in.
    private actor Log {
        private(set) var entries: [String] = []
        func add(_ s: String) { entries.append(s) }
    }

    private func until(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    func testOneRunAtATimeTwoWaitThenBusy() async {
        let queue = RecipeRunQueue()
        let gate = Gate()
        let log = Log()

        let first = Task { await queue.run(addOnID: "a") { await log.add("1"); await gate.wait(); return 1 } }
        await until { await queue.isRunning("a") }

        let second = Task { await queue.run(addOnID: "a") { await log.add("2"); return 2 } }
        await until { await queue.waitingCount(for: "a") == 1 }
        let third = Task { await queue.run(addOnID: "a") { await log.add("3"); return 3 } }
        await until { await queue.waitingCount(for: "a") == 2 }

        // A fourth call while one runs and two wait is refused straight away.
        let fourth = await queue.run(addOnID: "a") { await log.add("4"); return 4 }
        guard case .busy = fourth else { return XCTFail("expected busy") }
        let started = await log.entries
        XCTAssertEqual(started, ["1"], "nothing else started while the first run holds the add-on")

        await gate.release()
        let results = [await first.value, await second.value, await third.value].map { admission -> Int? in
            if case .ran(let v) = admission { return v }
            return nil
        }
        XCTAssertEqual(results, [1, 2, 3])
        let order = await log.entries
        XCTAssertEqual(order, ["1", "2", "3"], "waiters run in arrival order")
        let running = await queue.isRunning("a")
        XCTAssertFalse(running)
        let waiting = await queue.waitingCount(for: "a")
        XCTAssertEqual(waiting, 0)
    }

    func testDifferentAddOnsDoNotWaitForEachOther() async {
        let queue = RecipeRunQueue()
        let gate = Gate()
        let held = Task { await queue.run(addOnID: "a") { await gate.wait(); return "a" } }
        await until { await queue.isRunning("a") }

        let other = await queue.run(addOnID: "b") { "b" }
        guard case .ran("b") = other else { return XCTFail("b should run while a is busy") }

        await gate.release()
        guard case .ran("a") = await held.value else { return XCTFail() }
    }

    func testTheAddOnIsFreeAgainAfterARun() async {
        let queue = RecipeRunQueue()
        for i in 0..<5 {
            guard case .ran(let v) = await queue.run(addOnID: "a", { i }) else { return XCTFail() }
            XCTAssertEqual(v, i)
        }
        let running = await queue.isRunning("a")
        XCTAssertFalse(running)
    }
}
