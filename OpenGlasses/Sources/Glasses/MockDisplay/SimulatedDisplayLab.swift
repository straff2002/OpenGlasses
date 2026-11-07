#if DAT_MOCK_DISPLAY
import Foundation
import MWDATCore
import MWDATMockDevice
import UIKit
import WebKit

/// The simulated Ray-Ban Display (Plan KV P4), development only, on the iOS Simulator.
///
/// Compiled only into a project generated with `AVENKIN_DAT_MOCK_DISPLAY=1`
/// (`project.mock-display.yml`), whose build phase refuses anything but a Debug build for the
/// Simulator. Every use of DAT's Mock Device Kit lives in this folder, inside `#if DAT_MOCK_DISPLAY`
/// (`MockDisplayLaneGuardTests`).
///
/// **Order.** The app configures the SDK as it always does (`WearablesBootstrap.ensureConfigured()`:
/// the telemetry block, then `Wearables.configure()`); the kit is enabled after that, registered and
/// with the camera permission granted, and the simulated glasses are paired, powered on and put on.
/// From there nothing is simulated in the app: `GlassesConnectionService` reads the mock's link as
/// it reads a real one, and the HUD sends through the real `MetaDisplayBackend`, so the preview
/// draws the frames a Display would get.
@MainActor
final class SimulatedDisplayLab: ObservableObject {
    static let shared = SimulatedDisplayLab()

    /// The test server's port, which Meta's Chrome extension reads (`http://127.0.0.1:9000/`).
    static let testServerPort: UInt16 = 9000
    /// Launch argument: switch the simulated Display on at launch and run the page walkthrough.
    static let walkthroughLaunchArgument = "-AvenkinSimulatedDisplayWalkthrough"
    /// Launch argument: switch the simulated Display on at launch.
    static let switchOnLaunchArgument = "-AvenkinSimulatedDisplay"

    @Published private(set) var isOn = false
    @Published private(set) var status = ""
    @Published private(set) var serverAddress: String?
    @Published var previewVisible = true {
        didSet { previewPanel.setVisible(previewVisible && isOn) }
    }

    private(set) var glasses: (any MockGlasses)?
    let previewPanel = SimulatedDisplayPreviewPanel()
    private var originalSourceURL: ((FieldSessionService.StagedFigure) -> URL?)?

    /// The mock's display kit, once the glasses are paired.
    var displayKit: (any MockDisplayKit)? { glasses?.services.display }

    // MARK: - Launch

    /// Called once at launch: switches on (and runs the walkthrough) when asked by argument.
    func launchHook(appState: AppState) {
        let arguments = ProcessInfo.processInfo.arguments
        let walkthrough = arguments.contains(Self.walkthroughLaunchArgument)
        guard walkthrough || arguments.contains(Self.switchOnLaunchArgument) else { return }
        Task { @MainActor in
            // Let the scene come up first: the preview panel needs a window scene.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.switchOn(appState: appState)
            if walkthrough, self.isOn {
                await SimulatedDisplayWalkthrough(appState: appState, lab: self).run()
            }
        }
    }

    // MARK: - Switch

    func switchOn(appState: AppState) async {
        guard !isOn else { return }
        // The SDK first, the app's own way: the telemetry block, then `Wearables.configure()`.
        guard WearablesBootstrap.ensureConfigured() else {
            status = "The glasses SDK isn't configured: \(WearablesBootstrap.statusDescription)"
            return
        }
        let kit = MockDeviceKit.shared
        if !kit.isEnabled {
            kit.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
        }
        let paired: any MockGlasses
        do {
            paired = try kit.pairGlasses(model: .metaRayBanDisplay)
        } catch {
            status = "The simulated glasses didn't pair: \(error.description)"
            return
        }
        paired.powerOn()
        paired.don()
        glasses = paired
        note(appState, "kit enabled, Display glasses paired, powered on and worn")

        do {
            let port = try await kit.startTestServer(port: Self.testServerPort)
            serverAddress = "http://127.0.0.1:\(port)/"
            note(appState, "test server on port \(port)")
        } catch {
            serverAddress = nil
            note(appState, "test server not started")
        }

        // The HUD on, the Meta backend, and the invented manual behind the page view.
        Config.setGlassesDisplayEnabled(true)
        installTestManual(appState: appState)
        // Idempotent; the app normally started it at launch already.
        appState.glassesService.startObserving()

        isOn = true
        status = "On"
        previewPanel.attach(paired.services.display.createPreviewView())
        previewPanel.setVisible(previewVisible)
    }

    func switchOff(appState: AppState) async {
        guard isOn else { return }
        previewPanel.setVisible(false)
        previewPanel.detach()
        let kit = MockDeviceKit.shared
        await kit.stopTestServer()
        if let glasses { await kit.unpairDevice(glasses) }
        glasses = nil
        await kit.disable()
        if let originalSourceURL { appState.lensPage.sourceURL = originalSourceURL }
        originalSourceURL = nil
        serverAddress = nil
        isOn = false
        status = "Off"
        note(appState, "switched off")
    }

    // MARK: - The invented manual

