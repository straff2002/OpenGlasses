import SwiftUI

/// When the Home screen shows the live-hints card (Plan MO P2). Pure.
///
/// While a session runs (real or demo) the card is always there: it is the way back to the session
/// screen and to a dismissed lens card, and it carries the Listening pill. Otherwise it shows only
/// with the feature switched on *and* the wearer having placed it on Home (Edit Home › Cards, off
/// by default), and it yields the zone the way the day card does (to a reply being worked out or
/// spoken, and to captions).
enum LiveHintsHomeCardRule {
    /// The placement's `UserDefaults` key (`Config.liveHintsOnHome`).
    static let onHomeKey = "liveHintsOnHome"

    static func shows(featureOn: Bool, onHome: Bool, sessionRunning: Bool, surfaceFree: Bool) -> Bool {
        if sessionRunning { return true }
        return featureOn && onHome && surfaceFree
    }
}

/// Live hints' card on the Home screen (Plan MO P2): one row that opens the session sheet, and,
/// while a session runs, the Listening pill and the way back to it.
struct LiveHintsHomeCard: View {
    @ObservedObject var service: LiveHintsService
    @ObservedObject var demo: LiveHintsService
    var onOpen: () -> Void

    @Environment(\.appAccent) private var accent

    private var running: LiveHintsService? {
        service.isRunning ? service : (demo.isRunning ? demo : nil)
    }

    var body: some View {
        Button(action: onOpen) {
            OGCard {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.title3)
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live hints")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if running != nil {
                        OGStatusPill(text: String(localized: "Listening",
                                                  comment: "Live hints: the pill shown for the whole of a session."),
                                     dot: OGTheme.ok)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(minHeight: OGMetrics.minTouchTarget)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(running == nil ? "Opens live hints" : "Opens the live hints session"))
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var subtitle: String {
        if let running {
            return running === demo
                ? String(localized: "The demo is running. Open it to see the hints.",
                         comment: "Live hints Home card while the demo session runs.")
                : String(localized: "Open it to see your hints.",
                         comment: "Live hints Home card while a session runs.")
        }
        return String(localized: "When someone asks you a question, a short answer from your documents.",
                      comment: "Live hints Home card: what the feature does.")
    }
}
