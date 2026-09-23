#if DEBUG
import Foundation
import UIKit

/// Deterministic launch state for the UI-test target (Plan DF P4).
///
/// **This exists only inside a Debug build.** The whole file is behind `#if DEBUG`, so a Release
/// binary contains none of it, and every path is inert unless the process was launched with
/// `-OGUITest`. Nothing here changes how the app *behaves*: it seeds state a screen would
/// otherwise need a real account, a real device, or a real conversation to reach, so an audit can
/// stand in front of a known screen instead of whatever the last run left behind. There is no
/// branch that skips a check, shortens an animation, or fakes a result.
///
/// The seam is deliberately narrow — two call sites, both in `OpenGlassesApp`:
/// `applyLaunchState()` before anything reads a default, and `seedRuntime(_:)` once `AppState`
/// exists for the state that has no defaults key.
enum UITestSupport {
    /// Present on the launch arguments of a UI-test run, and nowhere else.
    static let activation = "-OGUITest"

    enum Flag: String, CaseIterable {
        /// A never-launched install: onboarding is the first thing on screen.
        case freshInstall = "-OGUITestFreshInstall"
        /// Past onboarding, with the settings journey in its folded first-run shape.
        case configured = "-OGUITestConfigured"
        /// "Show everything" already on, so the hub renders every category as a row.
        case showAllSettings = "-OGUITestShowAllSettings"
        /// Captions overlay on screen with a short history and a live line.
        case seedCaptions = "-OGUITestSeedCaptions"
        /// My Day set up and loaded with a full card's worth of rows — the state that needs a
        /// calendar, a permission grant and a real morning to reach otherwise.
        case seedMyDay = "-OGUITestSeedMyDay"
        /// Stored conversations, one of them long — the state the dock's conversation page needs
        /// to be looked at at all, and which otherwise takes a real session per thread to reach.
        case seedConversations = "-OGUITestSeedConversations"
        /// A delete-and-reinstall: the Keychain kept a provider key, `UserDefaults` kept nothing.
        case reinstall = "-OGUITestReinstall"
        /// Field Assist entitled and switched on, with no job open — the Job tab present, showing
        /// its empty state.
        case fieldAssist = "-OGUITestFieldAssist"
        /// Field Assist as above, plus one finished job in the history, so the past-job list and
        /// the past-job page have something in them.
        case seedFieldHistory = "-OGUITestSeedFieldHistory"
        /// Field Assist as above, plus a job open with a number, a machine and two tasks on it.
        case seedFieldJob = "-OGUITestSeedFieldJob"
        /// A **modifier**, not a state of its own: it puts photographs on whichever jobs the
        /// flags above seeded — the finished one, the open one, or both — which is what the
        /// past-job Photos section and the close-job evidence review need in order to have
        /// anything to show. The pictures are drawn in-process, so no camera, no photo library
        /// and no permission is involved.
        case seedFieldPhotos = "-OGUITestSeedFieldPhotos"
        /// A modifier like the one above, for clips (Plan FO P2b): it puts one length-capped clip
        /// on the open job so the Photos-and-clips section, the duration badge and the review's
        /// clip row have something to measure. The clip's bytes are a placeholder and its poster
        /// frame is drawn in-process — no camera and no relay is involved, which is the point: the
        /// audit is about the labels and the touch targets, not about video.
        case seedFieldClips = "-OGUITestSeedFieldClips"
        /// A modifier for Plan FO P2c: the finished job carries a customer's signature, so the
        /// past job's Customer acceptance block — the summary that was agreed to, the name, the
        /// time and the drawing — is on screen for the audit. The signature is drawn in-process
        /// and the sign-off goes through the shipping `recordSignOff`, so what is seeded is what a
        /// real hand-over writes.
        case seedFieldSignOff = "-OGUITestSeedFieldSignOff"
        /// A modifier for Plan FO P3b: the finished job carries a saved debrief, and three
        /// reports are staged in the delivery queue — so the past job's Debrief section and the
        /// Job tab's "reports ready to send" card are both on screen for an audit. The debrief
        /// goes through the shipping `recordDebrief` and the queue through the shipping store, so
        /// what is seeded is what a real drive writes. Nothing is sent: a staged send is staged.
        case seedFieldSends = "-OGUITestSeedFieldSends"
        /// A **narrowing** modifier on the Field Assist flags (Plan FS): the entitlement becomes
        /// the retired one-time unlock instead of the internal grant, so screens render the state
        /// a grandfathered owner sees — the bundled vaults, and the import button explaining that
        /// vaults of your own come with a subscription. It can only ever take capabilities away,
        /// which is why it is safe to have: there is no flag here that opens a gate.
        case retiredUnlockOnly = "-OGUITestRetiredUnlockOnly"
        /// Plan FS PR2: the review sheet for a vault offered by a link, in its **signed** state.
        /// The archive is built in-process and goes through the whole pipeline — zip reader,
        /// header, per-file checksums, signature, publisher lookup. Only the transport is
        /// replaced, so nothing here is a bypass of a check.
        case vaultLinkSigned = "-OGUITestVaultLinkSigned"
        /// …and in its **unverified** state: the same archive with no signature, which is what
        /// raises the highlighted warning block and the second acknowledgement.
        case vaultLinkUnverified = "-OGUITestVaultLinkUnverified"
        /// A vault already installed from a link, unsigned — so the Custom Vaults row can be seen
        /// with its "Unverified source" badge.
        case vaultReceivedBadge = "-OGUITestVaultReceivedBadge"
        /// Dark appearance, for the half of a screenshot pass that is about the dark palette.
        case darkAppearance = "-OGUITestDarkAppearance"
    }

