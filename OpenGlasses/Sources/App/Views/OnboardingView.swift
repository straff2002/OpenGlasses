import SwiftUI
import AVFoundation
import CoreLocation
import MWDATCore
import Speech

/// Full-screen onboarding flow — Apple HIG compliant.
///
/// Pages:
///   1. Welcome — what OpenGlasses is, AI transparency disclosure
///   2. Choose Provider — pick an AI provider (large tap targets)
///   3. Access Key — paste key, link to get one, inline validation
///   4. Ready — success, get started
///
/// Design: the system's own language, on the OGDesign foundation — warm canvas,
/// grouped lists for anything list-shaped, standard field affordances, Dynamic
/// Type text styles throughout (no fixed point sizes), and the app accent as the
/// single call-to-action colour. Colour is never the only carrier of meaning:
/// selection, permission state and validation all say what they are in words.
/// Follows Apple Generative AI HIG — discloses AI use, sets expectations,
/// communicates that responses may contain errors.
struct OnboardingView: View {
    @Binding var isVisible: Bool
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Moves VoiceOver to the new page's title on every page change, so the flow
    /// reads from the top instead of leaving focus wherever the last button was.
    @AccessibilityFocusState private var focusedPage: Int?

    @State private var page = 0
    @State private var selectedProvider: LLMProvider?
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var keyValid = false
    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var selectedModelId: String?

    // Sign in with Claude (OAuth) — the no-API-key path for the Anthropic provider. Same
    // service the model editor uses; a connected account means requests authenticate with
    // the user's Claude subscription (`AnthropicAuth.resolveCredential` falls back to it
    // whenever the saved model's key is empty).
    @ObservedObject private var claudeOAuth = ClaudeOAuthService.shared
    @ObservedObject private var chatgptOAuth = ChatGPTOAuthService.shared

    // Optional service keys
    @State private var elevenLabsKey = ""
    @State private var perplexityKey = ""

    // Permissions state
    @State private var micGranted = false
    @State private var locationGranted = false
    @State private var bluetoothConfigured = false
    @State private var speechGranted = false
    @State private var homeKitGranted = false

    // Reinstall welcome-back (page 1 variant). Captured at view init, so the page does not change
    // shape underneath a user who is reading it.
    @State private var isWelcomeBack = Config.isReinstallLaunch

    // Offline-model offer (Plan DH P2) — the optional download on the keyless path.
    @State private var offlineOffer: OfflineModelOffer.Verdict?
    @State private var isDownloadingOfflineModel = false
    @State private var offlineDownloadError: String?

    // Connect glasses state (page 5)
    @State private var cameraGranted = false
    @State private var metaRegistered = false
    @State private var registrationStatus = ""
    @State private var isRegistering = false

    // Metrics that sit beside type and have to scale with it.
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var iconTile: CGFloat = OGMetrics.iconTile
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var successGlyph: CGFloat = 56

    private let totalPages = 7

