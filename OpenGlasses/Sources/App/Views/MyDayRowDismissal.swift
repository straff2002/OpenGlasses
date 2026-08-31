import SwiftUI

/// Swipe a My Day row left to clear it, Mail-style.
///
/// `.swipeActions` would have been the whole implementation, and it is not available: it is a
/// `List` modifier and no-ops anywhere else, while both My Day surfaces are `OGCard` → `VStack`
/// rows. Converting them to a `List` would take the card out of the app's shared card language and
/// unwind the manual `OGDivider` interleaving, to buy one gesture. So the gesture is built here.
///
/// The gesture stack is the reason this is worth its own file. The row lives inside the
/// conversation zone's *vertical* `ScrollView`, so the drag is constrained to the horizontal axis
/// and refuses any gesture whose vertical travel dominates — a scroll flick that grazes a row does
/// not open it. Nothing here fights the scroll view for a vertical drag; it never claims one.
struct MyDaySwipeToClear<Content: View>: View {
    let label: String
    let onClear: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var committed = false

    /// How far the row has to travel before the action commits on release, and how far it can be
    /// held open. A partial swipe rests at `revealWidth` showing the button; carrying on past
    /// `fullSwipe` clears on release without needing the button at all.
    private let revealWidth: CGFloat = 88
    private let fullSwipe: CGFloat = 200

    var body: some View {
        ZStack(alignment: .trailing) {
            // The button under the row. Drawn first so the row slides over it, and hidden from
            // VoiceOver — the named action below is how a screen reader reaches this, because a
            // control revealed by a gesture is a control it can never find.
            Button(action: clear) {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .foregroundStyle(OGTheme.onBadge)
                    .frame(width: revealWidth, height: OGMetrics.minTouchTarget)
                    .background(OGTheme.badge, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(offset < -8 ? 1 : 0)
            .accessibilityHidden(true)

            content()
                .background(OGTheme.card)
                .offset(x: offset)
                .simultaneousGesture(dragGesture)
        }
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: offset)
        // The gesture leaves no mark in the accessibility tree, so the action is the real control
        // for anyone driving this by voice or by rotor — not a convenience alongside it.
        .accessibilityAction(named: "Clear \(label) from My Day", clear)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Horizontal-only, and leftward only. A drag whose vertical travel dominates is the
                // scroll view's, and this gesture takes no position on it.
                guard !committed,
                      abs(value.translation.width) > abs(value.translation.height),
                      value.translation.width < 0 else { return }
                offset = max(value.translation.width, -fullSwipe)
            }
            .onEnded { value in
                guard !committed else { return }
                let travelled = -value.translation.width
                let flung = -value.predictedEndTranslation.width
                if travelled >= fullSwipe * 0.6 || flung >= fullSwipe {
                    clear()
                } else if travelled >= revealWidth * 0.5 {
                    offset = -revealWidth      // rest open, showing the button
                } else {
                    offset = 0
                }
            }
    }

    private func clear() {
        guard !committed else { return }
        committed = true
        // Slide the row out under its own animation before the snapshot recomposes without it, so
        // the row leaves rather than blinking out.
        withAnimation(.easeIn(duration: 0.18)) { offset = -fullSwipe * 2 }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onClear()
    }
}