    /// Whether a vault-link review is being staged for a screenshot.
    static var wantsVaultLinkReview: Bool { isSet(.vaultLinkSigned) || isSet(.vaultLinkUnverified) }

    /// The link service the app runs with under a vault-link flag: the real pipeline with a
    /// fixture archive handed to it instead of a network response, and the publisher list the
    /// fixture's key belongs to. Nil — and the app builds its own — on every other launch.
    @MainActor
    static func vaultLinkService(isOnCellular: @escaping () -> Bool) -> VaultLinkService? {
        guard wantsVaultLinkReview else { return nil }
        let signed = isSet(.vaultLinkSigned)
        let fixture = UITestVaultFixture.archive(signed: signed)
        return VaultLinkService(
            download: { _, staging, progress in
                let file = try staging.create()
                try staging.append(fixture.data, to: file)
                progress(fixture.data.count)
                return (file, URL(string: "https://\(UITestVaultFixture.host)/d/demo/acme.vaultarchive")!)
            },
            publishers: { fixture.publishers },
            isOnCellular: isOnCellular,
            audit: { _, _ in })
    }

    /// Whether any of the Field Assist flags is set. They are cumulative: seeding a job implies
    /// the feature is on, because a job cannot exist otherwise.
    static var wantsFieldAssist: Bool {
        isSet(.fieldAssist) || isSet(.seedFieldHistory) || isSet(.seedFieldJob)
            || isSet(.seedFieldPhotos) || isSet(.seedFieldClips) || isSet(.seedFieldSignOff)
            || isSet(.seedFieldSends)
    }

    static var isActive: Bool { arguments.contains(activation) }

    static func isSet(_ flag: Flag) -> Bool { isActive && arguments.contains(flag.rawValue) }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    // MARK: - Defaults-backed state

