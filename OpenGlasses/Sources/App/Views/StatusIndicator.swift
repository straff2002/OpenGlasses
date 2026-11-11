import SwiftUI
import UIKit

/// Center status panel — card showing current state + quick action buttons.
///
/// The panel grows vertically as the user adds more quick actions.
/// Status info at top, action grid below.
struct StatusIndicator: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject var openClawBridge: OpenClawBridge
    var compact = false
    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The assistant's chosen name (Plan FE P6) — empty when the wearer never set one.
    @AppStorage("assistantDisplayName") private var storedAssistantName = ""
    /// Push-to-talk — the same key `Config.silentMode` writes. When it is on, the wake phrase being
    /// off is the wearer's choice and the card does not mention it.
    @AppStorage("silentMode") private var pushToTalk = false
    @State private var showDisconnectConfirm = false
    @State private var showDetails = false
    /// The open Field Assist job, for the job pill. Observed so pausing, resuming or ending the
    /// job from anywhere — the Job tab, a voice turn, a relaunch — redraws the card.
    @ObservedObject private var fieldSessions = FieldSessionService.shared

    /// The status tile, and the glyph inside it. Scaled rather than fixed so the
    /// tile keeps its proportion to the two lines of text beside it at every
    /// Dynamic Type size instead of shrinking against them.
    @ScaledMetric(relativeTo: .body) private var statusTile: CGFloat = 52
    @ScaledMetric(relativeTo: .callout) private var statusGlyph: CGFloat = 28
    /// The connection pills' logo, which scales with the type beside it.
    @ScaledMetric(relativeTo: .caption) private var pillGlyph: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var statusDot: CGFloat = 5

    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode.usesOpenAIRealtimeTransport }
    private var isRealtime: Bool { appState.currentMode.isRealtime }

    @ViewBuilder
    var body: some View {
        Group {
            if compact || showDetails {
                compactCard
            } else {
                fullCard
            }
        }
        .sheet(isPresented: $showDetails) { details }
    }

    private var compactCard: some View {
        let wakeOff = SessionCardWakeWordNotice.shows(
            listeningEnabled: appState.listeningEnabled, pushToTalk: pushToTalk)
        return Button { showDetails = true } label: {
            HStack(spacing: 10) {
                Group {
                    if iconName == "AvenkinMark" { LogoIcon(size: 24) }
                    else { Image(systemName: iconName).font(.title3) }
                }
                .foregroundStyle(OGTheme.tintedAccentLabel(ringColor))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel).font(.headline)
                    Group {
                        if wakeOff { Text("Wake phrase off") }
                        else { Text(liveEndNotice ?? modeLabel) }
                    }
                    .font(.caption)
                    .foregroundStyle(OGTheme.secondaryLabel)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if isRealtime, let chip = appState.cameraService.readiness.statusChip {
                    Text(chip.label)
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(chip.isHealthy ? OGTheme.okLabel : OGTheme.warnLabel)
                }
                Image(systemName: "chevron.forward").font(.caption)
                    .foregroundStyle(OGTheme.secondaryLabel)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .accessibilityLabel(spokenStatus)
        .accessibilityValue(wakeOff ? String(localized: "Wake phrase off") : (liveEndNotice ?? ""))
        .accessibilityHint("Opens session details and connection controls.")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("compact-session-status")
    }

    private var details: some View {
        NavigationStack {
            ScrollView { fullCard.padding(.vertical, 12) }
                .navigationTitle("Session status")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDetails = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// Two rows: the state and the model on one line, then every pill — beside them, on the right,
    /// the status mark (`statusMark`). Once a small tile at the start of the first row; then every pill —
    /// mode, wake word, job, glasses, OpenClaw — in one row that wraps only when it must. It used
    /// to be four bands (a 48pt tile over two lines, a full-width wake-word line, a job row, a
    /// footer), and the conversation under it — what a technician scrolls back through for a
    /// number they missed — got what was left.
    private var fullCard: some View {
        // The text and the pills on the left, the status mark large on the right beside both rows:
        // the card's spare width used to sit empty at the end of the status line.
        HStack(alignment: .center, spacing: 0) {
        VStack(spacing: 0) {
            // Status row
            HStack(spacing: 10) {
                // The state and the model as one run of text: "Ready  Voice · OpenAI (GPT)".
                // Uncapped — the state of the session is the one thing this card exists to
                // report and the line can be a whole error message — so it wraps, at word
                // boundaries, and the model follows it rather than claiming a line of its own.
                // At accessibility sizes the run already wraps over several lines, so sharing one
                // saves nothing — and one Text in two fonts is measured by the audit as if it were
                // all the larger one, which it reports as clipped. There the two stack instead.
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusLabel)
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Color(.label))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(modeLabel)
                                .font(.caption)
                                .foregroundStyle(OGTheme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(statusLine)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // FD P0: a green dot and the word CAM used to appear on `isStreaming`
                // alone, which a paused or stalled stream also satisfies — so the one
                // indicator on this card said the camera was fine in precisely the states
                // it was not. The chip now carries the phase, and the dot is green only
                // when pictures are actually flowing.
                if isRealtime, let chip = appState.cameraService.readiness.statusChip {
                    HStack(spacing: 3) {
                        Circle().fill(chip.isHealthy ? OGTheme.ok : OGTheme.warn)
                            .frame(width: statusDot, height: statusDot)
                            .accessibilityHidden(true)
                        Text(chip.label)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundStyle(chip.isHealthy ? OGTheme.okLabel
                                                            : OGTheme.warnLabel)
                    }
                    .accessibilityLabel(chip.spoken)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            // One stop, one sentence. Split across several Texts it read as "Listening…",
            // "Voice middle dot Claude", "Camera streaming" — three swipes to assemble a fact
            // that is one glance for a sighted user. `.updatesFrequently` is the non-intrusive
            // half of the announcement design: VoiceOver re-reads this while focus is on it,
            // and stays quiet when it isn't, because the transitions themselves are narrated
            // from the state machine.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenStatus)
            .accessibilityAddTraits(.updatesFrequently)

            // Plan HY P1: a session that ended itself for want of the wearer says so, rather than
            // the card simply reading "Ready" with no account of where the session went.
            if let notice = liveEndNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(OGTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            // Tool call / reconnecting
            if isGemini && session.toolCallStatus.isActive {
                toolCallPill(session.toolCallStatus.displayText, color: accent)
                    .padding(.top, 6)
            } else if !isRealtime && appState.llmService.toolCallStatus.isActive {
                toolCallPill(appState.llmService.toolCallStatus.displayText, color: accent)
                    .padding(.top, 6)
            }

            if isGemini && session.reconnecting {
                reconnectingLabel.padding(.top, 6)
            }
            if isOpenAI && openAISession.reconnecting {
                reconnectingLabel.padding(.top, 6)
            }

            // The pill row: the mode, then whatever is worth a tap — the wake word when it is off,
            // an open job, the glasses when this phone has a pair, OpenClaw when it is set up.
            // Formerly a footer plus two rows of their own; one flow now, which keeps every pill
            // at its full word and moves a pill to a second line rather than cutting it ("Job p…"
            // is the one thing the job pill must never read). At accessibility sizes the same
            // flow simply wraps more — one layout throughout, so the pills keep their identity
            // across a text-size change (swapping subtrees reads to the accessibility audit as
            // text that stopped scaling).
            PillFlowLayout(spacing: 6, lineSpacing: 0) {
                activeModeBadge
                // The wake phrase switched off somewhere else — Lock Screen, Control Center, a
                // widget, Siri — while the card would otherwise still say "Ready"
                // (`SessionCardWakeWordNotice`).
                if SessionCardWakeWordNotice.shows(listeningEnabled: appState.listeningEnabled,
                                                   pushToTalk: pushToTalk) {
                    wakeWordOffChip
                }
                // An open job, running or paused (`SessionCardJobPill`).
                jobPill
                glassesPill
                // Instant Replay is keeping recent video from the glasses camera. Shown whenever
                // the buffer runs, so it is never invisible.
                if appState.instantReplay.isRunning {
                    replayMark
                }
                if Config.isOpenClawConfigured {
                    openClawPill
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            // The tappable pills carry a full 44pt target, taller than the capsules they draw,
            // so the target is the row's breathing room and the row adds almost none of its own.
            .padding(.bottom, 2)
        }
            statusMark
                .padding(.trailing, 14)
                .padding(.vertical, 10)
        }
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        // A group *name*, not a summary. The card's label used to restate the status and the
        // mode, which the row above now says properly — so a VoiceOver user heard the whole
        // sentence on entering the group and then again on the first swipe inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session status")
    }

    /// The session's mark: the Avenkin logo while it is ready, the state's own glyph otherwise, on a
    /// wash of the state's hue with a ring of it — the card's connection indicator at a glance.
    /// Capped at half again its size, so at accessibility text sizes the text keeps the width.
    private var statusMark: some View {
        let side = min(statusTile, 52 * 1.5)
        return ZStack {
            Circle()
                .fill(ringColor.opacity(OGTheme.Opacity.accentPillFill))
            Circle()
                .strokeBorder(ringColor.opacity(0.55), lineWidth: 2)
            Group {
                if iconName == "AvenkinMark" {
                    LogoIcon(size: min(statusGlyph, 28 * 1.5))
                } else {
                    Image(systemName: iconName)
                        .font(.title2.weight(.semibold))
                }
            }
            // The tile paints a hue on a wash of itself, which is the
            // case `tintedAccentLabel` exists for: it nudges any hue to
            // the nearest value that clears AA on its own tint, against
            // the *stronger* wash, so the 0.12 pill fill is covered too.
            .foregroundStyle(OGTheme.tintedAccentLabel(ringColor))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// The status row's text: the state in the headline face, then the model in the caption face,
    /// one run so it wraps as a sentence. An `AttributedString` rather than `Text` concatenation
    /// (deprecated) or a localised format (a catalog key for two values the app already localises).
    private var statusLine: AttributedString {
        var state = AttributedString(statusLabel)
        state.font = Font.system(.headline, design: .rounded).weight(.semibold)
        state.foregroundColor = Color(.label)
        var model = AttributedString("\u{2002}" + modeLabel)
        model.font = Font.caption
        model.foregroundColor = OGTheme.secondaryLabel
        return state + model
    }

    // MARK: - Connection pills (merged from the old StatusPillsRow)

    /// `nil` while this phone has no glasses added — the card then says nothing about glasses.
    private var glassesPillPresentation: SessionCardGlassesPill.Presentation? {
        SessionCardGlassesPill.presentation(link: appState.glassesPhase,
                                            stoodDown: appState.glassesStoodDown,
                                            glassesSupported: GlassesSupportPolicy.isSupported)
    }

    @ViewBuilder
    private var glassesPill: some View {
        if let presentation = glassesPillPresentation {
            let color = labelColor(presentation.tint)

            Button {
                didTapGlassesPill(presentation.action)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eyeglasses")
                        .font(.caption)
                        .foregroundStyle(color)
                    // Hidden at accessibility sizes: the pill shrinks to the symbol alone rather
                    // than taking a line of the pill row for itself; the label still says it.
                    if !typeSize.isAccessibilitySize {
                        Text(presentation.word)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color)
                            .lineLimit(1)
                    }
                    if presentation.showsLiveDot {
                        Circle().fill(OGTheme.ok).frame(width: statusDot, height: statusDot)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(in: .capsule)
                // The drawn capsule stays the size the signature draws it; what
                // grows is the target around it. A pill that *looked* 44pt would be
                // a different status card — this is the same card with a control a
                // finger can actually land on, and it is the reason the pill row
                // gave up its bottom padding above.
                //
                // A *floor*, and deliberately not a `@ScaledMetric` one. 44pt is an
                // absolute minimum for a fingertip, not a type-relative measure: a
                // reader who turns the text up has not grown their thumb, and a
                // scaled 44 reaches about 130pt at AX5, which is a third of the
                // screen for a status dot. The drawn pill still grows on its own,
                // and when it outgrows 44 this stops applying.
                .frame(minWidth: OGMetrics.minTouchTarget,
                       minHeight: OGMetrics.minTouchTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .confirmationDialog("Disconnect Glasses", isPresented: $showDisconnectConfirm) {
                Button("Disconnect", role: .destructive) {
                    appState.disconnectGlasses()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stop mic, camera, and TTS. Gateway tasks keep running.")
            }
            // Without `children: .ignore` the element is the union of the pill's children rather
            // than the pill itself, so VoiceOver's focus ring landed inside the capsule instead of
            // around it.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityHint(presentation.accessibilityHint)
        }
    }

    /// `SessionCardGlassesPill.Action` → what actually happens. A tap while the glasses are merely
    /// away used to run `AppState.connectGlasses()` — a 15 s wait ending in the SDK's own error
    /// text, for a tap Greig made by accident. It now posts a plain, transient hint instead
    /// (`NoticeCenter`, the same surface every other glasses condition already posts to) and never
    /// starts that wait. The hint says why the glasses are away (Plan HX P3). `connectGlasses()`
    /// stays reserved for the connect rows: onboarding's, and Devices & Privacy › Glasses.
    private func didTapGlassesPill(_ action: SessionCardGlassesPill.Action) {
        switch action {
        case .disconnect:
            showDisconnectConfirm = true
        case .resume:
            appState.resumeGlasses()
        case .hint:
            NoticeCenter.shared.post(
                SessionCardGlassesPill.awayHint(for: appState.glassesReachability.diagnosis),
                severity: .advisory, source: .glasses)
        case .none:
            break
        }
    }

    // MARK: - Job pill

    /// `nil` with no Field Assist job open — the card then carries no job pill at all.
    private var jobPillPresentation: SessionCardJobPill.Presentation? {
        SessionCardJobPill.presentation(session: fieldSessions.activeSession)
    }

    /// The glasses pill's capsule, for the job. One difference: the word is never dropped at
    /// accessibility sizes. The glasses pill can fall back to its symbol because "glasses" is all
    /// the symbol has to say; here the word *is* the news — running or paused — so it wraps instead.
    @ViewBuilder
    private var jobPill: some View {
        if let presentation = jobPillPresentation {
            let color = labelColor(presentation.tint)

            Button {
                didTapJobPill(presentation.action)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: presentation.systemImage)
                        .font(.caption)
                        .foregroundStyle(color)
                    Text(presentation.word)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(in: .capsule)
                // The same 44pt floor as the glasses pill, for the same reasons (see there).
                .frame(minWidth: OGMetrics.minTouchTarget,
                       minHeight: OGMetrics.minTouchTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityHint(presentation.accessibilityHint)
        }
    }

    /// `SessionCardJobPill.Action` → what actually happens. Through `AppState.openJobs`, the one
    /// route every surface uses to send the wearer to a job, so the job's page is pushed over the
    /// list and Back returns to it.
    private func didTapJobPill(_ action: SessionCardJobPill.Action) {
        switch action {
        case .openJob:
            appState.openJobs(.currentJob)
        }
    }

    private var openClawPill: some View {
        // A 5pt dot reads from the uncorrected hue; the word beside it is what
        // carries the state, so the colour is reinforcement rather than signal.
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected: return (OGTheme.ok, String(localized: "Connected"))
            case .checking: return (OGTheme.warn, String(localized: "Checking"))
            case .unreachable: return (OGTheme.error, String(localized: "Unreachable"))
            case .notConfigured: return (OGTheme.secondaryLabel, String(localized: "Not Set Up"))
            }
        }()

        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: statusDot, height: statusDot)
                .accessibilityHidden(true)
            Text("OpenClaw")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenClaw: \(label)")
    }

    // MARK: - Active Mode Badge

    /// The mode, as the first pill: dot, persona symbol, name. "Active mode:" / "Mode:" is no
    /// longer drawn — the dot and the name's colour carry the state, and the line it cost was the
    /// room the rest of the row needed — but VoiceOver still hears it, in the label.
    private var activeModeBadge: some View {
        let persona = appState.activePersona
        // No persona selected: the assistant's own name, which the wearer may have chosen. Read
        // through `@AppStorage` so the badge redraws when Settings changes it, and through the
        // same validator `Config` uses so an unusable stored value, or a former default, still
        // reads as the default name.
        let name = persona?.name
            ?? AssistantIdentity.sanitized(storedAssistantName)
                .flatMap { AssistantIdentity.isDefaultName($0) ? nil : $0 }
            ?? AssistantIdentity.defaultName
        let icon = persona?.icon ?? "sparkles"
        let dot = modeDot
        let isActive = dot.readsAsActiveMode
        // The dot is a fill and the name beside it is text — the same state, two
        // roles, and the raw success hue is unreadable as the second one.
        let dotColor = dotFillColor(dot.tint)
        let nameColor = labelColor(dot.tint)

        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: statusDot, height: statusDot)
                .accessibilityHidden(true)
            Group {
                if icon == "AvenkinMark" {
                    LogoIcon(size: pillGlyph)
                } else {
                    Image(systemName: icon)
                        .font(.caption.weight(.medium))
                }
            }
            .foregroundStyle(nameColor)
            .accessibilityHidden(true)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(nameColor)
                // A persona name is user-supplied. Wrapping is the only honest
                // option: truncating loses the one word that says which mode is
                // running.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        // Not a control, so no 44pt target; the row's height comes from the pills that are.
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        // Read-only, and said so: an element with no traits is audited as something to tap, and
        // a drawn pill is smaller than a fingertip target by design.
        .accessibilityAddTraits(.isStaticText)
        // Disconnected, the interpolation used to open with an empty string, so the line began
        // with a pause and read as " mode: OpenGlasses".
        .accessibilityLabel(isActive ? "Active mode: \(name)" : "Mode: \(name)")
    }

    /// The row's state — `SessionCardModeDot` — read from whichever session is live. Pure mapping
    /// lives in `SessionCardModeDot`/`TalkEntryPolicyTests`; this is just which inputs apply.
    private var modeDot: SessionCardModeDot {
        if isGemini {
            return .realtime(sessionActive: session.isActive,
                             phase: realtimePhase(session.connectionState),
                             muted: session.micMuted,
                             reconnecting: session.reconnecting)
        } else if isOpenAI {
            return .realtime(sessionActive: openAISession.isActive,
                             phase: realtimePhase(openAISession.connectionState),
                             muted: openAISession.micMuted,
                             reconnecting: openAISession.reconnecting)
        } else {
            return .direct(muted: appState.micMuted)
        }
    }

    private func realtimePhase(_ state: RealtimeConnectionState) -> SessionCardRealtimePhase {
        switch state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .settingUp: return .settingUp
        case .ready: return .ready
        case .error: return .error
        }
    }

    /// `SessionCardTint` → a status-dot fill. Bare hues (`OGTheme.ok`/`.warn`/`.error`/`.inactive`):
    /// a filled circle doesn't carry text, so it is exempt from the label-contrast correction below.
    private func dotFillColor(_ tint: SessionCardTint) -> Color {
        switch tint {
        case .ok: return OGTheme.ok
        case .warn: return OGTheme.warn
        case .error: return OGTheme.error
        case .quiet: return OGTheme.inactive
        }
    }

    /// `SessionCardTint` → a colour for text or a glyph, corrected to clear AA on the card
    /// (`OGTheme`'s `...Label` tokens — the bare hues above measure far too light as text).
    private func labelColor(_ tint: SessionCardTint) -> Color {
        switch tint {
        case .ok: return OGTheme.okLabel
        case .warn: return OGTheme.warnLabel
        case .error: return OGTheme.errorLabel
        case .quiet: return OGTheme.secondaryLabel
        }
    }

    // MARK: - Computed Properties

    /// The glasses' line when it, not the session, is the headline — only while the wearer's own
    /// glasses connect is under way (`SessionCardGlassesHeadline`). Phone-first: glasses away
    /// otherwise leave the card reporting the session the phone is carrying.
    private var glassesHeadline: String? {
        SessionCardGlassesHeadline.headline(connectAttemptInFlight: appState.isConnectingGlasses,
                                            link: appState.glassesPhase,
                                            connectionStatus: appState.glassesService.connectionStatus)
    }

    private var iconName: String {
        if glassesHeadline != nil {
            return "AvenkinMark"
        }

        if appState.glassesIdle {
            return "moon.zzz.fill"
        }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return "speaker.wave.3.fill"
            case .ready: return "AvenkinMark"
            case .connecting, .settingUp: return "antenna.radiowaves.left.and.right"
            case .error: return "exclamationmark.triangle.fill"
            case .disconnected: return "AvenkinMark"
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return "speaker.wave.3.fill"
            case .ready: return "AvenkinMark"
            case .connecting, .settingUp: return "antenna.radiowaves.left.and.right"
            case .error: return "exclamationmark.triangle.fill"
            case .disconnected: return "AvenkinMark"
            }
        } else {
            if appState.isListening { return "ear.fill" }
            if appState.speechService.isSpeaking { return "speaker.wave.3.fill" }
            return "AvenkinMark"
        }
    }

    /// The hue the status tile is built from — the wash is this at the pill-fill
    /// opacity and the glyph is this corrected to read on that wash. Every value
    /// is a palette token so both halves are measurable.
    private var ringColor: Color {
        if glassesHeadline != nil { return OGTheme.inactive }
        if appState.glassesIdle { return OGTheme.inactive }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return OGTheme.warn
            case .ready: return accent
            case .connecting, .settingUp: return OGTheme.warn
            case .error: return OGTheme.error
            case .disconnected: return OGTheme.inactive
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return OGTheme.warn
            case .ready: return accent
            case .connecting, .settingUp: return OGTheme.warn
            case .error: return OGTheme.error
            case .disconnected: return OGTheme.inactive
            }
        } else {
            if appState.isListening { return accent }
            if appState.speechService.isSpeaking { return OGTheme.warn }
            return OGTheme.inactive
        }
    }

    private var statusLabel: String {
        if let glassesHeadline { return glassesHeadline }

        if appState.glassesIdle {
            #if AVENKIN_PHONE_ONLY
            return String(localized: "Idle")
            #else
            return String(localized: "Glasses Idle")
            #endif
        }

        if isGemini {
            if !session.isActive { return String(localized: "Ready") }
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return String(localized: "Speaking...")
            case .ready: return String(localized: "Listening...")
            case .connecting: return String(localized: "Connecting...")
            case .settingUp: return String(localized: "Setting Up...")
            case .error(let msg): return msg
            case .disconnected: return session.reconnecting ? String(localized: "Reconnecting...") : String(localized: "Disconnected")
            }
        } else if isOpenAI {
            if !openAISession.isActive { return String(localized: "Ready") }
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return String(localized: "Speaking...")
            case .ready: return String(localized: "Listening...")
            case .connecting: return String(localized: "Connecting...")
            case .settingUp: return String(localized: "Setting Up...")
            case .error(let msg): return msg
            case .disconnected: return openAISession.reconnecting ? String(localized: "Reconnecting...") : String(localized: "Disconnected")
            }
        } else {
            switch WakeListenerFailurePolicy.directHeadline(
                isListening: appState.isListening,
                isSpeaking: appState.speechService.isSpeaking,
                listenerDown: wakeListenerDown) {
            case .listening: return String(localized: "Listening...")
            case .speaking: return String(localized: "Speaking...")
            case .notListening: return WakeListenerFailurePolicy.headline
            case .ready: return String(localized: "Ready")
            }
        }
    }

    /// Plan KD P1: the wake-word listener is expected and a start of it failed — the card must not
    /// say "Ready" over a microphone nobody is listening on.
    private var wakeListenerDown: Bool {
        WakeListenerFailurePolicy.isDown(failed: appState.wakeListenerFailed,
                                         listeningEnabled: appState.listeningEnabled,
                                         pushToTalk: pushToTalk,
                                         micMuted: appState.micMuted,
                                         inConversation: appState.inConversation,
                                         listenerRunning: appState.wakeWordService.isListening)
    }

    /// Why the selected live mode's last session ended, while none is running (Plan HY P1).
    private var liveEndNotice: String? {
        if isGemini {
            return LiveSessionEndReason.cardNotice(sessionActive: session.isActive,
                                                   reason: session.endReason)
        }
        if isOpenAI {
            return LiveSessionEndReason.cardNotice(sessionActive: openAISession.isActive,
                                                   reason: openAISession.endReason)
        }
        return nil
    }

    private var modeLabel: String {
        if isGemini {
            return "Gemini Live"
        } else if isOpenAI {
            return openAISession.sessionModel?.name ?? Config.realtimeModel(for: appState.currentMode)?.name ?? appState.currentMode.displayName
        } else {
            let model = appState.llmService.activeModelName
            return String(localized: "Voice \u{00B7} \(model)")
        }
    }

    /// The mode as a sentence rather than as displayed: the middot is a visual separator and
    /// VoiceOver reads it aloud as "middle dot", so it becomes the pause it was drawn to be.
    private var spokenModeLabel: String {
        modeLabel.replacingOccurrences(of: " \u{00B7} ", with: ", ")
    }

    /// Status, mode, and — only when it is actually on — the camera, as one spoken line. The
    /// trailing ellipses of "Listening…" are dropped: they mean "ongoing" to the eye and are
    /// read as a stumble.
    private var spokenStatus: String {
        let state = statusLabel
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "\u{2026}", with: "")
        var parts = [state, spokenModeLabel]
        // The spoken line carries the same phase the chip shows. "camera streaming" over a paused
        // camera is the untruth the chip was fixed for, delivered to the user least able to check
        // it against the preview.
        if isRealtime, let chip = appState.cameraService.readiness.statusChip {
            parts.append(chip.spoken)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    /// The wake word is off and expected on (`SessionCardWakeWordNotice`): a chip in the pill row,
    /// tinted like the card's other tappable text. One tap turns listening back on.
    private var wakeWordOffChip: some View {
        Button {
            appState.setListeningEnabled(true)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.slash")
                    .accessibilityHidden(true)
                Text(SessionCardWakeWordNotice.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(OGTheme.tintedAccentLabel(accent))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)
            // The same 44pt floor as the glasses pill, for the same reasons (see there).
            .frame(minWidth: OGMetrics.minTouchTarget, minHeight: OGMetrics.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(SessionCardWakeWordNotice.accessibilityLabel)
        .accessibilityHint(SessionCardWakeWordNotice.accessibilityHint)
    }

    /// The Replay mark: not a button — what it says is that the buffer is running, and the switch
    /// is in Settings › Devices & Privacy › Glasses.
    private var replayMark: some View {
        HStack(spacing: 5) {
            Image(systemName: "gobackward")
                .accessibilityHidden(true)
            Text("Replay")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(OGTheme.secondaryLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .frame(minHeight: OGMetrics.minTouchTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Instant Replay on")
        .accessibilityHint("Keeping recent video from the glasses camera on this phone.")
    }

    private var reconnectingLabel: some View {
        Text("Reconnecting...")
            .font(.caption)
            .foregroundStyle(OGTheme.warnLabel)
    }

    private func toolCallPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7).tint(.primary)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(OGTheme.Opacity.accentFill))
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running: \(text)")
    }

}

