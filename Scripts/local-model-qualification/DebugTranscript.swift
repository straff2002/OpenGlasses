import Foundation

/// Debug only (`--transcripts`): each tool-turn generation's raw text and parsed calls, one JSON
/// line each, in Documents/debug-transcripts.jsonl. It exists to tell "the model answered in words"
/// from "the model called and the parser missed it" while a qualification run is being brought up.
///
/// It is not the record. The corpus is synthetic plus the committed example vault, so the file holds
/// no personal data, but it does hold turns and model text: copy it to a scratch folder to read,
/// never into `reports/` or git, and leave the flag off for a run whose record is kept. The file is
/// started over on every launch that sets the flag.
final class DebugTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("debug-transcripts.jsonl")
        try? Data().write(to: url, options: .atomic)
    }

    func write(caseID: String, turn: String, offered: [String], kept: [String]?, expected: [String],
               text: String, calls: [(String, [String: Any])], pass: Int) {
        let row: [String: Any] = [
            "case": caseID, "turn": turn, "pass": pass, "offered": offered, "kept": kept ?? offered,
            "expected": expected, "text": text,
            "calls": calls.map { ["name": $0.0, "arguments": $0.1] as [String: Any] },
        ]
        append(row)
    }

    /// A manual reading: the reply, what the case expects, and the check's verdict.
    func writeReading(caseID: String, turn: String, text: String, expectedAccepted: Bool, verdict: String) {
        append(["case": caseID, "turn": turn, "kind": "reading", "text": text,
                "expectedAccepted": expectedAccepted, "verdict": verdict])
    }

    private func append(_ row: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(row),
              var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
