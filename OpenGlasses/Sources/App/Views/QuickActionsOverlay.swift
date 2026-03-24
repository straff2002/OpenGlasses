import SwiftUI
import UIKit

/// Rolex-style rotatable speed dial for quick actions.
/// Spin vertically with your thumb (3 o'clock position), tap the magnified icon to invoke.
struct QuickActionsOverlay: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedIndex: Int = 0
    @State private var isExecuting = false

    private var actions: [QuickAction] { Config.quickActions }

    private var isIdle: Bool {
        !appState.isProcessing
        && !appState.isListening
        && !appState.speechService.isSpeaking
        && !appState.cameraService.isCaptureInProgress
        && !isExecuting
    }

    private let dialRadius: CGFloat = 85
    private let itemSize: CGFloat = 36
    private let selectedSize: CGFloat = 54

    var body: some View {
        if appState.isConnected && isIdle && appState.currentMode == .direct && !actions.isEmpty {
            ZStack {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    let isSelected = index == selectedIndex
                    dialItem(action: action, index: index, isSelected: isSelected)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        // Vertical swipe: up = next, down = previous (natural thumb motion)
                        let threshold: CGFloat = 20
                        if value.translation.height < -threshold {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedIndex = (selectedIndex + 1) % actions.count
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } else if value.translation.height > threshold {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedIndex = (selectedIndex - 1 + actions.count) % actions.count
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    // MARK: - Dial Item

    @ViewBuilder
    private func dialItem(action: QuickAction, index: Int, isSelected: Bool) -> some View {
        let angle = angleFor(index: index)
        let size = isSelected ? selectedSize : itemSize
        let opacity = opacityFor(index: index)

        Button {
            if isSelected {
                executeAction(action)
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    selectedIndex = index
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(isSelected ? Color.accentColor.opacity(0.3) : .clear)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isSelected ? Color.accentColor : .white.opacity(0.15),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                        .frame(width: size, height: size)
                        .shadow(color: isSelected ? .accentColor.opacity(0.4) : .clear, radius: 8)

                    Image(systemName: action.icon)
                        .font(.system(size: size * 0.38, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.white)
                }

                if isSelected {
                    Text(action.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .offset(
            x: dialRadius * cos(angle),
            y: dialRadius * sin(angle)
        )
        .opacity(opacity)
        .scaleEffect(isSelected ? 1.0 : 0.85)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selectedIndex)
    }

    // MARK: - Layout

    /// Selected item at 3 o'clock (0 radians). Others distributed around the circle.
    private func angleFor(index: Int) -> CGFloat {
        let count = actions.count
        guard count > 0 else { return 0 }
        let step = 2 * CGFloat.pi / CGFloat(count)
        return CGFloat(index - selectedIndex) * step
    }

    /// Items far from selection fade out.
    private func opacityFor(index: Int) -> CGFloat {
        let count = actions.count
        let distance = min(
            abs(index - selectedIndex),
            count - abs(index - selectedIndex)
        )
        switch distance {
        case 0: return 1.0
        case 1: return 0.6
        case 2: return 0.3
        default: return 0.15
        }
    }

    // MARK: - Execution

    private func executeAction(_ action: QuickAction) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isExecuting = true

        Task {
            defer { isExecuting = false }

            switch action.type {
            case .prompt:
                guard let text = action.promptText, !text.isEmpty else { return }
                appState.speechService.startThinkingSound()
                do {
                    let response = try await appState.llmService.sendMessage(
                        text,
                        locationContext: appState.locationService.locationContext,
                        memoryContext: Config.userMemoryEnabled ? appState.userMemory.systemPromptContext() : nil
                    )
                    appState.lastResponse = response
                    await appState.speechService.speak(response)
                } catch {
                    appState.speechService.stopThinkingSound()
                    appState.errorMessage = error.localizedDescription
                }

            case .photo:
                await appState.captureAndAnalyzePhoto()

            case .photoThenPrompt:
                let prompt = action.promptText ?? "Describe what you see."
                await appState.capturePhotoAndSend(prompt: prompt)

            case .homeAssistant:
                guard let service = action.haService else {
                    appState.errorMessage = "No HA service configured"
                    return
                }
                var command = "Call Home Assistant service '\(service)'"
                if let entity = action.haEntityId, entity != "all" {
                    command += " on entity '\(entity)'"
                }
                if let data = action.haData, !data.isEmpty {
                    command += " with data: \(data)"
                }
                appState.speechService.startThinkingSound()
                do {
                    let response = try await appState.llmService.sendMessage(command, locationContext: nil, memoryContext: nil)
                    appState.lastResponse = response
                    await appState.speechService.speak(response)
                } catch {
                    appState.speechService.stopThinkingSound()
                    appState.errorMessage = error.localizedDescription
                }

            case .siriShortcut:
                guard let name = action.shortcutName, !name.isEmpty else { return }
                if let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
                    await MainActor.run { UIApplication.shared.open(url) }
                }

            case .openApp:
                guard let scheme = action.urlScheme, let url = URL(string: scheme) else { return }
                await MainActor.run { UIApplication.shared.open(url) }
            }
        }
    }
}
