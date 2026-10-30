import Foundation
@testable import OpenGlasses

/// The invented `chains.md` of Plan JJ P2's test vault — the same text as the vault guide's
/// "Tables and chains" example, which a test holds them to. Every table, rule number, designation,
/// band and value is made up ("Table 99", "Rule QR-17", "QMX90"); nothing is a fact from any book.
enum RuleChainFixtures {

    static let chainsMarkdown = """
    # Rule chains

    Invented for the example: every table, rule and value here is made up.

    ## Size a conductor for a load
    Answers: which conductor carries a load once it is corrected for the ambient temperature and the conductors grouped in the run.

    ```chain
    ask load (A) range 1..400: What load will the circuit carry, in amps?
    ask ambient (°C) range 0..40: What is the ambient temperature along the run?
    ask conductors (conductors) range 1..9: How many current-carrying conductors share the run?
    ask group range 1..3: Which rating group is the installation method in?
    lookup band = Table 90 row {conductors} column Band rule exact
    cite Rule QR-12
    lookup factor = Table 98 row {ambient} column Rating group {group} › {band} rule at_least
    cite Rule QR-14
    calc corrected (A) = load / factor
    lookup size = Table 99 column Rating group {group} cell {corrected} rule at_least
    cite Rule QR-17
    say "Use {size.row}: rated {size} A in rating group {group}, against {corrected} A once the load is divided by the factor of {factor} ({factor.table}, {factor.page})."
    ```

    ## Check an installed conductor
    Answers: whether a conductor already installed carries a load, after the same correction.

    ```chain
    ask size (text): Which conductor is installed, by its designation and number of conductors?
    ask load (A) range 1..400: What load does the circuit carry, in amps?
    ask ambient (°C) range 0..40: What is the ambient temperature along the run?
    ask conductors (conductors) range 1..9: How many current-carrying conductors share the run?
    ask group range 1..3: Which rating group is the installation method in?
    lookup band = Table 90 row {conductors} column Band rule exact
    cite Rule QR-12
    lookup factor = Table 98 row {ambient} column Rating group {group} › {band} rule at_least
    cite Rule QR-14
    lookup rating = Table 99 row {size} column Rating group {group} rule exact
    cite Rule QR-17
    calc capacity (A) = rating * factor
    check capacity >= load ? "{rating.row} carries it: {capacity} A once corrected, against a load of {load} A." : "{rating.row} does not carry it: {capacity} A once corrected, against a load of {load} A. The next row is {rating.next}."
    ```

    ## Voltage drop on a run
    Answers: the voltage drop along a run as a share of the supply, against the limit this example sets.

    ```chain
    ask size (text): Which size is the run, as the table prints it?
    ask current (A) range 1..400: What current does the run carry, in amps?
    ask length (ft) range 1..2000: How long is the run, one way, in feet?
    convert metres = length to m
    lookup drop = Table 97 row {size} column Drop rule exact
    cite Rule QR-30
    calc volts (V) = drop * current * metres / 100
    ask supply (V) range 50..1000: What is the supply voltage?
    calc percent (%) = volts / supply * 100
    check percent <= 4.5 ? "The drop is {volts} V, {percent} % of {supply} V: within the 4.5 % this example allows." : "The drop is {volts} V, {percent} % of {supply} V: over the 4.5 % this example allows, so a larger size or a shorter run is needed."
    ```
    """

    /// The tables the chains read, extracted from the invented layouts as an import would — Table
    /// 99 printed as page 12 on PDF page 2, Table 98 on page 3, Table 97 on page 4, Table 90 on
    /// page 5 — and a Table 92 whose caption was found over prose, so its grid was not read.
    static func tables() -> [TableLookup.Source] {
        func extracted(_ page: TableFixtureLayouts.Page, physical: Int, printed: String? = nil) -> ManualTable? {
            TableExtractor.extractAll(words: TableFixtureLayouts.words(page),
                                      page: ManualTable.Page(physical: physical, printed: printed))
                .first?.outcome.table
        }
        let tables: [ManualTable] = [
            extracted(TableFixtureLayouts.simpleGrid(), physical: 2, printed: "12"),
            extracted(TableFixtureLayouts.twoLevelHeader(), physical: 3),
            extracted(TableFixtureLayouts.unitsInHeader(), physical: 4),
            extracted(TableFixtureLayouts.groupingBands(), physical: 5),
            .unextracted(.init(label: "Table 92", title: "Wiring notes", continues: false),
                         page: .init(physical: 6, printed: "44"), failure: .tooFewRows),
        ].compactMap { $0 }
        return tables.map { TableLookup.Source(documentId: "a", documentName: "Invented Book A", table: $0) }
    }
}

extension RuleChainFixtures {

    /// `args` with an answer naming the step `service`'s chain is waiting for, as the tool has
    /// required since Plan KD P2 — for the tests written before it, which pass only the value. An
    /// answer that already names a step, and every other action, is left as it is.
    @MainActor static func answering(_ args: [String: Any], _ service: FieldSessionService) -> [String: Any] {
        guard (args["action"] as? String) == "answer", args["step"] == nil,
              let run = service.activeChain, case .ask(let ask) = run.current else { return args }
        var named = args
        named["step"] = ask.name
        return named
    }

    /// `result` without the "Running now" line it opens with while a chain runs (Plan KD P2), for
    /// the tests that read what follows it.
    static func withoutRunningNow(_ result: String) -> String {
        guard result.hasPrefix("Running now: "), let newline = result.firstIndex(of: "\n") else { return result }
        return String(result[result.index(after: newline)...])
    }

    /// What `tool` says to `args`, as the tests before Plan KD P2 read it: the answer names the
    /// pending step, and the "Running now" line is left off.
    @MainActor static func run(_ tool: RuleChainTool, _ args: [String: Any],
                               _ service: FieldSessionService) async throws -> String {
        withoutRunningNow(try await tool.execute(args: answering(args, service)))
    }
}
