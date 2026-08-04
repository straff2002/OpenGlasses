import SwiftUI

/// The assistant's voice-state visual: a ribbon of distinct wave strands (the Siri-style idiom)
/// in the app's warm coral family — several lines that weave and cross, not one line with a glow.
///
/// Motion design: three FIXED sine harmonics whose per-state *amplitudes* are blended with eased
/// transitions — frequencies and phases never change, so a state switch morphs the wave instead of
/// jumping it. (Changing a frequency mid-animation jumps the sine phase; that discontinuity is
/// what makes cheap voice visuals twitch.) Each strand adds only CONSTANT phase offsets and a
/// constant speed detune, so the phase-continuity contract holds per strand too.
///
///   • idle      — calm, slowly interweaving threads: present, not busy
///   • listening — tight, quick, low ripple: attentive stillness
///   • thinking  — a slow swell with a fast shimmer riding it: working
///   • speaking  — tall, lively, flowing: talking
struct VoiceWaveline: View {

    var state: VoiceVisualState = .idle
    var height: CGFloat = 76
    @Environment(\.appAccent) private var accent

    /// A spectrum around the SELECTED accent — the primary strand is the accent itself and the
    /// companions are hue-rotated variants, spread far enough apart to stay clearly distinct
    /// (near-identical hues blur back into one thick line). With Coral selected this reproduces
    /// the original sunset ribbon; picking Blue or Green in Look & Feel re-dresses the wave the
    /// same way it re-dresses the rest of the app. A greyscale accent (White) has no hue to
    /// rotate, so the companions fan out in brightness instead.
    static func palette(around accent: Color) -> [Color] {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(accent).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        guard saturation > 0.05 else {
            return [0.85, 0.55, 0.70, brightness].map {
                Color(hue: 0, saturation: 0, brightness: $0)
            }
        }

        func companion(_ hueShift: CGFloat, _ brightnessScale: CGFloat) -> Color {
            let h = (hue + hueShift).truncatingRemainder(dividingBy: 1)
            return Color(hue: h < 0 ? h + 1 : h,
                         saturation: saturation,
                         brightness: min(1, brightness * brightnessScale))
        }
        // Matches the original coral ribbon's spread: gold ≈ +0.07, ember ≈ −0.04 and darker,
        // rose ≈ −0.10; the last entry is the untouched accent (primary strand).
        return [companion(0.07, 1.05), companion(-0.04, 0.80), companion(-0.10, 0.95), accent]
    }

    /// The ribbon, back to front. Offsets/detunes are constants (phase-continuous); the negative
    /// ampScale mirrors a strand so it *must* cross the others — that guaranteed crossing is what
    /// makes the eye read "several threads" instead of "one thick line".
    static func strands(around accent: Color) -> [WavelineStrand] {
        let colors = palette(around: accent)
        return [
            WavelineStrand(phaseShift: 2.1, timeScale: 0.82, ampScale:  0.90,
                           color: colors[0], lineWidth: 1.8, opacity: 0.75),
            WavelineStrand(phaseShift: 4.4, timeScale: 1.18, ampScale:  0.78,
                           color: colors[1], lineWidth: 1.8, opacity: 0.70),
            WavelineStrand(phaseShift: 1.1, timeScale: 0.94, ampScale: -0.75,
                           color: colors[2], lineWidth: 1.6, opacity: 0.75),
            WavelineStrand(phaseShift: 0.0, timeScale: 1.00, ampScale:  1.00,
                           color: colors[3], lineWidth: 2.4, opacity: 1.00),
        ]
    }

    @State private var amplitudes = WavelineParams.params(for: .idle)

    var body: some View {
        let strands = Self.strands(around: accent)
        // Capped at 60fps: the glow's 6px blur is an offscreen Gaussian pass per frame, and on
        // ProMotion an uncapped .animation runs it at 120Hz — twice the GPU/battery for motion
        // this slow-moving, with no visible difference.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                // Soft glow underlay traces the primary strand, then the ribbon on top.
                if let primary = strands.last {
                    var glow = context
                    glow.addFilter(.blur(radius: 6))
                    glow.stroke(strandPath(primary, time: t, size: size),
                                with: shading(for: primary, opacityScale: 0.30, width: size.width),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
                for strand in strands {
                    context.stroke(strandPath(strand, time: t, size: size),
                                   with: shading(for: strand, width: size.width),
                                   style: StrokeStyle(lineWidth: strand.lineWidth, lineCap: .round))
                }
            }
        }
        .frame(height: height)
        .onChange(of: state) { _, newState in
            withAnimation(.easeInOut(duration: 0.6)) {
                amplitudes = WavelineParams.params(for: newState)
            }
        }
        .onAppear { amplitudes = WavelineParams.params(for: state) }
        .accessibilityHidden(true)   // decorative; state is announced elsewhere
        .animation(.easeInOut(duration: 0.6), value: amplitudes)
    }