    /// Seed the persisted state, before anything can read it.
    ///
    /// Called first thing in `OpenGlassesApp.init()` — ahead of the secrets migration and the
    /// settings-journey migration, both of which read what this writes.
    static func applyLaunchState() {
        guard isActive else { return }

        // Every run starts from the same defaults, whatever the simulator was left holding.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        // Saved models live in the Keychain, which outlives an app delete on a simulator — so
        // wiping the defaults domain is not on its own enough to produce a first-run app. One
        // keyless model is what a device with nothing configured actually holds.
        //
        // A reinstall is the same wipe with the *other* half left standing: the same absent
        // defaults, and a saved model still carrying a real key. That is the whole state — no
        // flag says "this is a reinstall", the app works it out from these two facts, which is
        // exactly what the test is here to check.
        Config.setSavedModels(isSet(.reinstall)
                              ? [Config.appleIntelligenceDefault, keyedModelThatSurvivedTheDelete]
                              : [Config.appleIntelligenceDefault])

        if isSet(.freshInstall) {
            Config.setHasCompletedOnboarding(false)
        }

        if isSet(.seedMyDay) {
            // The opt-in the setup card writes. The card's *content* is seeded at runtime below;
            // this is only the switch that decides which card is drawn.
            UserDefaults.standard.set(true, forKey: "myDayEnabled")
            UserDefaults.standard.set(false, forKey: "myDayCollapsed")
        }

        if isSet(.darkAppearance) {
            UserDefaults.standard.set("dark", forKey: "appAppearance")
        }

        if isSet(.configured) {
            Config.setHasCompletedOnboarding(true)
            // Write the journey state directly rather than letting the migration infer it: a
            // completed onboarding reads as a prior install, which unfolds every category and
            // leaves no Discover card to audit. The folded hub is the shape this seeds.
            seedJourney(showsEverything: isSet(.showAllSettings))
        }

        // Sessions live in Documents, which outlives the defaults wipe, so **every** UI-test
        // launch starts from no jobs — not only a seeded one. A run with no Field Assist flags
        // that inherited an open job from the launch before it would draw the Job tab, because the
        // tab is shown while a session is active precisely so a licence lapsing mid-job cannot
        // strand one. That is correct behaviour reading stale state, and it made "no Job tab
        // without the entitlement" depend on which test ran first.
        clearFieldSessions()

        if wantsFieldAssist {
            // The entitlement comes from the seam that already exists for development and demos —
            // in-memory, `#if DEBUG` only, producing an evidence case that does not compile into a
            // Release binary. Nothing here weakens the shipped gate: `Config`, `VaultRegistry` and
            // every field tool still ask the same evaluator the same question.
            FieldAssistEntitlement.shared.setInternalDeveloperGrant(true)
            if isSet(.retiredUnlockOnly) {
                FieldAssistEntitlement.shared.setInternalDeveloperGrant(false)
                FieldAssistEntitlement.shared.provider = RetiredUnlockOnlyProvider()
            }
            applyFieldAssistSwitch()
        }
    }

    /// Turn Field Assist on, and make sure the write has actually landed.
    ///
    /// Written last and flushed on purpose. `removePersistentDomain` above is not ordered against
    /// the writes that follow it, and a launch where this one was swallowed comes up with no Job
    /// tab at all — which looked exactly like a bug in the tab's own visibility rule until the
    /// failing run's accessibility tree showed four tabs and a `fieldAssistEnabled` of false.
    /// `seedRuntime` asserts it a second time, once `AppState` exists.
    private static func applyFieldAssistSwitch() {
        Config.setFieldAssistEnabled(true)
        // The name the customer-facing sign-off sheet is headed with (Plan FO P2c). A real device
        // has none until an organisation profile sets one, and the sheet then omits the line — but
        // a screenshot of the line is the point of seeding it.
        Config.organizationDisplayName = "Northbridge Mechanical"
        UserDefaults.standard.synchronize()
    }

    /// The one fact a reinstall is made of, stated directly because the store that carries it
    /// does not exist here.
    ///
    /// A simulator build with code signing off has **no Keychain**: every read and write returns
    /// `errSecMissingEntitlement`, which is also why ~13 Keychain-backed unit tests fail in the
    /// same environment. A surviving *Keychain* credential is exactly what separates a reinstall
    /// from a fresh install, so writing one and hoping to read it back seeds nothing at all.
    /// `Config.captureLaunchProvenance()` takes this instead.
    ///
    /// Still only state, on the terms at the top of this file: the detection rule, the page it
    /// produces and both of its exits are the shipping ones, and nothing here compiles into a
    /// Release binary. `nil` on every launch that is not seeding a reinstall, so the real probe
    /// answers for all of them.
    static var seededSurvivingCredentials: Bool? {
        guard isSet(.reinstall) else { return nil }
        return true
    }