    var body: some View {
        ZStack {
            OGTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                // Content — uses conditional views instead of paged TabView
                // so text fields on the API key page respond to taps immediately
                // (paged TabView's swipe gestures steal focus from text fields)
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: providerPage
                    case 2: apiKeyPage
                    case 3: servicesPage
                    case 4: permissionsPage
                    case 5: connectGlassesPage
                    case 6: readyPage
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(pageChange, value: page)
            }
        }
        .onChange(of: page) { _, newPage in focusedPage = newPage }
        .onAppear { refreshOfflineOffer() }
    }

    /// One animation for every page transition — nil under Reduce Motion, which
    /// also stops the page indicator sliding.
    private var pageChange: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    private func go(to next: Int) {
        withAnimation(pageChange) { page = next }
    }

    // MARK: - Header

    /// Page indicator, with Back overlaid on the leading edge so the flow can be
    /// walked in both directions (the page index used to only ever increment).
    private var header: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? accent : Color(.tertiarySystemFill))
                        .frame(width: i == page ? 24 : 8, height: 4)
                        .animation(pageChange, value: page)
                }
            }
            // The dots are decoration: 4pt tall, so as an accessibility element they are a
            // target no finger could find, and VoiceOver would stop on them on the way to the
            // page. Where in the flow the user is now rides on the page title instead — the
            // element focus is moved to on every page change, which is where the question is
            // actually asked. See `pagePosition`.
            .accessibilityHidden(true)

            if page > 0 {
                HStack {
                    Button {
                        go(to: page - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .accessibilitySortPriority(2)
                    Spacer()
                }
                .padding(.leading, 8)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    /// Where in the flow this page sits, spoken as the title's *value* so it is heard on arrival
    /// and re-heard on every page change, without becoming a stop of its own.
    private var pagePosition: String { "Page \(page + 1) of \(totalPages)" }

    /// The title block every page opens with — the VoiceOver landing point.
    private func pageTitle(_ title: String, _ subtitle: String? = nil, page index: Int) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(pagePosition)
                .accessibilityFocused($focusedPage, equals: index)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    // MARK: - Page 1: Welcome

    /// The first page has two shapes. A reinstall gets the welcome-back variant; everyone else
    /// gets the introduction, unchanged.
    @ViewBuilder
    private var welcomePage: some View {
        if isWelcomeBack {
            welcomeBackPage
        } else {
            firstRunWelcomePage
        }
    }

    /// What a delete-and-reinstall lands on.
    ///
    /// The app's own preferences went with the delete and its Keychain did not, and the copy says
    /// exactly that and nothing more — the one thing this page must never imply is that settings
    /// come back, because they don't. Both exits finish onboarding (`completeOnboarding` on the
    /// restore side, the full flow on the other), so the completion flag is written and the
    /// glasses stack is configured whichever the user picks.
    private var welcomeBackPage: some View {
        VStack(spacing: 0) {
            centeredScroll {
                VStack(spacing: 14) {
                    LogoIcon(size: logoSize)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)

                    Text("Welcome back")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(pagePosition)
                        .accessibilityFocused($focusedPage, equals: 0)

                    Text("Your sign-ins and access keys are still on this iPhone.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OGCard {
                    OGRow(
                        "Sign-ins and keys kept",
                        icon: "key.horizontal",
                        subtitle: "Provider keys and connected accounts are stored securely on the device, so they survived the reinstall.",
                        showsChevron: false
                    )
                    OGDivider()
                    OGRow(
                        "Settings start fresh",
                        icon: "slider.horizontal.3",
                        subtitle: "Your preferences — voice, personas, permissions and the rest — were removed with the app and begin at their defaults.",
                        showsChevron: false
                    )
                }
            }

            pageFooter {
                primaryButton("Restore my setup") {
                    completeOnboarding()
                }
                Button("Set up fresh") { go(to: 1) }
                    .buttonStyle(.ogQuiet)
            }
        }
    }

    private var firstRunWelcomePage: some View {
        VStack(spacing: 0) {
            centeredScroll {
                VStack(spacing: 14) {
                    LogoIcon(size: logoSize)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)

                    Text("OpenGlasses")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(pagePosition)
                        .accessibilityFocused($focusedPage, equals: 0)

                    Text("AI assistant for your smart glasses")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // AI transparency disclosure (Apple Generative AI HIG)
                OGCard {
                    OGRow(
                        "Powered by AI",
                        icon: "brain.head.profile",
                        subtitle: "Conversations are processed by the AI provider you choose. Responses are generated by AI and may not always be accurate.",
                        showsChevron: false
                    )
                    OGDivider()
                    OGRow(
                        "Your keys, your data",
                        icon: "lock.shield",
                        subtitle: "Your access key connects directly to your provider. We never see or store your conversations.",
                        showsChevron: false
                    )
                    OGDivider()
                    OGRow(
                        "Microphone access",
                        icon: "mic.badge.xmark",
                        subtitle: "Voice input is processed on-device for wake word detection and sent to your provider for transcription.",
                        showsChevron: false
                    )
                }
            }

            pageFooter {
                primaryButton("Get Started") { go(to: 1) }
                skipButton()
            }
        }
    }

    /// A scroll view whose content sits centred while it fits and scrolls once
    /// it doesn't — which is what keeps the two hero pages composed at default
    /// sizes without truncating them at AX5.
    private func centeredScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let body = VStack(spacing: 26, content: content)
        return GeometryReader { proxy in
            ScrollView {
                body
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    // MARK: - Page 2: Choose Provider

    private var providerPage: some View {
        VStack(spacing: 0) {
            pageTitle("Choose your AI", "Pick a provider. You can add more later in Settings.", page: 1)

            List {
                Section {
                    // The keyless path, first because it is the one that needs nothing.
                    //
                    // Two devices can take it. One has Apple Intelligence and is ready to talk the
                    // moment setup ends. The other doesn't — and used to be shown no keyless
                    // option at all, because the chain's other on-device rung only exists once a
                    // model has been downloaded and nothing here ever offered to download one.
                    // It is offered now, on the devices that can actually run it; a phone below
                    // the bar still sees no dead end here, and the reason is stated on the next
                    // page rather than being left to guess at.
                    if FirstRunDefaults.appleIntelligenceAvailable {
                        providerRow(
                            .appleOnDevice,
                            name: "Start without an API key",
                            model: "Apple Intelligence",
                            detail: "Runs on this iPhone. Add a provider key later in Settings.",
                            icon: "iphone"
                        )
                    } else if offlineModelIsOfferable {
                        providerRow(
                            .local,
                            name: "Start without an API key",
                            model: LLMProvider.local.defaultModel,
                            detail: "Downloads a model to this iPhone. No account, works offline.",
                            icon: "iphone"
                        )
                    }
                    providerRow(
                        .anthropic,
                        name: "Anthropic",
                        model: "Claude",
                        detail: "Best for reasoning and conversation",
                        icon: "brain"
                    )
                    providerRow(
                        .gemini,
                        name: "Google",
                        model: "Gemini",
                        detail: "Free tier available, vision capable",
                        icon: "sparkles"
                    )
                    providerRow(
                        .openai,
                        name: "OpenAI",
                        model: "GPT-4o",
                        detail: "Realtime voice mode available",
                        icon: "waveform"
                    )
                    providerRow(
                        .chatgpt,
                        name: "ChatGPT",
                        model: "Codex",
                        detail: "Use your ChatGPT subscription — no API key",
                        icon: "person.crop.circle.badge.checkmark"
                    )
                    providerRow(
                        .groq,
                        name: "Groq",
                        model: "Llama / Mixtral",
                        detail: "Ultra-fast inference, free tier",
                        icon: "bolt"
                    )
                    providerRow(
                        .qwen,
                        name: "Qwen",
                        model: "Qwen3.5 Plus",
                        detail: "Vision capable, bring your own key",
                        icon: "globe.asia.australia"
                    )
                    providerRow(
                        .zai,
                        name: "Z.ai",
                        model: "GLM-4.5",
                        detail: "Bring your own key",
                        icon: "bolt.circle"
                    )
                }

                // Collapsed section for other providers
                Section {
                    DisclosureGroup {
                        providerRow(
                            .openrouter,
                            name: "OpenRouter",
                            model: "500+ models",
                            detail: "Access many providers through one key",
                            icon: "arrow.triangle.branch"
                        )
                    } label: {
                        Text("More providers")
                            .font(.body)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()

            if selectedProvider != nil {
                pageFooter {
                    primaryButton("Continue") {
                        configureDefaults()
                        go(to: 2)
                    }
                }
            }
        }
    }

    // MARK: - Page 3: Access Key

    private var apiKeyPage: some View {
        let provider = selectedProvider ?? .anthropic
        let needsKey = provider.requiresAPIKey
        let needsAccount = provider == .chatgpt   // no key at all — sign-in is the credential
        let claudeConnected = provider == .anthropic && claudeOAuth.isConnected

        return VStack(spacing: 0) {
            pageTitle(keyPageTitle(provider), keyPageSubtitle(provider), page: 2)

            List {
                if needsKey {
                    // Sign in with Claude — the subscription path; hides the key field once connected.
                    if provider == .anthropic {
                        claudeSignInSection
                    }

                    if !claudeConnected {
                        accessKeySection(provider)
                    }

                    // Model picker (shown after successful validation)
                    if keyValid && !availableModels.isEmpty {
                        modelSection
                    }
                } else if needsAccount {
                    // ChatGPT — account sign-in is the credential; model picker fills from the catalog.
                    chatgptSignInSection

                    if chatgptOAuth.isConnected && !availableModels.isEmpty {
                        modelSection
                    }
                } else {
                    // Subscription and on-device providers — no key needed
                    Section {
                        Label {
                            Text("\(provider.displayName) doesn't require an access key.")
                                .font(.body)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(OGTheme.okLabel)
                        }
                        .frame(minHeight: rowMinHeight)
                    }

                    if provider == .appleOnDevice || provider == .local {
                        offlineModelSection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()
            .onAppear { refreshOfflineOffer() }

            pageFooter {
                if needsAccount {
                    primaryButton("Continue") {
                        saveModel()
                        go(to: 3)
                    }
                    if !chatgptOAuth.isConnected {
                        Button("I'll sign in later") {
                            saveModel()
                            go(to: 3)
                        }
                        .buttonStyle(.ogQuiet)
                    }
                } else if needsKey {
                    if keyValid || claudeConnected {
                        primaryButton("Continue") {
                            saveModel()
                            go(to: 3)
                        }
                    } else {
                        primaryButton(isValidating ? "Validating..." : "Validate Key") {
                            validateKey()
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                    }

                    Button(keyValid ? "Skip model selection" : "I'll add it later") {
                        if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                            saveModel()
                        }
                        go(to: 3)
                    }
                    .buttonStyle(.ogQuiet)
                } else {
                    primaryButton("Continue") {
                        saveModel()
                        go(to: 3)
                    }
                }
            }
        }
    }

    private func keyPageTitle(_ provider: LLMProvider) -> String {
        if provider == .chatgpt { return "Connect ChatGPT" }
        if provider == .local || provider == .appleOnDevice { return "On this iPhone" }
        if provider.requiresAPIKey {
            return provider == .anthropic ? "Connect Claude" : "Add your access key"
        }
        return "You're all set"
    }

    private func keyPageSubtitle(_ provider: LLMProvider) -> String? {
        if provider == .chatgpt {
            return "Sign in with your ChatGPT account — no API key needed"
        }
        if provider == .local || provider == .appleOnDevice {
            return "There's nothing to paste — this one runs on your iPhone."
        }
        guard provider.requiresAPIKey else { return nil }
        return provider == .anthropic
            ? "Sign in with your Claude account, or paste an API key"
            : "Paste your \(provider.displayName) access key below"
    }

    /// The key field, its "get a key" link, and the validation state — a stock
    /// grouped section, so the field behaves like every other field on iOS.
    private func accessKeySection(_ provider: LLMProvider) -> some View {
        Section {
            HStack(spacing: 8) {
                SecretInputField(placeholder: "sk-...", text: $apiKey)
                    .onChange(of: apiKey) { _, _ in
                        validationError = nil
                        keyValid = false
                        availableModels = []
                        selectedModelId = nil
                    }

                if !apiKey.isEmpty {
                    Button {
                        apiKey = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear access key")
                }
            }
            .frame(minHeight: rowMinHeight)

            Button {
                openAPIKeyURL(for: provider)
            } label: {
                Label(apiKeyURLLabel(for: provider), systemImage: "arrow.up.right.square")
                    .font(.subheadline)
                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                    .frame(minHeight: rowMinHeight)
            }
        } header: {
            Text("Access Key")
        } footer: {
            keyValidationFooter
        }
    }

    @ViewBuilder
    private var keyValidationFooter: some View {
        if let error = validationError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(OGTheme.errorLabel)
        } else if keyValid {
            Label(
                availableModels.isEmpty
                    ? "Key valid"
                    : "Key valid — \(availableModels.count) models available",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(OGTheme.okLabel)
        }
    }

    /// The model list a validated credential unlocks — a native grouped
    /// selection list, the same shape the Settings model editor offers.
    private var modelSection: some View {
        Section {
            ForEach(availableModels) { model in
                Button {
                    selectedModelId = model.id
                } label: {
                    HStack(spacing: OGMetrics.rowSpacing) {
                        Text(model.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        OGSelectionCheck(selectedModelId == model.id)
                    }
                    .frame(minHeight: rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.name)
                .accessibilityAddTraits(
                    selectedModelId == model.id ? [.isButton, .isSelected] : .isButton
                )
            }
        } header: {
            Text("Select Model")
        }
    }

    // MARK: - Account sign-in sections (shared OnboardingAccountSignInSection, BW P4)

    private var claudeSignInSection: some View {
        OnboardingAccountSignInSection(
            service: claudeOAuth,
            signInLabel: "Sign in with Claude",
            caption: "Use your Claude subscription — no API key required.",
            connectedCaption: "Requests use your Claude subscription — no API key needed.",
            pasteInstructions: "Sign in in the browser, copy the code from the callback page, then paste it here.",
            onConnected: { validateViaClaudeAccount() },
            onSignedOut: {
                keyValid = false
                availableModels = []
                selectedModelId = nil
            }
        )
    }

    private var chatgptSignInSection: some View {
        OnboardingAccountSignInSection(
            service: chatgptOAuth,
            signInLabel: "Sign in with ChatGPT",
            // The distinction that confused a real device session: signing in covers *typed and
            // spoken conversation* on your plan. Live voice mode is a different OpenAI product
            // that only accepts a platform API key — no sign-in of any kind reaches it — so the
            // caption says which one this is and where the other comes from.
            caption: "Use your ChatGPT plan for conversation — no API key required. Live voice mode is separate: it needs an OpenAI API key, added as its own model.",
            connectedCaption: "Conversation uses your ChatGPT plan. Live voice mode still needs an OpenAI API key, added as its own model in Settings.",
            pasteInstructions: "Sign in in the browser. When it ends on a localhost page that can't connect, copy the full URL from the address bar and paste it here.",
            onConnected: { markChatGPTConnected() },
            onSignedOut: {
                keyValid = false
                availableModels = []
                selectedModelId = nil
            }
        )
    }

    // MARK: - Offline model offer (Plan DH P2)

    /// Whether the keyless card is worth showing on a device without Apple Intelligence: only
    /// where a model could actually be downloaded, or already has been.
    private var offlineModelIsOfferable: Bool {
        guard let offlineOffer else { return false }
        switch offlineOffer {
        case .offer, .alreadyDownloaded: return true
        case .notEnoughStorage, .deviceTooSmall: return false
        }
    }

    /// The optional download that turns the keyless path into a fully-offline one.
    ///
    /// Every branch says something true about *this* device: the size before anything starts, the
    /// reason when the device is under the bar, the storage shortfall when there is no room, and —
    /// while a download runs — that leaving the flow doesn't cancel it. The download itself goes
    /// through the same service call the local-model screen uses, so there is one download path in
    /// the app, with one cancel, one resume, and one progress reading.
    @ViewBuilder
    private var offlineModelSection: some View {
        if let verdict = offlineOffer {
            Section {
                offlineModelRows(verdict)

                if let offlineDownloadError {
                    OGStatusLabel(offlineDownloadError, kind: .error,
                                  systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("Offline Model")
            } footer: {
                offlineModelFooter(verdict)
            }
        }
    }

    @ViewBuilder
    private func offlineModelRows(_ verdict: OfflineModelOffer.Verdict) -> some View {
        switch verdict {
        case .deviceTooSmall(let requiredRAMGB):
            Label {
                Text(OfflineModelOffer.deviceTooSmallDetail(requiredRAMGB: requiredRAMGB))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "memorychip")
                    .foregroundStyle(OGTheme.warnLabel)
            }
            .frame(minHeight: rowMinHeight)

        case .notEnoughStorage(let needed, let free):
            Label {
                Text(OfflineModelOffer.notEnoughStorageDetail(neededBytes: needed, freeBytes: free))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "internaldrive")
                    .foregroundStyle(OGTheme.warnLabel)
            }
            .frame(minHeight: rowMinHeight)

        case .alreadyDownloaded:
            Label {
                Text(OfflineModelOffer.alreadyDownloadedDetail)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OGTheme.okLabel)
            }
            .frame(minHeight: rowMinHeight)

        case .offer(let modelId, let sizeBytes):
            offlineDownloadRow(modelId: modelId, sizeBytes: sizeBytes)
        }
    }

    @ViewBuilder
    private func offlineDownloadRow(modelId: String, sizeBytes: Int64) -> some View {
        HStack(spacing: OGMetrics.rowSpacing) {
            OGIconTile(systemName: "arrow.down.circle")

            VStack(alignment: .leading, spacing: 2) {
                Text(OfflineModelOffer.title(
                    appleIntelligenceAvailable: FirstRunDefaults.appleIntelligenceAvailable))
                    .font(.body)
                // The size is stated here, beside the button, before anything is downloaded —
                // not discovered halfway through a multi-gigabyte pull on cellular.
                Text(OfflineModelOffer.formattedSize(sizeBytes))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if isDownloadingOfflineModel, let service = appState.llmService.localLLMService {
                DownloadProgressRow(service: service) {
                    service.cancelDownload()
                    isDownloadingOfflineModel = false
                    SessionAnnouncer.say("Offline model download cancelled")
                }
            } else {
                Button("Download") { downloadOfflineModel(modelId) }
                    .buttonStyle(.ogProminentCompact)
                    .accessibilityLabel("Download the offline model, \(OfflineModelOffer.formattedSize(sizeBytes))")
            }
        }
        .frame(minHeight: rowMinHeight)
    }

    @ViewBuilder
    private func offlineModelFooter(_ verdict: OfflineModelOffer.Verdict) -> some View {
        switch verdict {
        case .offer(_, let sizeBytes):
            // While it runs, the footer stops describing the offer and starts describing the
            // download — because "can I leave this screen?" is the only question a user has once
            // a multi-gigabyte transfer has started.
            Text(isDownloadingOfflineModel
                 ? OfflineModelOffer.inProgressDetail
                 : OfflineModelOffer.detail(
                    appleIntelligenceAvailable: FirstRunDefaults.appleIntelligenceAvailable,
                    sizeBytes: sizeBytes))
        case .alreadyDownloaded, .notEnoughStorage, .deviceTooSmall:
            EmptyView()
        }
    }

    private func refreshOfflineOffer() {
        let verdict = OfflineModelOffer.verdict(OfflineModelOffer.currentInputs(),
                                                modelId: OfflineModelOffer.modelId)
        offlineOffer = verdict
        // A model already on disk is the one this path should configure, so the id is settled
        // before the user ever reaches Continue.
        if case .alreadyDownloaded(let modelId) = verdict, selectedProvider == .local {
            selectedModelId = modelId
        }
    }

    private func downloadOfflineModel(_ modelId: String) {
        guard let service = appState.llmService.localLLMService else {
            offlineDownloadError = "On-device models aren't available on this build."
            SessionAnnouncer.say(offlineDownloadError ?? "", interrupts: true)
            return
        }
        isDownloadingOfflineModel = true
        offlineDownloadError = nil
        // The keyless local path should end up pointing at what is being fetched, whether or not
        // the user waits here for it to land.
        if selectedProvider == .local { selectedModelId = modelId }
        // Both ends of a long wait are spoken. A progress spinner that replaces a button says
        // nothing to a user who isn't looking at it, and this is the longest wait in the flow.
        SessionAnnouncer.say("Downloading the offline model. You can carry on setting up.")
        Task {
            do {
                try await service.downloadModel(modelId)
                isDownloadingOfflineModel = false
                ensureLocalModelIsSelectable(modelId)
                refreshOfflineOffer()
                SessionAnnouncer.say("Offline model ready")
            } catch is CancellationError {
                isDownloadingOfflineModel = false   // the user cancelled; not an error to report
            } catch {
                isDownloadingOfflineModel = false
                offlineDownloadError = error.localizedDescription
                SessionAnnouncer.say("Offline model download failed. \(error.localizedDescription)",
                                     interrupts: true)
            }
        }
    }

    /// Make a downloaded model reachable from the model list.
    ///
    /// `FirstRunDefaults` decides what is *active*: on a device with Apple Intelligence that stays
    /// Apple Intelligence, which is exactly what the offer promised there — an upgrade, not a
    /// replacement. But "it appears alongside your other models" is only true if a saved
    /// configuration exists for it, so this adds or retargets the local entry and leaves the
    /// active model alone. On the keyless local path `saveModel` then makes it active on Continue,
    /// which is the promise made on *that* device.
    private func ensureLocalModelIsSelectable(_ modelId: String) {
        var models = Config.savedModels
        if let idx = models.firstIndex(where: { $0.llmProvider == .local }) {
            guard models[idx].model != modelId else { return }
            models[idx].model = modelId
        } else {
            var config = ModelConfig.defaultConfig(for: .local)
            config.model = modelId
            models.append(config)
        }
        Config.setSavedModels(models)
        appState.llmService.refreshActiveModel()
    }

    // MARK: - Page 4: Services (Optional)

    private var servicesPage: some View {
        VStack(spacing: 0) {
            pageTitle(
                "Enhance your experience",
                "Optional — add these later in Settings if you prefer.",
                page: 3
            )

            List {
                Section {
                    SecretInputField(placeholder: "ElevenLabs API Key", text: $elevenLabsKey)
                        .frame(minHeight: rowMinHeight)

                    if elevenLabsKey.isEmpty {
                        Link(destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!) {
                            Label("Get key from elevenlabs.io", systemImage: "arrow.up.right.square")
                                .font(.subheadline)
                                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                                .frame(minHeight: rowMinHeight)
                        }
                    }
                } header: {
                    Label("ElevenLabs Voice", systemImage: "waveform")
                } footer: {
                    Text("Natural-sounding voice. Without this, the built-in iOS voice is used.")
                }

                Section {
                    SecretInputField(placeholder: "Perplexity API Key", text: $perplexityKey)
                        .frame(minHeight: rowMinHeight)

                    if perplexityKey.isEmpty {
                        Link(destination: URL(string: "https://www.perplexity.ai/settings/api")!) {
                            Label("Get key from perplexity.ai", systemImage: "arrow.up.right.square")
                                .font(.subheadline)
                                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                                .frame(minHeight: rowMinHeight)
                        }
                    }
                } header: {
                    Label("Perplexity Search", systemImage: "magnifyingglass")
                } footer: {
                    Text("AI-powered web search with cited sources. Without this, DuckDuckGo is used.")
                }

                Section {
                    if hasPremiumVoiceInstalled {
                        Label("Premium voice detected", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(OGTheme.okLabel)
                            .frame(minHeight: rowMinHeight)
                    } else {
                        Text("Go to Settings → Accessibility → Spoken Content → Voices to download a premium voice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: rowMinHeight)
                    }
                } header: {
                    Label("iOS Fallback Voice", systemImage: "speaker.wave.2")
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()

            pageFooter {
                primaryButton("Continue") {
                    // Save any keys the user entered
                    if !elevenLabsKey.isEmpty {
                        Config.setElevenLabsAPIKey(elevenLabsKey)
                    }
                    if !perplexityKey.isEmpty {
                        Config.setPerplexityAPIKey(perplexityKey)
                    }
                    go(to: 4)
                }
                skipButton()
            }
        }
    }

    /// Check if any enhanced/premium quality voice is installed.
    private var hasPremiumVoiceInstalled: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { voice in
            voice.quality == .enhanced || voice.quality == .premium
        }
    }

    // MARK: - Page 5: Permissions

    private var permissionsPage: some View {
        VStack(spacing: 0) {
            pageTitle("Permissions", "OpenGlasses needs a few permissions to work.", page: 4)

            List {
                Section {
                    permissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        detail: "For wake word detection and voice commands",
                        granted: micGranted
                    ) {
                        await requestMicPermission()
                    }

                    permissionRow(
                        icon: "waveform",
                        title: "Speech Recognition",
                        detail: "To understand what you say",
                        granted: speechGranted
                    ) {
                        await requestSpeechPermission()
                    }

                    permissionRow(
                        icon: "location.fill",
                        title: "Location",
                        detail: "For weather, nearby places, and context",
                        granted: locationGranted
                    ) {
                        requestLocationPermission()
                    }

                    permissionRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Bluetooth",
                        detail: "To connect to your Ray-Ban Meta glasses",
                        granted: bluetoothConfigured
                    ) {
                        configureWearablesSDK()
                    }

                    permissionRow(
                        icon: "house.fill",
                        title: "Home Data",
                        detail: "To control lights, locks, and smart home devices",
                        granted: homeKitGranted
                    ) {
                        await requestHomeKitPermission()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()

            pageFooter {
                primaryButton("Continue") { go(to: 5) }
                    .disabled(!micGranted)

                if micGranted {
                    skipButton()
                } else {
                    Text("Microphone permission is required")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
        .onAppear { checkExistingPermissions() }
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: OGMetrics.rowSpacing) {
            permissionIcon(icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Title and detail are one thought, not two stops.
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if granted {
                // Said in words, not just carried by the green — the state has
                // to survive a screen reader and a colour-blind reader alike.
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OGTheme.okLabel)
            } else {
                Button("Grant") {
                    Task { await action() }
                }
                .buttonStyle(.ogProminentCompact)
                .accessibilityLabel("Grant \(title) access")
            }
        }
        .frame(minHeight: rowMinHeight)
    }

    @ViewBuilder
    private func permissionIcon(_ icon: String) -> some View {
        if icon == "OpenGlassesLogo" {
            RoundedRectangle(cornerRadius: iconTile * 0.28, style: .continuous)
                .fill(accent.opacity(OGTheme.Opacity.accentFill))
                .frame(width: iconTile, height: iconTile)
                .overlay {
                    LogoIcon(size: iconTile * 0.6)
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                }
                .accessibilityHidden(true)
        } else {
            OGIconTile(systemName: icon)
        }
    }

    private func checkExistingPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        let locStatus = CLLocationManager().authorizationStatus
        locationGranted = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways
        bluetoothConfigured = Config.hasCompletedOnboarding
        homeKitGranted = false
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Say how a permission request came out.
    ///
    /// The system alert is accessible on its own, but its *dismissal* is where onboarding goes
    /// quiet: a grant swaps a button for a checkmark somewhere down the list, and a refusal
    /// changes nothing at all — so from behind VoiceOver, "no" and "the tap didn't register"
    /// are the same experience. Refusal is stated, because it is the answer that stalls the
    /// flow, and a stalled flow the user cannot see is where onboarding is abandoned.
    private func announcePermission(_ name: String, granted: Bool) {
        SessionAnnouncer.say(granted ? "\(name) access granted"
                                     : "\(name) access not granted")
    }

    private func requestMicPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micGranted = granted
        announcePermission("Microphone", granted: granted)
    }

    private func requestSpeechPermission() async {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        speechGranted = status == .authorized
        announcePermission("Speech recognition", granted: speechGranted)
    }

    private func requestLocationPermission() {
        appState.locationService.startTracking()
        // Give time for the dialog to show and user to respond
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let status = CLLocationManager().authorizationStatus
            locationGranted = status == .authorizedWhenInUse || status == .authorizedAlways
            announcePermission("Location", granted: locationGranted)
        }
    }

    private func configureWearablesSDK() {
        guard !bluetoothConfigured else { return }
        // Funnels through the single owner of configure() so this and the launch path cannot
        // configure twice. Marked done either way: a failure here must not become a retry loop,
        // and the user can still reconnect from Settings.
        _ = WearablesBootstrap.ensureConfigured()
        bluetoothConfigured = true
        NSLog("[Onboarding] Wearables SDK %@", WearablesBootstrap.statusDescription)
        announcePermission("Bluetooth", granted: true)
    }

    private func requestHomeKitPermission() async {
        // HMHomeManager triggers the permission dialog on init.
        // HomeKitTool.prepareShared() creates the singleton manager.
        HomeKitTool.prepareShared()
        // Give time for the permission dialog
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        homeKitGranted = true
        announcePermission("Home data", granted: true)
    }

    // MARK: - Page 6: Connect Glasses

    private var connectGlassesPage: some View {
        VStack(spacing: 0) {
            pageTitle(
                "Connect Your Glasses",
                "Authorize camera access and link OpenGlasses to the Meta AI app.",
                page: 5
            )

            List {
                Section {
                    // iOS Camera permission
                    permissionRow(
                        icon: "camera.fill",
                        title: "Camera",
                        detail: "Required to stream video from your Ray-Ban Meta glasses",
                        granted: cameraGranted
                    ) {
                        await requestCameraPermission()
                    }

                    // Meta AI integration
                    permissionRow(
                        icon: "OpenGlassesLogo",
                        title: "Meta AI Integration",
                        detail: "Links OpenGlasses to your glasses via the Meta AI app",
                        granted: metaRegistered
                    ) {
                        await connectToMetaAI()
                    }
                } footer: {
                    registrationFooter
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()

            pageFooter {
                primaryButton("Continue") { go(to: 6) }
                Button("Skip — no glasses yet") { go(to: 6) }
                    .buttonStyle(.ogQuiet)
            }
        }
        .onAppear {
            cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            metaRegistered = bluetoothConfigured && Wearables.shared.registrationState.rawValue >= 3
        }
    }

    @ViewBuilder
    private var registrationFooter: some View {
        if isRegistering {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(registrationStatus.isEmpty ? "Connecting…" : registrationStatus)
            }
        } else if !registrationStatus.isEmpty && !metaRegistered {
            Text(registrationStatus)
                .foregroundStyle(OGTheme.warnLabel)
        }
    }

    private func requestCameraPermission() async {
        cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        announcePermission("Camera", granted: cameraGranted)
    }

    private func connectToMetaAI() async {
        guard bluetoothConfigured else {
            registrationStatus = "Grant Bluetooth permission first (previous page)"
            SessionAnnouncer.say(registrationStatus, interrupts: true)
            return
        }
        isRegistering = true
        registrationStatus = "Registering with Meta AI…"
        // This step leaves the app entirely — the user approves in another app and comes back —
        // so the one thing that must not happen is returning to a screen that says nothing about
        // whether it worked. Both ends of the wait are spoken: it started, and how it finished.
        SessionAnnouncer.say("Registering with Meta AI")
        await appState.glassesService.connect()
        let state = Wearables.shared.registrationState
        metaRegistered = state.rawValue >= 3
        registrationStatus = metaRegistered
            ? ""
            : "Open the Meta AI app to approve, then tap Connect again"
        isRegistering = false
        SessionAnnouncer.say(metaRegistered ? "Meta AI connected" : registrationStatus,
                             interrupts: !metaRegistered)

        // Start observing devices now that registration is in progress
        appState.glassesService.startObserving()
    }

    // MARK: - Page 7: Ready

    private var readyPage: some View {
        VStack(spacing: 0) {
            centeredScroll {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: successGlyph, weight: .regular))
                        .foregroundStyle(OGTheme.okLabel)
                        .accessibilityHidden(true)

                    Text("You're ready")
                        .font(.title.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(pagePosition)
                        .accessibilityFocused($focusedPage, equals: 6)

                    Text("Say \"OpenGlasses\" or tap the mic to start a conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                // What you can do
                OGCard {
                    OGRow("Voice-first — talk naturally, get spoken answers",
                          icon: "mic.fill", showsChevron: false)
                    OGDivider()
                    OGRow("Show things to the camera for visual AI",
                          icon: "camera.fill", showsChevron: false)
                    OGDivider()
                    OGRow("Switch personas for different AI personalities",
                          icon: "person.2.fill", showsChevron: false)
                    OGDivider()
                    OGRow("Add more models or tweak settings anytime",
                          icon: "gearshape", showsChevron: false)
                }

                // AI disclosure reminder
                Text("AI responses may contain errors. Verify important information independently.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            pageFooter {
                primaryButton("Start Using OpenGlasses") {
                    completeOnboarding()
                }
            }
        }
    }

    // MARK: - Components

    /// The action block every page ends with: one filled accent button, and at
    /// most one quiet escape hatch under it.
    private func pageFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 2) {
            content()
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.ogProminent)
            .frame(maxWidth: 340)
    }

    private func skipButton() -> some View {
        Button("Skip setup") {
            completeOnboarding()
        }
        .buttonStyle(.ogQuiet)
    }

    private func providerRow(
        _ provider: LLMProvider,
        name: String,
        model: String,
        detail: String,
        icon: String
    ) -> some View {
        let selected = selectedProvider == provider

        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedProvider = provider
                modelName = model
            }
        } label: {
            HStack(spacing: OGMetrics.rowSpacing) {
                OGIconTile(systemName: icon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                OGSelectionCheck(selected)
            }
            .frame(minHeight: rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) — \(detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Logic

    private func configureDefaults() {
        guard let provider = selectedProvider else { return }
        modelName = provider.defaultModel
    }

    private func validateKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let provider = selectedProvider else { return }

        // Basic format validation
        if provider == .anthropic && !trimmed.hasPrefix("sk-ant-") {
            validationError = "Anthropic keys start with sk-ant-"
            SessionAnnouncer.say(validationError ?? "", interrupts: true)
            return
        }
        if provider == .openai && !trimmed.hasPrefix("sk-") {
            validationError = "OpenAI keys start with sk-"
            SessionAnnouncer.say(validationError ?? "", interrupts: true)
            return
        }

        isValidating = true
        validationError = nil

        Task {
            let models = await ModelFetcher.fetchModels(
                provider: provider,
                apiKey: trimmed,
                baseURL: provider.defaultBaseURL
            )

            await MainActor.run {
                isValidating = false
                if models.isEmpty {
                    // Key may still be valid even if model listing fails — accept it
                    keyValid = true
                    availableModels = []
                    selectedModelId = provider.defaultModel
                } else {
                    keyValid = true
                    availableModels = models
                    // Pre-select the provider's default model if it's in the list
                    if models.contains(where: { $0.id == provider.defaultModel }) {
                        selectedModelId = provider.defaultModel
                    } else {
                        selectedModelId = models.first?.id
                    }
                }
                // The button goes back from "Validating…" to "Continue" and a model list appears
                // further down the page — neither of which reaches a user whose focus is still on
                // the key field, which is exactly where it is after typing one.
                SessionAnnouncer.say(availableModels.isEmpty
                                     ? "Key accepted"
                                     : "Key accepted. \(availableModels.count) models available.")
            }
        }
    }

    /// After a successful Claude sign-in: fetch the model list with the OAuth credential (an
    /// empty key resolves to the connected account) and mark the provider ready to continue.
    /// A failed listing still counts as valid — the account is connected; the default model works.
    /// After a successful ChatGPT sign-in: the codex catalog is static, so no network fetch —
    /// mark the provider ready and pre-select the default model.
    private func markChatGPTConnected() {
        keyValid = true
        availableModels = ChatGPTOAuth.modelCatalog.map { ModelFetcher.RemoteModel(id: $0, name: $0) }
        selectedModelId = ChatGPTOAuth.defaultModel
    }

    private func validateViaClaudeAccount() {
        isValidating = true
        validationError = nil
        Task {
            let models = await ModelFetcher.fetchModels(
                provider: .anthropic,
                apiKey: "",
                baseURL: LLMProvider.anthropic.defaultBaseURL
            )
            await MainActor.run {
                isValidating = false
                keyValid = true
                availableModels = models
                if models.contains(where: { $0.id == LLMProvider.anthropic.defaultModel }) {
                    selectedModelId = LLMProvider.anthropic.defaultModel
                } else {
                    selectedModelId = models.first?.id ?? LLMProvider.anthropic.defaultModel
                }
            }
        }
    }

    private func saveModel() {
        guard let provider = selectedProvider else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let chosenModel = selectedModelId ?? provider.defaultModel

        let model = ModelConfig(
            id: UUID().uuidString,
            name: provider.displayName,
            provider: provider.rawValue,
            apiKey: trimmedKey,
            model: chosenModel,
            baseURL: provider.defaultBaseURL
        )

        var models = Config.savedModels
        // Replace existing model for same provider, or append
        if let idx = models.firstIndex(where: { $0.provider == provider.rawValue }) {
            models[idx] = model
        } else {
            models.append(model)
        }
        Config.setSavedModels(models)
        Config.setActiveModelId(model.id)

        // Update the LLM service so the UI reflects the chosen model immediately
        appState.llmService.refreshActiveModel()

        // Ensure the default persona uses this model (so wake-word doesn't revert to a stale model)
        let personas = Config.savedPersonas
        if personas.count <= 1, let only = personas.first {
            Config.updatePersonaModelId(only.id, modelId: model.id)
        }
    }

    private func completeOnboarding() {
        Config.setHasCompletedOnboarding(true)

        // Ensure Wearables SDK is configured (may already be done from permissions page)
        if !bluetoothConfigured {
            configureWearablesSDK()
        }

        // Start all services that depend on Wearables.shared + permissions
        appState.startPermissionRequiringServices()

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            isVisible = false
        }
    }

    private func openAPIKeyURL(for provider: LLMProvider) {
        let urlString: String
        switch provider {
        case .anthropic: urlString = "https://console.anthropic.com/settings/keys"
        case .openai: urlString = "https://platform.openai.com/api-keys"
        case .gemini: urlString = "https://aistudio.google.com/apikey"
        case .groq: urlString = "https://console.groq.com/keys"
        case .openrouter: urlString = "https://openrouter.ai/keys"
        case .qwen: urlString = "https://dashscope.console.aliyun.com/apiKey"
        case .zai: urlString = "https://open.bigmodel.cn/usercenter/apikeys"
        case .xai: urlString = "https://console.x.ai"
        default: urlString = ""
        }
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    private func apiKeyURLLabel(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return "Get a key at console.anthropic.com"
        case .openai: return "Get a key at platform.openai.com"
        case .gemini: return "Get a key at aistudio.google.com"
        case .groq: return "Get a key at console.groq.com"
        case .openrouter: return "Get a key at openrouter.ai"
        case .qwen: return "Get a key at dashscope.console.aliyun.com"
        case .zai: return "Get a key at open.bigmodel.cn"
        case .xai: return "Get a key at console.x.ai"
        default: return "Get an access key"
        }
    }
}
