import SwiftUI

/// Live on-phone mirror of the in-lens HUD (Display Phase 4 / Plan Y). Observes the
/// router's current interactive screen and renders it through `HUDPreviewView`, so you
/// can watch the real HUD — task cards and launcher menus — on the phone in real time,
/// with or without Display glasses. (The router sets its `currentScreen` regardless of
/// whether the glasses actually render, so this works device-less.)
///
/// View-only: drive the HUD with the Neural Band or voice; this just reflects it. The one
/// exception is the manual page (Plan KV P3): while it is on the lens, its buttons work here
/// too (`HUDRouter.pressFromPreview`), so the page view can be walked from the phone.
struct HUDMirrorView: View {
    @ObservedObject var router: HUDRouter

    var body: some View {
        VStack(spacing: 16) {
            if let frame = router.previewFrame {
                // Plan KV P3: while the manual page is on the lens, its buttons work here too, through
                // the same page session the band presses.
                HUDPreviewView(screen: frame.screen,
                               onPress: frame.isPressable ? { [router] id in router.pressFromPreview(id) } : nil)
                    .padding(.horizontal)
                Text("Live — this is what's on the lens.")
                    .font(.footnote)
                    .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
                if frame.isPressable {
                    Text("The page's buttons work here too.")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
                }
                #if !AVENKIN_PHONE_ONLY
                // Plan KP §6: the preview is drawn to the lens's shape at estimated text sizes.
                Text("Drawn to the lens's shape. Text sizes are estimates.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
                    .padding(.horizontal)
                #endif
            } else {
                ContentUnavailableView(
                    "HUD idle",
                    systemImage: "eyeglasses",
                    description: Text("Start a workflow or say \u{201C}menu\u{201D} to drive the HUD — it mirrors here in real time.")
                )
                .foregroundStyle(OGTheme.onMedia, OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical)
        // The mirror reflects the lens itself, so — like the camera preview and the
        // HUD panel it hosts — the page sits on the fixed media ground rather than
        // the warm canvas, with the nav bar chrome flipped to match so its title and
        // back control stay legible over black in light mode too.
        .background(OGTheme.media.ignoresSafeArea())
        .navigationTitle("HUD Mirror")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