    /// Writes the invented manual and makes it the PDF behind its pages on the lens. Only pages of
    /// that manual resolve through here; every other page resolves the way it always does.
    private func installTestManual(appState: AppState) {
        guard let url = try? SimulatedDisplayTestManual.write() else {
            note(appState, "test manual not written")
            return
        }
        let original = originalSourceURL ?? appState.lensPage.sourceURL
        originalSourceURL = original
        appState.lensPage.sourceURL = { staged in
            staged.documentId == SimulatedDisplayTestManual.documentId ? url : original(staged)
        }
        note(appState, "test manual installed (\(SimulatedDisplayTestManual.pageCount) pages)")
    }

    // MARK: - Presses through the mock

    /// One button as the simulated lens last drew it.
    struct LensButton: Equatable {
        let title: String
        let identifier: String
    }

    /// The buttons of the frame the simulated lens holds now, in order, with the identifiers the
    /// SDK gave them.
    ///
    /// DAT's `Button` takes no identifier: the SDK names each button when the frame is sent
    /// (`c<position>_<nonce>`, new on every send), and `MockDisplayKit.sendClick(identifier:)` takes
    /// that name — a button's label is accepted by `sendClick` but presses nothing. The only place
    /// the names are readable is the frame the mock serves its preview from, the test server's
    /// `POST /display/content`, so that is where they are read. Nil without the test server.
    func lensButtons() async -> [LensButton]? {
        guard let serverAddress, let url = URL(string: serverAddress + "display/content") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"afterRevision":null}"#.utf8)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let content = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = content["payload"] as? String,
              let decoded = Data(base64Encoded: payload),
              let frame = try? JSONSerialization.jsonObject(with: decoded) else { return nil }
        var buttons: [LensButton] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if object["type"] as? String == "button", let title = object["title"] as? String,
                   let identifier = object["identifier"] as? String {
                    buttons.append(LensButton(title: title, identifier: identifier))
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(frame)
        return buttons
    }

    /// Presses the button the lens shows with `identifier`, as the band would.
    @discardableResult
    func sendClick(identifier: String) -> Bool {
        displayKit?.sendClick(identifier: identifier) ?? false
    }

    // MARK: - Snapshot

    /// The preview's current render, drawn as it is on screen.
    func snapshot() -> UIImage? { previewPanel.snapshot() }

    func note(_ appState: AppState, _ line: String) {
        appState.addDebugEvent("Simulated Display: \(line)")
    }
}

/// The square floating panel that holds the mock's preview: a small window of its own above the
/// app, so it floats over any screen and touches outside it reach the app. It can be hidden.
@MainActor
final class SimulatedDisplayPreviewPanel {
    static let side: CGFloat = 300

    private var window: UIWindow?
    private var previewView: UIView?
    private let container = UIView()

    func attach(_ preview: UIView) {
        detach()
        previewView = preview
        container.backgroundColor = .black
        container.layer.borderColor = UIColor.systemOrange.cgColor
        container.layer.borderWidth = 1
        preview.frame = container.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(preview)
        // The preview is a web view: in a small window its scroll view would take the status bar's
        // safe-area inset…
        if let scroll = (webView as? WKWebView)?.scrollView {
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.isScrollEnabled = false
            // …and draw its top edge effect over the lens's first lines.
            scroll.topEdgeEffect.isHidden = true
            scroll.bottomEdgeEffect.isHidden = true
        }
    }

    func detach() {
        previewView?.removeFromSuperview()
        previewView = nil
        window?.isHidden = true
        window = nil
    }

    func setVisible(_ visible: Bool) {
        guard visible else { window?.isHidden = true; return }
        guard previewView != nil else { return }
        if window == nil { makeWindow() }
        window?.isHidden = false
    }

    private func makeWindow() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let bounds = scene.screen.bounds
        let frame = CGRect(x: bounds.width - Self.side - 12, y: bounds.height - Self.side - 120,
                           width: Self.side, height: Self.side)
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        window.windowLevel = .alert + 1
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        container.frame = controller.view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(container)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumNumberOfTouches = 2
        controller.view.addGestureRecognizer(drag)
        window.rootViewController = controller
        self.window = window
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let window else { return }
        let moved = gesture.translation(in: nil)
        window.frame = window.frame.offsetBy(dx: moved.x, dy: moved.y)
        gesture.setTranslation(.zero, in: nil)
    }

    /// The preview as drawn now.
    func snapshot() -> UIImage? {
        // The container, so the lens's black is in the picture (the preview itself is transparent).
        let view = container
        guard previewView != nil, view.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    /// The preview's view tree, one line per view: what the mock draws with, for the walkthrough log.
    func describeTree() -> [String] {
        guard let previewView else { return [] }
        var lines: [String] = []
        func walk(_ view: UIView, depth: Int) {
            var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
            if let id = view.accessibilityIdentifier, !id.isEmpty { line += " id=\(id)" }
            if let label = view.accessibilityLabel, !label.isEmpty { line += " label=\(label)" }
            lines.append(line)
            for child in view.subviews where depth < 12 { walk(child, depth: depth + 1) }
        }
        walk(previewView, depth: 0)
        return lines
    }

    var webView: UIView? {
        func find(_ view: UIView) -> UIView? {
            if String(describing: type(of: view)).contains("WKWebView") { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return previewView.flatMap(find)
    }
}
#endif