    /// The saved model a reinstall finds waiting for it — written for the sake of a device or a
    /// signed build, where it is the whole seed. Not a real credential; nothing in a UI test ever
    /// sends it anywhere. Just a non-empty key, which is what the gate reads.
    private static let keyedModelThatSurvivedTheDelete = ModelConfig(
        id: "uitest-surviving-key",
        name: "Anthropic",
        provider: LLMProvider.anthropic.rawValue,
        apiKey: "sk-ant-uitest-not-a-real-key",
        model: LLMProvider.anthropic.defaultModel,
        baseURL: LLMProvider.anthropic.defaultBaseURL
    )

    private static func seedJourney(showsEverything: Bool) {
        var state = SettingsJourneyMigration.initialState(
            signals: .init(hasPriorInstall: false, configuredCategoryIDs: [])
        )
        state.showsEverything = showsEverything
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: "settingsJourneyState")
    }

    // MARK: - Runtime state

    /// Seed the state that has no defaults key, once `AppState` exists.
    @MainActor
    static func seedRuntime(_ appState: AppState) {
        guard isActive else { return }

        if wantsFieldAssist {
            // Asserted again, and deliberately: see `applyFieldAssistSwitch`. The gating cache is
            // main-actor state, so it is re-read here rather than beside the grant that made it
            // stale.
            applyFieldAssistSwitch()
            VaultRegistry.shared.resetCache()
        }

        if isSet(.seedMyDay) {
            appState.myDayService.seedForUITest(seededDay())
        }

        if isSet(.vaultReceivedBadge) {
            seedReceivedVault()
        }

        if wantsVaultLinkReview {
            // The review is reached the way a reader reaches it: the link is opened, the site is
            // approved, the archive comes down (from the fixture) and the sheet shows what the
            // pipeline made of it.
            let link = appState.vaultLink
            Task { @MainActor in
                link.open("https://\(UITestVaultFixture.host)/d/demo/acme.vaultarchive")
                await link.approveFetch()
            }
        }

        if isSet(.seedConversations) {
            seedConversations(appState)
        }

        if isSet(.seedFieldHistory) || isSet(.seedFieldJob) || isSet(.seedFieldPhotos)
            || isSet(.seedFieldClips) || isSet(.seedFieldSignOff) || isSet(.seedFieldSends) {
            // Deferred by one runloop turn on purpose. Starting a session builds the vault's model
            // and parts indexes on the main thread, and doing that inside launch pushes a cold
            // first launch of a large Debug build towards the watchdog — which shows up as an app
            // that "launched" and has no UI. The tab itself does not wait on this: its visibility
            // comes from the switch and the entitlement, both already set.
            Task { @MainActor in seedFieldJobs(appState) }
        }

        if isSet(.seedCaptions) {
            seedCaptions(appState)
            // Re-applied on a tick rather than written once. With no glasses to talk to, the app
            // correctly decides the wearer is away and *suspends* captions a few seconds in, which
            // clears the live line and reshapes the overlay — and a screen that changes shape while
            // an audit is walking it produces findings about a layout that has already gone (a
            // caption measured for contrast against the canvas, because the scrim it actually sits
            // on left with the rest of the panel). That is the app behaving correctly and the
            // *seed* being too short-lived, and it stayed invisible while this surface's contrast
            // was deferred.
            //
            // Still only state: every tick writes exactly what the initial seed wrote, and only
            // when the app has cleared it. Nothing branches on this timer, and none of it exists
            // outside a Debug build launched with `-OGUITest`.
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak appState] _ in
                guard let appState else { return }
                MainActor.assumeIsolated { seedCaptions(appState) }
            }
        }
    }

    /// A full card: the three rows the home surface draws plus the ones behind "See all", with a
    /// long title in the mix because a row that wraps is what makes the card tall enough to test
    /// the layout that has to hold it.
    private static func seededDay() -> MyDaySnapshot {
        let now = Date()
        func item(_ id: String, _ kind: MyDayKind, _ title: String, _ detail: String,
                  _ urgency: MyDayUrgency, in minutes: Int) -> MyDayItem {
            MyDayItem(id: .init(source: .calendar, rawValue: id), kind: kind, title: title,
                      detail: detail, dueAt: now.addingTimeInterval(TimeInterval(minutes * 60)),
                      urgency: urgency, actions: [.open])
        }

        return MyDaySnapshot(
            generatedAt: now,
            period: .morning,
            headline: "Four things today, first one in 25 minutes.",
            items: [
                item("standup", .event, "Design review with the hardware team",
                     "9:30 AM · Meeting room 2, second floor", .immediate, in: 25),
                item("call", .event, "Call back the supplier about the lens order",
                     "11:00 AM", .important, in: 120),
                item("errand", .reminder, "Pick up the replacement charging case",
                     "Due today", .upcoming, in: 300),
                item("write-up", .reminder, "Send the field notes from yesterday's test",
                     "Due today", .upcoming, in: 400),
            ],
            sourceStates: MyDaySource.allCases.map(MyDaySourceState.available),
            nextRefreshAt: now.addingTimeInterval(900)
        )
    }

    /// Two finished conversations, the older one long enough to have to scroll.
    ///
    /// Written through the store's own `startThread`/`appendMessage`, so what lands on disk is
    /// exactly what a real session would have left — and then ended, which is the state a wearer
    /// is actually in when they reach for the switcher: a thread worth resuming and nothing
    /// active.
    ///
    /// Deterministic: the conversations file lives in Documents and outlives the defaults wipe, so
    /// this clears before it seeds rather than piling a fresh pair on every launch.
    @MainActor
    private static func seedConversations(_ appState: AppState) {
        let store = appState.conversationStore
        guard !store.isLocked else { return }
        store.deleteAllThreads()

        store.startThread(mode: AppMode.direct.rawValue)
        for (question, answer) in longExchange {
            store.appendMessage(role: "user", content: question)
            store.appendMessage(role: "assistant", content: answer)
        }
        store.endThread()

        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "What time does the hardware store close?")
        store.appendMessage(role: "assistant",
                            content: "It closes at 5:30 today, and it's about eleven minutes away.")
        store.endThread()
    }

    /// Long enough that the panel's page has to scroll, with one reply that wraps to several
    /// lines — the two things a fixed-height transcript has to survive.
    private static let longExchange: [(String, String)] = [
        ("What's the flashing on the roof made of?",
         "It's galvanised steel, and the section above the valley has started to lift."),
        ("Is that something I can fix myself?",
         "The lifted section can be re-fastened with roofing screws and butyl tape, which is a "
         + "morning's work if you're comfortable on the roof. The valley itself is worth leaving "
         + "to a roofer: if the underlay below it has torn, re-fastening the flashing over the "
         + "top just hides the leak until the next heavy rain."),
        ("What would a roofer charge for that?",
         "For a single valley, usually a call-out plus an hour or two of labour."),
        ("Remind me what tape you said.",
         "Butyl tape — the black rubbery kind, not the foil-faced flashing tape."),
    ]

    // MARK: - Field Assist jobs

    /// Wipe `Documents/FieldSessions`, so a seeded launch starts from no jobs at all.
    ///
    /// Runs before anything touches `FieldSessionService.shared`, which reads the directory in its
    /// initialiser. Only ever under `-OGUITest`, and only alongside a Field Assist flag.
    /// Install the fixture vault through the real installer and record the receipt a link import
    /// writes, so the Custom Vaults row renders its badge from the same sidecar production reads.
    @MainActor
    private static func seedReceivedVault() {
        VaultImporter.uninstall(id: UITestVaultFixture.vaultId)
        Task { @MainActor in
            _ = try? await VaultLinkInstaller.install(
                .init(files: UITestVaultFixture.files(),
                      receipt: UITestVaultFixture.receipt(signed: false)))
            VaultRegistry.shared.reloadUserManifests()
            VaultRegistry.shared.resetCache()
        }
    }

    private static func clearFieldSessions() {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(
            at: documents.appendingPathComponent("FieldSessions", isDirectory: true))
    }

    /// One finished job, and — with `.seedFieldJob` — one open one on top of it.
    ///
    /// Written through the service's own API, so what lands on disk is exactly what a real visit
    /// would have left: a session record, an audit log, a job number recorded through the intake,
    /// and tasks in the states a technician's decisions put them in.
    @MainActor
    private static func seedFieldJobs(_ appState: AppState) {
        let sessions = FieldSessionService.shared
        let vaultId = Config.fieldAssistDefaultVaultId
        guard VaultRegistry.shared.isUnlocked(vaultId) else { return }
        guard sessions.activeSession == nil else { return }

        // The finished one, so the past-job list and its page have something in them.
        if (try? sessions.startSession(vaultId: vaultId, assetId: nil, mode: .aiOnly,
                                       jobReference: "1004")) != nil {
            if let task = try? sessions.addOperatorTask(title: "Replaced the condensate trap",
                                                        why: "Blocked; water in the burner box") {
                _ = try? sessions.completeTask(id: task.id, note: "New trap fitted and tested.")
            }
            // A finished job needs its own evidence, and its own *decision* about it: the past-job
            // page shows the selection that went out rather than a fresh proposal, so seeding the
            // pictures without one would show a screen no technician ever saw.
            if isSet(.seedFieldPhotos) {
                attach(sessions, colour: .systemTeal, caption: "Blocked trap, as found",
                       origin: .photoLog, blurred: true)
                attach(sessions, colour: .systemGreen, caption: "New trap fitted",
                       origin: .photoLog, blurred: true)
                var chosen = sessions.evidenceSelection()
                if let first = chosen.entries.first { chosen.setRole(.fault, for: first.itemId) }
                if let last = chosen.entries.last, chosen.entries.count > 1 {
                    chosen.setRole(.fix, for: last.itemId)
                }
                sessions.setEvidenceSelection(chosen.confirmed())
            }
            if isSet(.seedFieldSignOff), let record = sessions.workRecord() {
                sessions.recordSignOff(
                    CustomerSignOff(customerName: "Dana Okafor",
                                    comment: "Happy with the work; please send the invoice to accounts.",
                                    method: .drawn,
                                    summaryLines: record.customerSummaryLines),
                    pngData: signaturePNG())
            }
            if isSet(.seedFieldSends), let record = sessions.workRecord() {
                seedDebrief(sessions, sessionId: record.sessionId)
            }
            _ = try? sessions.endSession(outcome: .resolved)
            if isSet(.seedFieldSends) { seedStagedSends(appState, sessions: sessions) }
        }

        guard isSet(.seedFieldJob) else { return }

        // The open one. Through the guided flow, so the binding, the intake and the thread title
        // are the ones the shipped path produces.
        guard (try? appState.guidedJobFlow.startJob(vaultId: vaultId, assetId: nil, mode: .aiOnly,
                                                    jobReference: "1005")) != nil else { return }
        if let model = sessions.modelIndex.models.first {
            sessions.setEquipment(EquipmentIdentity(model: model, token: model.name, source: .manual))
        }
        if let done = try? sessions.addOperatorTask(title: "Checked the pressure switch tubing",
                                                    why: "Intermittent lockout on ignition") {
            _ = try? sessions.completeTask(id: done.id, note: "Tubing clear; switch held at 0.6 in w.c.")
        }
        _ = try? sessions.addOperatorTask(title: "Clean the flame sensor",
                                          why: "Signal reading low")

        if isSet(.seedFieldPhotos) {
            // Three pictures with the shape the review has to cope with: one logged on the job
            // (ticked by default), one taken by the assistant (offered, not assumed), and one
            // captured while the face blur was on, so the per-item label is on screen for the
            // audit to measure.
            attach(sessions, colour: .systemTeal, caption: "Pressure switch tubing, reconnected",
                   origin: .photoLog, blurred: false)
            attach(sessions, colour: .systemOrange, caption: "Flame sensor before cleaning",
                   origin: .capture, blurred: false)
            attach(sessions, colour: .systemIndigo, caption: "Nameplate", origin: .photoLog,
                   blurred: true)
        }

        guard isSet(.seedFieldClips) else { return }
        // Two clips, and an office address so the report has a channel with a size limit at all.
        // One fits that limit and one does not, which is the only way the "too large — share it
        // separately" row on a finished job is ever on screen to be audited.
        var delivery = DeliverySettings.load()
        if delivery.emailRecipients.isEmpty { delivery.emailRecipients = ["office@example.com"] }
        delivery.save()
        attachClip(sessions, caption: "Compressor short-cycling", seconds: 12, bytes: 640_000)
        attachClip(sessions, caption: "Fan wobble at full speed", seconds: 28,
                   bytes: 21 * 1024 * 1024)
    }

    /// One saved debrief on the finished job (Plan FO P3b).
    ///
    /// Written through the shipping `recordDebrief`, with the citations a real summary carries and
    /// one item marked "reported, not verified" — which is the label the past job's page has to
    /// render, and the one an audit is actually looking at.
    @MainActor
    private static func seedDebrief(_ sessions: FieldSessionService, sessionId: String) {
        let turns = [
            JobDebrief.Turn(id: "seed-t1", text: "the drier looked wet when I pulled the panel",
                            at: Date()),
            JobDebrief.Turn(id: "seed-t2", text: "base should send somebody back for the drier",
                            at: Date())
        ]
        let summary = DebriefSummary(categories: [
            .findings: [DebriefSummary.Item(text: "Drier looked wet behind the panel",
                                            sourceTurnIds: ["seed-t1"]),
                        DebriefSummary.Item(text: "Checked the sight glass",
                                            sourceTurnIds: ["seed-t1"],
                                            flag: .reportedNotVerified)],
            .forBase: [DebriefSummary.Item(text: "Send somebody back for the drier",
                                           sourceTurnIds: ["seed-t2"])]
        ])
        sessions.recordDebrief(
            JobDebrief.make(summary: summary, turns: turns,
                            provenance: AIProvenance(modelIdentifier: "seeded-model",
                                                     providerClass: .cloud,
                                                     promptVersionDigest: "sha256:seed"),
                            threadId: nil),
            sessionId: sessionId)
    }

    /// Three reports waiting for a thumb, so the Job tab's Send card has something to draw.
    ///
    /// Staged, never sent — which is the whole point of the card, and is what makes this safe to
    /// seed: nothing here can put anything on a wire.
    @MainActor
    private static func seedStagedSends(_ appState: AppState, sessions: FieldSessionService) {
        var delivery = DeliverySettings.load()
        if delivery.emailRecipients.isEmpty { delivery.emailRecipients = ["office@example.com"] }
        delivery.save()
        let finished = sessions.history.filter { $0.endedAt != nil }
        for (index, session) in finished.prefix(1).enumerated() {
            _ = index
            let number = session.jobReference.map { "Job \($0)" } ?? JobTabModel.noJobNumber
            for (offset, kind) in [QueuedSend.DocumentKind.report, .addendum, .report].enumerated() {
                appState.jobSends.queue.append(QueuedSend(
                    sessionId: session.id, jobNumber: number, documentKind: kind,
                    channel: offset == 1 ? .messages : .email,
                    recipients: offset == 1 ? ["+64211234567"] : ["office@example.com"],
                    recipientSource: .deliverySettings,
                    createdAt: Date(timeIntervalSinceNow: -Double(300 - offset * 60)),
                    state: .staged))
            }
        }
    }

    /// One seeded evidence photo, drawn rather than captured.
    ///
    /// A flat colour is enough: the review is being audited for its labels, its touch targets and
    /// its contrast, none of which depend on what the photograph is of — and a bundled JPEG would
    /// put test fixtures into the shipping app for no gain.
    @MainActor
    private static func attach(_ sessions: FieldSessionService, colour: UIColor, caption: String,
                               origin: JobMediaItem.Origin, blurred: Bool) {
        let size = CGSize(width: 480, height: 360)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        _ = sessions.attachPhoto(data, caption: caption, origin: origin, filterWasOn: blurred)
    }

    /// A seeded signature: two strokes drawn in-process, so the acceptance block has a real
    /// picture in it without a fixture PNG riding along in the shipping app.
    private static func signaturePNG() -> Data? {
        let size = CGSize(width: 600, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            let path = UIBezierPath()
            path.lineWidth = 6
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: 40, y: 150))
            path.addCurve(to: CGPoint(x: 260, y: 90),
                          controlPoint1: CGPoint(x: 90, y: 30), controlPoint2: CGPoint(x: 180, y: 190))
            path.addCurve(to: CGPoint(x: 540, y: 120),
                          controlPoint1: CGPoint(x: 340, y: 20), controlPoint2: CGPoint(x: 460, y: 180))
            path.stroke()
        }
    }

    /// One seeded clip: a drawn poster frame and a placeholder for the video itself.
    ///
    /// The bytes are not a real MP4 and are not meant to be — nothing in the audit plays one, and
    /// encoding a video at launch would slow a cold start for no gain. What has to be right is the
    /// catalogue entry the grid reads: a clip kind, a length, a size and a poster.
    @MainActor
    private static func attachClip(_ sessions: FieldSessionService, caption: String,
                                   seconds: TimeInterval, bytes: Int) {
        let size = CGSize(width: 480, height: 360)
        let poster = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBrown.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        _ = sessions.attachClip(Data(repeating: 0, count: bytes),
                                posterJPEG: poster.jpegData(compressionQuality: 0.8),
                                caption: caption, durationSeconds: seconds,
                                filterWasOn: true, cutShort: false)
    }

    /// The lines a real session would have produced. Two of the three carry a diarized speaker, so
    /// the speaker chip is on screen for the audit to measure — without one the chip never renders
    /// and its touch target, which two phases deferred, would be gated by nothing at all.
    ///
    /// Idempotent: a no-op while the seeded state is already on screen.
    @MainActor
    private static func seedCaptions(_ appState: AppState) {
        let captions = appState.ambientCaptions
        guard !captions.isActive
            || captions.currentCaption.isEmpty
            || captions.captionHistory.count != 3 else { return }

        let now = Date()
        captions.captionHistory = [
            .init(text: "That's the one on the left, next to the window.",
                  timestamp: now.addingTimeInterval(-8), seq: 3, speaker: 1),
            .init(text: "We should be there by about half past.",
                  timestamp: now.addingTimeInterval(-16), seq: 2, speaker: 0),
            .init(text: "Did you want the long or the short version?",
                  timestamp: now.addingTimeInterval(-24), seq: 1),
        ]
        captions.currentCaption = "I'll send the details over this afternoon."
        captions.isActive = true
    }
}
#endif

#if DEBUG
/// The retired one-time unlock, as evidence. Used only by `UITestSupport.retiredUnlockOnly`, to
/// render the grandfathered owner's state; it grants strictly less than any live provider would.
private struct RetiredUnlockOnlyProvider: FieldAssistEntitlementProvider {
    func evidence() -> FieldAssistEntitlementEvidenceSet {
        FieldAssistEntitlementEvidenceSet(evidence: [
            .verifiedStoreProduct(productID: StoreKitService.fieldAssistId, expiration: nil)
        ])
    }
}
#endif
