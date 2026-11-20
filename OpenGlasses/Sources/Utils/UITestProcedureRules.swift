#if DEBUG
import SwiftUI

/// Plan MN P3 — the procedure review screen on an invented procedure, for a screenshot.
///
/// **This whole file is behind `#if DEBUG`, so a Release binary contains none of it.** The
/// procedure's steps choose their routes from words, and a reply as an author's own AI might give
/// it (prose, a code fence, the JSON) is handed to the shipping screen and read by the shipping
/// parser, so each suggested rule shows beside its sentence. There is no vault behind it, so Save
/// has nowhere to write. Every name and number is invented.
struct UITestProcedureRules: View {

    static let procedure = Procedure(
        id: "fixture_tank_check", title: "Fixture tank check", version: "1.0.0",
        steps: [
            .init(id: "read_ph", title: "Read the pH", instruction: "Take a sample from the tank and read the pH meter.",
                  expectedInput: "The pH reading",
                  branches: [
                      .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "seal"),
                      .init(id: "high", condition: "pH above 4.4", next: "adjust"),
                      .init(id: "low", condition: "pH below 3.8", next: "hold"),
                  ]),
            .init(id: "adjust", title: "Adjust acid", instruction: "Add acid and read the pH again.", defaultNext: "read_ph"),
            .init(id: "seal", title: "Check the seal", instruction: "Look at the lid seal.",
                  branches: [
                      .init(id: "seal_ok", condition: "Seal looks fine", next: "done"),
                      .init(id: "seal_bad", condition: "Seal damaged or missing", next: "hold"),
                  ]),
            .init(id: "hold", title: "Hold the batch", instruction: "Tag the tank and call the supervisor.",
                  terminal: true, outcome: "escalated"),
            .init(id: "done", title: "Release", instruction: "Release the tank.", terminal: true, outcome: "resolved"),
        ])

    static let reply = """
    Here are the rules for your procedure:

    ```json
    {
      "steps": [
        {
          "step": "read_ph",
          "answer": { "record_as": "ph", "kind": "number", "label": "pH", "decimals": 2, "plausible": [0, 14], "spec": [3.8, 4.4] },
          "branches": [
            { "branch": "in_spec", "when": { "answer": "ph", "between": [3.8, 4.4] } },
            { "branch": "high", "when": { "answer": "ph", "gt": 4.4 } },
            { "branch": "low", "when": { "answer": "ph", "lt": 3.8 } }
          ]
        },
        {
          "step": "seal",
          "branches": [
            { "branch": "seal_ok", "when": { "answer": "seal", "is": "yes" } }
          ]
        }
      ]
    }
    ```
    """

    var body: some View {
        NavigationStack {
            ProcedureRulesView(vaultId: "", file: "fixture_tank_check.json", title: Self.procedure.title,
                               fixture: Self.procedure, fixturePaste: Self.reply)
        }
        .background(OGTheme.canvas.ignoresSafeArea())
    }
}
#endif
