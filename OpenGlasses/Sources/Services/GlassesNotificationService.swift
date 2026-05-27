import Foundation
import SwiftUI
import SystemNotification

/// Provides native iOS-style system notifications (like AirPods connection banners)
/// for glasses events. Uses the SystemNotification library for polished toast UI.
@MainActor
final class GlassesNotificationService: ObservableObject {
    @Published var currentNotification: GlassesNotification?
    @Published var isPresented: Bool = false

    struct GlassesNotification: Identifiable {
        let id = UUID()
        let title: String
        let message: String?
        let icon: String
        let style: Style

        enum Style {
            case success, warning, error, info
        }
    }

    // MARK: - Convenience Methods

    func showConnected(deviceName: String) {
        show(GlassesNotification(
            title: "Connected",
            message: deviceName,
            icon: "eyeglasses",
            style: .success
        ))
    }

    func showDisconnected() {
        show(GlassesNotification(
            title: "Disconnected",
            message: "Glasses connection lost",
            icon: "eyeglasses",
            style: .warning
        ))
    }

    func showToolResult(toolName: String, message: String) {
        show(GlassesNotification(
            title: toolName,
            message: message,
            icon: "checkmark.circle",
            style: .info
        ))
    }

    func showContextLoaded(source: String) {
        show(GlassesNotification(
            title: "Context Loaded",
            message: "From \(source)",
            icon: "doc.text.fill",
            style: .success
        ))
    }

    func showSceneObservation(_ observation: String) {
        show(GlassesNotification(
            title: "Scene",
            message: String(observation.prefix(80)),
            icon: "eye.fill",
            style: .info
        ))
    }

    func showError(_ message: String) {
        show(GlassesNotification(
            title: "Error",
            message: message,
            icon: "exclamationmark.triangle",
            style: .error
        ))
    }

    func showBatteryLow(level: Int) {
        show(GlassesNotification(
            title: "Low Battery",
            message: "Glasses at \(level)%",
            icon: "battery.25percent",
            style: .warning
        ))
    }

    func showGolfScore(hole: Int, score: String) {
        show(GlassesNotification(
            title: "Hole \(hole)",
            message: score,
            icon: "figure.golf",
            style: .success
        ))
    }

    // MARK: - Core

    private func show(_ notification: GlassesNotification) {
        currentNotification = notification
        isPresented = true

        // Auto-dismiss after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if currentNotification?.id == notification.id {
                isPresented = false
            }
        }
    }
}

// MARK: - SwiftUI View Modifier

/// Applies SystemNotification-style banner to a view.
/// Usage: `.glassesNotifications(service: notificationService)`
struct GlassesNotificationModifier: ViewModifier {
    @ObservedObject var service: GlassesNotificationService

    func body(content: Content) -> some View {
        content
            .systemNotification(isActive: $service.isPresented) {
                SystemNotificationContent(
                    notification: service.currentNotification ?? GlassesNotificationService.GlassesNotification(
                        title: "", message: nil, icon: "info.circle", style: .info
                    )
                )
            }
    }
}

/// The notification banner content view.
private struct SystemNotificationContent: View {
    let notification: GlassesNotificationService.GlassesNotification

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notification.icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                if let message = notification.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var iconColor: Color {
        switch notification.style {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return AppAccent.aiCoral
        }
    }
}

extension View {
    func glassesNotifications(service: GlassesNotificationService) -> some View {
        modifier(GlassesNotificationModifier(service: service))
    }
}