    private func strandPath(_ strand: WavelineStrand, time: Double, size: CGSize) -> Path {
        let midY = size.height / 2
        var path = Path()
        let steps = max(48, Int(size.width / 4))
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let y = midY + WavelineParams.displacement(
                phase: Double(i) / Double(steps),
                time: time,
                amplitudes: amplitudes,
                phaseShift: strand.phaseShift,
                timeScale: strand.timeScale) * midY * 0.85 * strand.ampScale
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    /// Edge-faded stroke gradient in the strand's own colour.
    private func shading(for strand: WavelineStrand, opacityScale: Double = 1, width: CGFloat) -> GraphicsContext.Shading {
        let peak = strand.opacity * opacityScale
        return .linearGradient(
            Gradient(colors: [strand.color.opacity(0.0),
                              strand.color.opacity(peak),
                              strand.color.opacity(peak),
                              strand.color.opacity(0.0)]),
            startPoint: .zero,
            endPoint: CGPoint(x: width, y: 0))
    }
}

/// One thread of the ribbon: constant phase offset + constant speed detune (so each strand is
/// individually phase-continuous), its own accent-family colour, weight, and amplitude scale.
struct WavelineStrand {
    let phaseShift: Double
    let timeScale: Double
    let ampScale: Double
    let color: Color
    let lineWidth: CGFloat
    let opacity: Double
}

/// The home screen's atmosphere: a faint accent radiance behind the conversation zone that
/// breathes with the same voice state as the waveline — one motion system, two expressions.
/// Deliberately near-subliminal (single-digit opacities): the screen should feel lit by the
/// assistant's presence, never painted with it. Sits over the system background, so light and
/// dark mode both keep their character.
struct VoiceAmbience: View {
    var state: VoiceVisualState = .idle
    @Environment(\.appAccent) private var accent

    private var glow: Double {
        switch state {
        case .idle: return 0.04
        case .listening: return 0.06
        case .thinking: return 0.07
        case .speaking: return 0.11
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [accent.opacity(glow), .clear],
                center: UnitPoint(x: 0.5, y: 0.42),   // behind the waveline zone
                startRadius: 0,
                endRadius: 420)
            // A whisper of depth toward the controls, so the bottom zone reads grounded.
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.03)],
                startPoint: UnitPoint(x: 0.5, y: 0.55),
                endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.9), value: glow)
        .accessibilityHidden(true)
    }
}

/// What the assistant is doing, as the waveline sees it.
enum VoiceVisualState: Equatable {
    case idle, listening, thinking, speaking

    /// Fuse the app's observable signals into one visual state. Pure — precedence is
    /// speaking > thinking > listening > idle, because the *most active* thing happening is what
    /// the eye should confirm. In a realtime session the mic is always open, so an active session
    /// that isn't speaking reads as listening.
    static func from(isSpeaking: Bool, isProcessing: Bool, isListening: Bool,
                     realtimeActive: Bool = false) -> VoiceVisualState {
        if isSpeaking { return .speaking }
        if isProcessing { return .thinking }
        if isListening || realtimeActive { return .listening }
        return .idle
    }
}

/// The waveline's motion parameters — pure and headless-testable.
///
/// Three fixed harmonics (a slow travelling swell, a mid flow, a fast shimmer); states blend
/// their amplitudes. An envelope pins both ends of the line to the midline so the wave lives in
/// the middle, like speech.
struct WavelineParams: Equatable, Animatable {
    var slow: Double
    var mid: Double
    var fast: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(slow, AnimatablePair(mid, fast)) }
        set { slow = newValue.first; mid = newValue.second.first; fast = newValue.second.second }
    }

    /// Fixed frequencies: spatial (cycles across the width) and temporal (radians/second).
    /// Never state-dependent — see the phase-continuity note on `VoiceWaveline`.
    static let spatial: (slow: Double, mid: Double, fast: Double) = (1.1, 2.3, 4.7)
    static let temporal: (slow: Double, mid: Double, fast: Double) = (1.4, 2.2, 5.6)

    static func params(for state: VoiceVisualState) -> WavelineParams {
        switch state {
        case .idle:      return WavelineParams(slow: 0.18, mid: 0.06, fast: 0.00)
        case .listening: return WavelineParams(slow: 0.08, mid: 0.12, fast: 0.22)
        case .thinking:  return WavelineParams(slow: 0.30, mid: 0.08, fast: 0.14)
        case .speaking:  return WavelineParams(slow: 0.50, mid: 0.32, fast: 0.18)
        }
    }

    /// Normalized displacement (−1…1 scale) at `phase` ∈ 0…1 across the width, at `time`.
    /// Waves *travel* (time enters as phase offset), and the end-pin envelope keeps the line
    /// anchored at both edges. `phaseShift`/`timeScale` are a strand's constant offsets — the
    /// shift is decorrelated per harmonic (×1, ×1.7, ×2.3) so strands separate instead of
    /// running parallel; being constants, they preserve phase continuity.
    static func displacement(phase: Double, time: Double, amplitudes: WavelineParams,
                             phaseShift: Double = 0, timeScale: Double = 1) -> Double {
        let envelope = sin(phase * .pi)   // 0 at both ends, 1 in the middle
        let s = sin(phase * spatial.slow * 2 * .pi + time * temporal.slow * timeScale + phaseShift) * amplitudes.slow
        let m = sin(phase * spatial.mid * 2 * .pi - time * temporal.mid * timeScale + phaseShift * 1.7) * amplitudes.mid
        let f = sin(phase * spatial.fast * 2 * .pi + time * temporal.fast * timeScale + phaseShift * 2.3) * amplitudes.fast
        return (s + m + f) * envelope
    }
}
