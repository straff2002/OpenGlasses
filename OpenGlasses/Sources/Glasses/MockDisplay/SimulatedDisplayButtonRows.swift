#if DAT_MOCK_DISPLAY
import Foundation
import MWDATDisplay
import UIKit
import WebKit

/// The button-row measurement on the simulated Display, development only, on the iOS Simulator.
///
/// It measures what `LensButtonRowBudget` estimates: how wide the lens draws a button for its
/// label. It sends real `MWDATDisplay` `Button`s in `ButtonGroup` rows through the HUD's own lens
/// session (`MetaDisplayBackend.sendMeasurementView`, so no second session) and reads the
/// preview's web view after each send: every button's drawn box and layout width, its label's
/// glyph run, its padding, the gap to the next button, and whether a row wider than the lens wraps,
/// shrinks or is cut off. Labels of known lengths in Latin, Cyrillic, Arabic and full-width (CJK)
/// scripts; `.primary`, `.secondary` and `.outline`; with and without an icon; one to four a row.
///
/// Then the app's own screens, through the HUD's builders and backend: every lens button row in
/// each of the 14 complete languages, before and after the budget; the reading view with an 8- and
/// a 9-line tile under the question line, and its source tile; the page view (the whole page, fit
/// width, a wide table's close-up); the rows view; the fit check; and the buttons that were built
/// with an icon (Today's ready and What's new, a prepared card's primary), which go out as labels.
///
/// The raw readings go to Documents/button-rows/ (results.json, button-rows.log, PNG snapshots
/// and a DOM dump of the first frame); the fitting is done off the device. Only invented text,
/// the catalog's own labels and drawn test pictures are sent; nothing is pressed that sends, saves
/// or asks the model anything.
@MainActor
struct SimulatedDisplayButtonRows {
    let appState: AppState
    let lab: SimulatedDisplayLab

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("button-rows", isDirectory: true)
    }

    /// The 14 complete catalog languages (`LocalizationCatalogGuardTests.completeLanguages`).
    static let languages = ["ar", "es-MX", "fr-CA", "hu", "it", "ja", "ko", "nl", "pt-BR", "ru", "uk",
                            "ur", "zh-Hans", "zh-Hant"]
    static let sendDeadline: TimeInterval = 20

    private var display: GlassesDisplayService { appState.glassesDisplay }
    private var backend: MetaDisplayBackend { display.simulatedDisplayMetaBackend }
    private var card: HUDAnswerCard { appState.hudAnswerCard }
    private var lensPage: LensPageSession { appState.lensPage }

    final class State {
        var lines: [String] = []
        var step = 0
        var results: [String: Any] = [:]
        var sends = 0
    }
    private let state = State()

    // MARK: - Run

    func run() async {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.folder)
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        lab.previewVisible = true

        let connected = await wait(seconds: 20) {
            appState.glassesPhase == .connected && display.deviceSupportsDisplay()
        }
        write("connected=\(connected) phase=\(appState.glassesPhase) availability=\(display.displayAvailability.rawValue) "
              + "server=\(lab.serverAddress ?? "none")")
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // A first, small send: it starts the lens session and the display.
        _ = await sendGroups([[Sample(label: "Warm-up", style: .secondary)]], marker: "BR warm-up")
        await capture("warm-up")

        await singleButtons()
        await icons()
        await rows()
        await languageRows()
        await readingTiles()
        await pageViews()
        await rowsView()
        await fitCheck()
        await formerIconButtons()

        saveResults()
        write("done")
        display.showNotification(title: "Simulated Display", body: "Button rows done", icon: .info, duration: 4)
    }

    // MARK: - 1. One button a row: the label's advance and the button's padding

    struct Sample {
        let label: String
        var style: ButtonStyle = .secondary
        var icon: IconName? = nil
        var script: String = "latin"

        var styleName: String {
            switch style {
            case .primary: return "primary"
            case .secondary: return "secondary"
            case .outline: return "outline"
            @unknown default: return "other"
            }
        }
    }

    static let latinLabels = [
        "i", "n", "W", "nn", "Ok", "Go", "Map", "Page", "Rows", "Back", "Move", "Done", "Close", "Read it",
        "Actions", "Zoom in", "Picture", "‹ Back", "Next ›", "‹ Latest", "Show here", "Whole page",
        "Next page ›", "Schließen", "Aktionen", "Fermer", "Página siguiente ›", "Próxima página ›",
        "Pagina successiva ›", "Volgende pagina ›", "Következő oldal ›", "Műveletek", "Bezárás",
        "How do I reseat the X3 plug?", "What should the supply read at L and N?",
        "Check the intake filter fuse first", "nnnn", "nnnnnnnn", "nnnnnnnnnnnnnnnn", "iiii", "iiiiiiii",
        "iiiiiiiiiiiiiiii", "WWWW", "WWWWWWWW", "MMMMMMMMMMMMMMMM", "Wide WW Mm labels",
    ]
    static let cyrillicLabels = ["Закрыть", "Действия", "Страница", "Назад", "Строки", "Прочитать",
                                 "Следующая страница ›", "Как переподключить разъём X3?"]
    static let arabicLabels = ["إغلاق", "الإجراءات", "الصفحة", "رجوع", "الصفوف", "الصفحة التالية ›",
                               "بند کریں", "کارروائیاں", "کیسے X3 پلگ دوبارہ لگاؤں؟"]
    static let wideLabels = ["字", "字字", "字字字字", "字字字字字字字字", "字字字字字字字字字字字字", "閉じる", "アクション",
                             "ページ", "戻る", "次のページ ›", "行", "全体を表示", "关闭", "操作", "下一页 ›", "關閉",
                             "動作", "닫기", "작업", "페이지", "다음 페이지 ›", "X3プラグを差し直すには？"]

    private func singleButtons() async {
        var samples: [Sample] = []
        for style in [ButtonStyle.secondary, .primary, .outline] {
            samples += Self.latinLabels.map { Sample(label: $0, style: style, script: "latin") }
            samples += Self.cyrillicLabels.map { Sample(label: $0, style: style, script: "cyrillic") }
            samples += Self.arabicLabels.map { Sample(label: $0, style: style, script: "arabic") }
            samples += Self.wideLabels.map { Sample(label: $0, style: style, script: "wide") }
        }
        var measured: [[String: Any]] = []
        let chunks = stride(from: 0, to: samples.count, by: 14).map { Array(samples[$0..<min($0 + 14, samples.count)]) }
        for (index, chunk) in chunks.enumerated() {
            let marker = "BR single \(index + 1)"
            let buttons = await sendGroups(chunk.map { [$0] }, marker: marker)
            if index == 0 { await dumpDOM("single-1") }
            if index < 3 { await capture("1-single-\(index + 1)") }
            measured += zipped(buttons, chunk.map { [$0] }, frame: marker)
            write("1 \(marker): \(buttons.count) buttons for \(chunk.count) samples")
        }
        state.results["1_single"] = measured
        saveResults()
    }

    // MARK: - 1b. Icons

    private func icons() async {
        var groups: [[Sample]] = []
        for style in [ButtonStyle.primary, .secondary, .outline] {
            for label in ["Close", "Next page ›", "閉じる"] {
                groups.append([Sample(label: label, style: style)])
                groups.append([Sample(label: label, style: style, icon: .checkmarkCircle)])
                groups.append([Sample(label: label, style: style, icon: .iCircle)])
            }
        }
        let buttons = await sendGroups(groups, marker: "BR icons")
        await capture("1b-icons")
        state.results["1b_icons"] = zipped(buttons, groups, frame: "BR icons")
        write("1b icons: \(buttons.count) buttons for \(groups.count) samples")
        saveResults()
    }

    // MARK: - 1c. One to four a row: the gap, and a row wider than the lens

    private func rows() async {
        let short: [Sample] = ["Page", "Actions", "Close", "Rows"].map { Sample(label: $0) }
        var out: [[String: Any]] = []
        var sets: [(name: String, groups: [[Sample]])] = []
        sets.append(("1-4 a row", (1...4).map { Array(short.prefix($0)) }))
        sets.append(("styles mixed", [[Sample(label: "Page", style: .secondary), Sample(label: "Actions", style: .secondary),
                                       Sample(label: "Close", style: .outline)],
                                      [Sample(label: "Next ›", style: .primary), Sample(label: "Actions", style: .secondary),
                                       Sample(label: "‹ Back", style: .outline), Sample(label: "Close", style: .outline)]]))
        // Rows estimated at about 600, 700 and 900 px by the provisional budget: wraps, shrinks or cut off?
        sets.append(("too wide", [
            ["What should the supply read at L and N?", "How do I reseat the X3 plug?", "Actions", "Close"].map { Sample(label: $0) },
            ["Página siguiente ›", "Pagina successiva ›", "Volgende pagina ›", "Close"].map { Sample(label: $0) },
            ["Whole page", "Zoom in", "Move", "Read it", "Actions", "Close"].map { Sample(label: $0) },
        ]))
        sets.append(("cjk rows", [["次のページ ›", "アクション", "閉じる"].map { Sample(label: $0, script: "wide") },
                                  ["X3プラグを差し直すには？", "アクション", "閉じる"].map { Sample(label: $0, script: "wide") }]))
        for (index, set) in sets.enumerated() {
            let marker = "BR rows \(index + 1)"
            let buttons = await sendGroups(set.groups, marker: marker)
            await capture("1c-rows-\(index + 1)")
            if set.name == "too wide" { await dumpDOM("too-wide") }
            out.append(["set": set.name, "buttons": zipped(buttons, set.groups, frame: marker),
                        "groups": set.groups.map { $0.map(\.label) }])
            write("1c \(set.name): \(buttons.count) buttons")
        }
        state.results["1c_rows"] = out
        saveResults()
    }

    /// Sends one `ButtonGroup` a row of `groups`, under a meta marker line, and reads every button.
    private func sendGroups(_ groups: [[Sample]], marker: String) async -> [[String: Any]] {
        var components: [any ViewComponent] = [Text(marker, style: .meta, color: .secondary)]
        for group in groups {
            components.append(ButtonGroup(alignment: .center) {
                for sample in group {
                    Button(label: sample.label, style: sample.style, iconName: sample.icon, onClick: {})
                }
            })
        }
        let view = FlexBox(direction: .column, spacing: 6, alignment: .start,
                           padding: EdgeInsets(top: 12, bottom: 20, leading: 12, trailing: 12)) {
            for component in components { component }
        }
        do {
            try await backend.sendMeasurementView(view, deadline: Self.sendDeadline)
        } catch {
            write("send \(marker) failed: \(error)")
        }
        _ = await shows(marker)
        return await readButtons()
    }

    /// The buttons read in document order beside the samples sent, in order.
    private func zipped(_ buttons: [[String: Any]], _ groups: [[Sample]], frame: String) -> [[String: Any]] {
        let samples = groups.enumerated().flatMap { group, row in
            row.enumerated().map { (group: group, position: $0.offset, count: row.count, sample: $0.element) }
        }
        let drawn = buttons.filter { ($0["isBox"] as? Bool) != true }
        var out: [[String: Any]] = []
        for (index, entry) in samples.enumerated() {
            var record: [String: Any] = [
                "frame": frame, "group": entry.group, "position": entry.position, "groupCount": entry.count,
                "label": entry.sample.label, "characters": entry.sample.label.count,
                "wide": entry.sample.label.filter(Self.isWide).count, "script": entry.sample.script,
                "style": entry.sample.styleName, "icon": entry.sample.icon.map { "\($0)" } ?? "none",
                "estimate": Double(max(LensButtonRowBudget.minimumButtonPixels,
                                       LensButtonRowBudget.labelWidth(entry.sample.label) + LensButtonRowBudget.buttonPaddingPixels)),
            ]
            if index < drawn.count { record["dom"] = drawn[index] } else { record["dom"] = "missing" }
            out.append(record)
        }
        if drawn.count != samples.count { write("\(frame): \(drawn.count) drawn for \(samples.count) sent") }
        return out
    }

    static func isWide(_ character: Character) -> Bool {
        LensButtonRowBudget.labelWidth(String(character)) > LensButtonRowBudget.advancePixels
    }

    // MARK: - 4. Every lens row in every complete language

    private struct LensRow {
        let name: String
        let items: [HUDItem]
        let givingWay: [String]
        var protected: Set<String> = []
    }

    private let question = "What should the supply read between terminals L and N with the unit running?"

    /// The builders' own rows, before the budget (as `LensButtonRowLanguageTests` builds them).
    private func lensRows() -> [LensRow] {
        typealias Card = HUDAnswerCardBuilder
        typealias Page = HUDPageScreenBuilder
        let reading = { (hasPage: Bool, followUps: [String], latest: Bool) -> [HUDItem] in
            HUDReadingViewBuilder.rowItems(HUDReadingViewState(
                top: .init(id: 1, question: nil, text: "Done.", isComplete: true, followUps: followUps, hasPage: hasPage),
                topIsLatest: !latest), { _ in })
        }
        let pages = HUDAnswerPager.pages(for: String(repeating: "word ", count: 160), geometry: LensPageFrame.answerGeometry)
        let pageRow = { (index: Int) in
            Card.rowItems(pages[index], followUps: [self.question, self.question], hasPage: true, onAction: { _ in })
        }
        let actions = Card.actions(pages, followUps: [], hasPage: true, followUpsOnRow: 0, offersPage: true) { _ in }.items
        var readingMode = HUDPageViewState(viewport: LensPageViewport(wholePage: CGSize(width: 612, height: 792)),
                                           legibility: LensLegibility(), hasNextPage: true)
        readingMode.readingPages = HUDAnswerPager.pages(for: String(repeating: "step ", count: 400),
                                                        geometry: LensPageFrame.readingGeometry, maxPages: 3)
        readingMode.isReading = true
        readingMode.readingIndex = 1
        var lastReading = readingMode
        lastReading.readingIndex = readingMode.readingPages.count - 1
        var whole = HUDPageViewState(viewport: LensPageViewport(wholePage: CGSize(width: 612, height: 792)),
                                     legibility: LensLegibility(), hasNextPage: true)
        whole.readingPages = readingMode.readingPages
        whole.rows = Self.inventedRows
        var rowsView = whole
        rowsView.showsRows = true
        return [
            LensRow(name: "reading view, Page", items: reading(true, [], false), givingWay: HUDReadingViewBuilder.rowGivingWay),
            LensRow(name: "reading view, a follow-up", items: reading(false, [question], false),
                    givingWay: HUDReadingViewBuilder.rowGivingWay),
            LensRow(name: "reading view, an earlier answer", items: reading(false, [], true),
                    givingWay: HUDReadingViewBuilder.rowGivingWay),
            LensRow(name: "paged card, first page", items: pageRow(0), givingWay: Card.rowGivingWay),
            LensRow(name: "paged card, middle page", items: pageRow(1), givingWay: Card.rowGivingWay),
            LensRow(name: "paged card, last page", items: pageRow(pages.count - 1), givingWay: Card.rowGivingWay),
            LensRow(name: "Actions", items: actions, givingWay: Card.actionsGivingWay, protected: [Card.ItemID.answer]),
            LensRow(name: "page view, whole page", items: Page.rowItems(whole, { _ in }), givingWay: Page.givingWay(for: whole)),
            LensRow(name: "page view, rows", items: Page.rowItems(rowsView, { _ in }), givingWay: Page.givingWay(for: rowsView)),
            LensRow(name: "reading mode, a middle page", items: Page.rowItems(readingMode, { _ in }),
                    givingWay: Page.givingWay(for: readingMode)),
            LensRow(name: "reading mode, the last page", items: Page.rowItems(lastReading, { _ in }),
                    givingWay: Page.givingWay(for: lastReading)),
        ]
    }

    static let inventedRows = LensPageRows(title: "Table 3 (Invented codes)", rows: [
        .init(label: "E7", text: "E7 · Low supply voltage · Check the supply at L and N",
              headings: "Code · Fault · Action", spoken: "E7. Fault: Low supply voltage."),
        .init(label: "E8", text: "E8 · High head pressure · Clean the condenser coil and check the fan",
              headings: "Code · Fault · Action", spoken: "E8. Fault: High head pressure."),
        .init(label: "E9", text: "E9 · Sensor open · Reseat the X3 plug",
              headings: "Code · Fault · Action", spoken: "E9. Fault: Sensor open."),
        .init(label: "E10", text: "E10 · Low charge · Check for leaks before adding refrigerant by weight",
              headings: "Code · Fault · Action", spoken: "E10. Fault: Low charge."),
    ], highlighted: 0)

    private static func bundle(for language: String) -> Bundle? {
        for name in [language, language.replacingOccurrences(of: "-", with: "_"), language.lowercased()] {
            if let path = Bundle.main.path(forResource: name, ofType: "lproj"), let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    private func languageRows() async {
        var out: [[String: Any]] = []
        let rows = lensRows()
        for language in Self.languages {
            guard let bundle = Self.bundle(for: language) else {
                write("4 \(language): no lproj in the app bundle")
                out.append(["language": language, "error": "no lproj"])
                continue
            }
            let translate = { (key: String) in bundle.localizedString(forKey: key, value: key, table: "Localizable") }
            for row in rows {
                let items = row.items.map { item in
                    HUDItem(id: item.id, label: translate(item.label), icon: item.icon, style: item.style, action: item.action)
                }
                let short = { (id: String) -> String? in LensButtonRowBudget.shortLabelKey(for: id).map(translate) }
                let fitted = LensButtonRowBudget.fit(items, givingWay: row.givingWay, protected: row.protected,
                                                     shortLabel: short)
                var entry: [String: Any] = ["language": language, "row": row.name]
                for (kind, list) in [("raw", items), ("fitted", fitted.row)] {
                    let marker = "LR \(language) \(kind) \(row.name)"
                    let screen = HUDScreen(title: nil, lines: [HUDLine(marker, emphasis: .meta)], items: list)
                    do {
                        try await backend.send(screen: screen)
                    } catch {
                        write("4 \(marker) failed: \(error)")
                    }
                    _ = await shows(marker)
                    let drawn = await readButtons().filter { ($0["isBox"] as? Bool) != true }
                    entry[kind] = [
                        "labels": list.map { HUDTextShaper.condense($0.label, max: HUDTextShaper.maxTitleLength) },
                        "styles": list.map { "\($0.style)" },
                        "estimates": list.map { Double(LensButtonRowBudget.width(of: $0)) },
                        "estimate": Double(LensButtonRowBudget.width(of: list)),
                        "dom": drawn,
                    ]
                    if language == "ar" || language == "ru" || language == "ja" {
                        if row.name == "reading view, a follow-up" || row.name == "paged card, middle page" {
                            await capture("4-\(language)-\(kind)-\(row.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: ""))")
                        }
                    }
                }
                entry["moved"] = fitted.moved.map(\.id)
                out.append(entry)
            }
            write("4 \(language): \(rows.count) rows sent raw and fitted")
            state.results["4_languageRows"] = out
            saveResults()
        }
        state.results["4_languageRows"] = out
        saveResults()
    }

    // MARK: - 2, 3. The reading view: an 8- and a 9-line tile under the question line, the source tile

    /// A paragraph that `HUDReadingRows` makes one tile of exactly `lines` lines: two long
    /// sentences, then one-line sentences until the tile is 8 lines; for 9, a short last sentence
    /// that the tile takes in (`orphan`).
    private func paragraph(lines: Int, maxChars: Int, orphan: Bool) -> String? {
        let long = [
            "Measure TP1 at the intake filter first; it should read between 0.4 and 0.9 volts.",
            "Then measure TP2 at the gain stage, which should sit between 2.1 and 2.6 volts.",
            "If TP1 is low, check the intake filter's fuse and the ribbon cable to the sensor head.",
            "Next, measure TP3 at the output buffer, which should read within a tenth of a volt of TP2.",
        ]
        let short = ["Keep the cover off for now.", "Note each reading as you go.", "Power the board down first.",
                     "Check the ribbon cable seat.", "Use the black probe on TP0.", "Wear the wrist strap."]
        let tails = ["Then test it again.", "Record it as well.", "Then test.", "Done."]
        func lineCount(_ text: String) -> Int? {
            let rows = HUDReadingRows.rows(for: text, maxChars: maxChars)
            return rows.count == 1 ? rows[0].lines.count : nil
        }
        for first in 0..<long.count {
            for second in 0..<long.count where second != first {
                var text = long[first] + " " + long[second]
                for line in short {
                    guard let count = lineCount(text), count < 8 else { break }
                    let next = text + " " + line
                    guard let made = lineCount(next), made <= 8 else { continue }
                    text = next
                }
                guard lineCount(text) == 8 else { continue }
                if !orphan { return lines == 8 ? text : nil }
                for tail in tails where lineCount(text + " " + tail) == lines { return text + " " + tail }
            }
        }
        return nil
    }

    private func readingTiles() async {
        let style = Config.lensAnswerStyle
        Config.lensAnswerStyle = .scroll
        defer { Config.lensAnswerStyle = style }
        let maxChars = HUDReadingRows.maxChars(for: card.geometry())
        let eight = paragraph(lines: 8, maxChars: maxChars, orphan: false)
        let nine = paragraph(lines: 9, maxChars: maxChars, orphan: true)
        write("2 maxChars=\(maxChars) eight=\(eight != nil) nine=\(nine != nil)")
        guard let eight, let nine else {
            state.results["2_readingTiles"] = ["error": "no 8- or 9-line paragraph found", "maxChars": maxChars]
            return
        }
        let source = "Source: Invented Q-7 Relay Board Guide, page 20; Invented Service Bulletin 4, page 2."
        let reply = [eight, nine, source].joined(separator: "\n")
        card.beginTurn(question: "how do I find a fault on the Q-7 relay board")
        card.finishTurn(reply: reply)
        card.endTurn()
        _ = await wait(seconds: 8) { card.isShowing && card.isReadingView }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let screen = card.screenOnLens
        let planned = (screen?.flow.flatMap(\.blocks) ?? []).map { ["id": $0.id, "lines": $0.lines.count] as [String: Any] }
        let open = await readScreen()
        await capture("2-reading-open", note: "planned=\(planned)")
        await dumpDOM("reading-open")
        var moves: [[String: Any]] = []
        for move in 1...4 {
            await key("ArrowDown")
            let after = await readScreen()
            moves.append(["move": "down \(move)", "screen": after])
            await capture("2-reading-down-\(move)")
        }
        state.results["2_readingTiles"] = [
            "maxChars": maxChars, "geometry": "\(card.geometry())", "eight": eight, "nine": nine, "source": source,
            "planned": planned, "buttons": screen?.items.map(\.label) ?? [], "open": open, "moves": moves,
        ]
        write("2 reading view: planned=\(planned)")
        if let close = card.screenOnLens?.items.first(where: { $0.id == HUDAnswerCardBuilder.ItemID.close }) { close.action() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        saveResults()
    }

    // MARK: - 5. The page view

    private func pageViews() async {
        var out: [String: Any] = [:]
        // The table page, outlined as a pictured table: the whole page, then its close-up (cut in
        // halves when wider than the lens).
        await stage(SimulatedDisplayTestManual.staged(page: 3, figure: "Table 1", pictured: true), words: "show me table 1")
        out["tableWhole"] = await pageReading("5-table-whole")
        await pressBlock(HUDPageScreenBuilder.ItemID.wholePicture)
        out["tableCloseUp"] = await pageReading("5-table-close-up")
        // Down the strip, to see both halves pass.
        var strip: [[String: Any]] = []
        for move in 1...8 {
            await key("ArrowDown")
            strip.append(["move": move, "screen": await readScreen()])
            if move == 4 || move == 8 { await capture("5-table-close-up-down-\(move)") }
        }
        out["tableCloseUpMoves"] = strip
        await pressItem(HUDPageScreenBuilder.ItemID.close)
        // A page by number: whole, then fit width.
        await stage(SimulatedDisplayTestManual.staged(page: 1, figure: "Figure 1"), words: "show me the page")
        out["pageWhole"] = await pageReading("5-page-whole")
        await pressBlock(HUDPageScreenBuilder.ItemID.wholePicture)
        out["pageFitWidth"] = await pageReading("5-page-fit-width")
        await pressItem(HUDPageScreenBuilder.ItemID.close)
        state.results["5_pageViews"] = out
        saveResults()
    }

    private func pageReading(_ name: String) async -> [String: Any] {
        let screen = await readScreen()
        let shown = lensPage.shownState
        await capture(name, note: "view=\(shown.map { "\($0.view)" } ?? "-") halves=\(shown?.closeUp?.hasHalves ?? false)")
        return [
            "view": shown.map { "\($0.view)" } ?? "-",
            "halves": shown?.closeUp?.hasHalves ?? false,
            "highlight": shown?.highlight.reason.rawValue ?? "-",
            "buttons": lensPage.shownScreen?.items.map(\.label) ?? [],
            "pictures": (lensPage.shownScreen?.allBlocks.compactMap(\.picture) ?? [])
                .map { [Double($0.pixelSize.width), Double($0.pixelSize.height)] },
            "screen": screen,
        ]
    }

    private func stage(_ staged: FieldSessionService.StagedFigure, words: String) async {
        let original = lensPage.requestWords
        lensPage.requestWords = { words }
        let before = lensPage.shownScreen?.renderKey
        appState.presentOnLens([staged], opening: 0)
        lensPage.requestWords = original
        let opened = await wait(seconds: 10) { lensPage.isViewOnLens && lensPage.shownScreen?.renderKey != before }
        write("5 stage p.\(staged.page) \"\(words)\": opened=\(opened)")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// The page view's block pressed as the lens would press it (its action; the walkthrough
    /// presses the same through the mock).
    private func pressBlock(_ id: String) async {
        let before = lensPage.shownScreen?.renderKey
        lensPage.shownScreen?.block(id: id)?.action?()
        _ = await wait(seconds: 8) { lensPage.shownScreen?.renderKey != before }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    private func pressItem(_ id: String) async {
        let before = lensPage.shownScreen?.renderKey
        lensPage.shownScreen?.items.first { $0.id == id }?.action()
        _ = await wait(seconds: 5) { lensPage.shownScreen?.renderKey != before }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: - 6. The rows view

    private func rowsView() async {
        var state6 = HUDPageViewState(viewport: LensPageViewport(wholePage: CGSize(width: 612, height: 792)),
                                      legibility: LensLegibility(), hasNextPage: false)
        state6.rows = Self.inventedRows
        state6.showsRows = true
        let screen = HUDPageScreenBuilder.screen(state6) { _ in }
        do { try await backend.send(screen: screen) } catch { write("6 rows send failed: \(error)") }
        _ = await shows("Table 3")
        let open = await readScreen()
        await capture("6-rows-open")
        var moves: [[String: Any]] = []
        for move in 1...4 {
            await key("ArrowDown")
            moves.append(["move": move, "screen": await readScreen()])
        }
        await capture("6-rows-down-4")
        state.results["6_rowsView"] = ["view": "\(state6.view)", "buttons": screen.items.map(\.label),
                                       "cards": screen.trailingFlow.flatMap(\.blocks).map { $0.lines.map(\.text) },
                                       "open": open, "moves": moves]
        saveResults()
    }

    // MARK: - 7. The fit check

    private func fitCheck() async {
        let refusal = appState.lensFitCheck.start()
        _ = await shows("Fit check")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let screen = await readScreen()
        await capture("7-fit-check")
        state.results["7_fitCheck"] = ["refusal": refusal.map { "\($0)" } ?? "none", "screen": screen,
                                       "rulerWidth": Double(LensFitCheck.rulerWidth), "tileWidth": Double(LensFitCheck.tileWidth),
                                       "tileOrigins": LensFitCheck.tileOrigins.map(Double.init)]
        appState.lensFitCheck.stop()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        saveResults()
    }

    // MARK: - 8. Buttons that carried an icon

    /// The Today screen's ready and What's new buttons and a prepared card's primary, built with
    /// their icons as the builders build them, sent through the backend: each should show its label.
    private func formerIconButtons() async {
        let today = HUDTodayBuilder.items(.init(ready: {}, whatsNew: {}, close: {}))
        let card = [
            HUDItem(id: PreparedCardHUDBuilder.ItemID.primary, label: "Directions", icon: .navigation, style: .primary) {},
            HUDItem(id: PreparedCardHUDBuilder.ItemID.second, label: "Text Ana", icon: .message, style: .secondary) {},
            HUDItem(id: PreparedCardHUDBuilder.ItemID.close, label: "Close", style: .outline) {},
        ]
        var out: [[String: Any]] = []
        for (name, items) in [("today", today), ("prepared card", card)] {
            let marker = "BR icons gone \(name)"
            let screen = HUDScreen(title: nil, lines: [HUDLine(marker, icon: .clock, emphasis: .meta)], items: items,
                                   focusItemID: items.first?.id)
            do {
                try await backend.send(screen: screen)
            } catch {
                write("8 \(marker) failed: \(error)")
            }
            _ = await shows(marker)
            let drawn = await readButtons().filter { ($0["isBox"] as? Bool) != true }
            await capture("8-icons-gone-\(name.replacingOccurrences(of: " ", with: "-"))")
            out.append(["screen": name, "labels": items.map(\.label), "icons": items.map { "\($0.icon)" },
                        "dom": drawn])
            write("8 \(name): \(drawn.map { $0["text"] as? String ?? "?" })")
        }
        state.results["8_formerIconButtons"] = out
        saveResults()
    }

    // MARK: - Reading the preview

    private var web: WKWebView? { lab.previewPanel.webView as? WKWebView }

    private func shows(_ marker: String) async -> Bool {
        guard let web else { return false }
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [marker]), encoding: .utf8)) ?? "[\"\"]"
        let script = "(() => { const m = \(quoted)[0]; return (document.body && document.body.innerText.indexOf(m) >= 0) ? 'yes' : 'no'; })()"
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? await web.evaluateJavaScript(script) as? String) == "yes" {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        write("marker not drawn: \(marker)")
        return false
    }

    /// Every button and tappable box on the preview, in document order.
    private func readButtons() async -> [[String: Any]] {
        guard let web, let text = try? await web.evaluateJavaScript(Self.buttonScript) as? String,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["buttons"] as? [[String: Any]]) ?? []
    }

    /// The whole screen: buttons, boxes and their text lines, loose text, pictures, scroll, focus.
    private func readScreen() async -> [String: Any] {
        guard let web, let text = try? await web.evaluateJavaScript(Self.screenScript) as? String,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["error": "unread"] }
        return json
    }

    /// Shared helpers: a rect, an element's text lines (distinct line tops of its text) and glyph run.
    static let helpers = """
      const R = e => { const b = e.getBoundingClientRect(); return [b.left, b.top, b.width, b.height].map(v => Math.round(v * 10) / 10); };
      const textOf = e => {
        const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT); let l = Infinity, r = -Infinity, t = Infinity, b = -Infinity; const tops = new Set(); let text = '';
        while (w.nextNode()) { const n = w.currentNode; if (!n.textContent.trim()) continue; text += n.textContent;
          const rg = document.createRange(); rg.selectNodeContents(n);
          for (const cr of rg.getClientRects()) { if (cr.width < 0.5) continue; tops.add(Math.round(cr.top)); l = Math.min(l, cr.left); r = Math.max(r, cr.right); t = Math.min(t, cr.top); b = Math.max(b, cr.bottom); } }
        return { text: text.trim(), lines: tops.size, l: Math.round(l * 10) / 10, r: Math.round(r * 10) / 10, w: Math.round((r - l) * 10) / 10, t: Math.round(t), h: Math.round(b - t) };
      };
      const app = document.getElementById('app') || document.body;
      const cands = [...app.querySelectorAll('button, [role=button]')].filter(e => !e.querySelector('button, [role=button]'));
      const describe = (e) => {
        const s = getComputedStyle(e); const tx = textOf(e);
        const label = [...e.querySelectorAll('*')].find(c => c.children.length === 0 && (c.textContent || '').trim().length > 0);
        const ls = label ? getComputedStyle(label) : null;
        const p = e.parentElement, pp = p ? p.parentElement : null; const ps = p ? getComputedStyle(p) : null, pps = pp ? getComputedStyle(pp) : null;
        return { tag: e.tagName, cls: String(e.className).slice(0, 100), isBox: !!e.querySelector('.dat-preview-flex'),
                 rect: R(e), offsetW: e.offsetWidth, offsetH: e.offsetHeight, scrollW: e.scrollWidth, clientW: e.clientWidth,
                 text: tx.text, lines: tx.lines, textL: tx.l, textR: tx.r, textW: tx.w, textT: tx.t, textH: tx.h,
                 padL: s.paddingLeft, padR: s.paddingRight, borderL: s.borderLeftWidth, borderR: s.borderRightWidth,
                 minW: s.minWidth, maxW: s.maxWidth, transform: s.transform, focused: document.activeElement === e,
                 layoutW: e.getAttribute('data-uit-button-default-layout-width'), focusedLayoutW: e.getAttribute('data-uit-button-focused-layout-width'),
                 defaultScale: e.getAttribute('data-uit-button-default-scale'), compensation: e.style.getPropertyValue('--uit-button-layout-compensation'),
                 font: ls ? (ls.fontWeight + ' ' + ls.fontSize + ' ' + ls.fontFamily).slice(0, 120) : '',
                 labelTag: label ? label.tagName : '', labelCls: label ? String(label.className).slice(0, 80) : '',
                 labelOverflow: ls ? (ls.textOverflow + ' ' + ls.overflow + ' ' + ls.whiteSpace) : '',
                 labelScrollW: label ? label.scrollWidth : -1, labelClientW: label ? label.clientWidth : -1,
                 icons: [...e.querySelectorAll('svg, img')].map(R),
                 parentRect: p ? R(p) : null, parentGap: ps ? ps.columnGap : '', parentWrap: ps ? ps.flexWrap : '', parentJustify: ps ? ps.justifyContent : '',
                 parentScrollW: p ? p.scrollWidth : -1, parentClientW: p ? p.clientWidth : -1, parentOverflow: ps ? ps.overflowX : '',
                 grandRect: pp ? R(pp) : null, grandGap: pps ? pps.columnGap : '', grandWrap: pps ? pps.flexWrap : '', grandJustify: pps ? pps.justifyContent : '',
                 grandScrollW: pp ? pp.scrollWidth : -1, grandClientW: pp ? pp.clientWidth : -1, grandOverflow: pps ? pps.overflowX : '' };
      };
    """

    static let buttonScript = """
    (() => {
    \(helpers)
      return JSON.stringify({ viewport: [innerWidth, innerHeight], buttons: cands.map(describe) });
    })()
    """

    static let screenScript = """
    (() => {
    \(helpers)
      const scrolls = [...document.querySelectorAll('*')].filter(e => e.scrollHeight > e.clientHeight + 1 && ['auto', 'scroll', 'hidden'].includes(getComputedStyle(e).overflowY))
        .map(e => ({ tag: e.tagName, top: Math.round(e.scrollTop), h: e.scrollHeight, ch: e.clientHeight }));
      const loose = [];
      const w = document.createTreeWalker(app, NodeFilter.SHOW_TEXT);
      while (w.nextNode()) { const n = w.currentNode; const t = n.textContent.trim(); if (!t || n.parentElement.closest('button, [role=button]')) continue;
        const rg = document.createRange(); rg.selectNodeContents(n); const tops = new Set(); for (const cr of rg.getClientRects()) if (cr.width >= 0.5) tops.add(Math.round(cr.top));
        const b = rg.getBoundingClientRect(); const s = getComputedStyle(n.parentElement);
        loose.push({ text: t.slice(0, 80), rect: [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)], lines: tops.size, font: s.fontSize + '/' + s.lineHeight }); }
      const imgs = [...app.querySelectorAll('img')].map(e => ({ rect: R(e), natural: [e.naturalWidth, e.naturalHeight] }));
      const ae = document.activeElement;
      return JSON.stringify({ viewport: [innerWidth, innerHeight], scrolls, buttons: cands.map(describe), loose, imgs,
                              active: ae && ae !== document.body ? { text: (ae.innerText || '').trim().slice(0, 60), rect: R(ae) } : null });
    })()
    """

    /// A key down and up on the preview's focused element (the preview's focus engine listens for it).
    private func key(_ name: String) async {
        guard let web else { return }
        let codes = ["ArrowUp": 38, "ArrowDown": 40, "ArrowLeft": 37, "ArrowRight": 39, "Enter": 13]
        let script = """
        (() => {
          const t = document.activeElement || document.body;
          for (const type of ['keydown', 'keyup']) {
            t.dispatchEvent(new KeyboardEvent(type, { key: '\(name)', code: '\(name)', keyCode: \(codes[name] ?? 0), which: \(codes[name] ?? 0), bubbles: true, cancelable: true }));
          }
          return 'ok';
        })()
        """
        _ = try? await web.evaluateJavaScript(script)
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    private func dumpDOM(_ name: String) async {
        guard let web, let html = try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String else { return }
        let trimmed = html.replacingOccurrences(of: #"data:image/[^"')]{80,}"#, with: "data:image/…", options: .regularExpression)
        try? trimmed.data(using: .utf8)?.write(to: Self.folder.appendingPathComponent("dom-\(name).html"))
    }

    // MARK: - Evidence

    private func capture(_ name: String, note: String = "") async {
        state.step += 1
        let file = String(format: "%02d-%@.png", state.step, name)
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let image = lab.snapshot(), let data = image.pngData() {
            try? data.write(to: Self.folder.appendingPathComponent(file))
            write("snapshot \(file) \(note)")
        } else {
            write("snapshot \(file) (none) \(note)")
        }
    }

    private func saveResults() {
        var results = state.results
        results["measuredAt"] = ISO8601DateFormatter().string(from: Date())
        results["note"] = "The iOS Simulator's simulated Ray-Ban Display (Mock Device Kit), not the glasses."
        results["budget"] = ["advance": Double(LensButtonRowBudget.advancePixels),
                             "wideFactor": Double(LensButtonRowBudget.wideAdvanceFactor),
                             "padding": Double(LensButtonRowBudget.buttonPaddingPixels),
                             "minimum": Double(LensButtonRowBudget.minimumButtonPixels),
                             "icon": Double(LensButtonRowBudget.iconPixels), "gap": Double(LensButtonRowBudget.gapPixels),
                             "column": Double(LensButtonRowBudget.columnPixels)]
        guard JSONSerialization.isValidJSONObject(results),
              let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) else {
            write("results not serialisable")
            return
        }
        try? data.write(to: Self.folder.appendingPathComponent("results.json"))
    }

    private func write(_ line: String) {
        state.lines.append(line)
        lab.note(appState, "button rows " + line)
        let text = state.lines.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: Self.folder.appendingPathComponent("button-rows.log"))
    }

    private func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}
#endif
