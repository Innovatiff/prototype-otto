import SwiftUI
import UIKit

/// Otto's visual language — light and alive: warm white stage, ink type,
/// white cards floating on soft shadows, and a palette of real color used
/// generously but never loudly. Presentation only — no view logic here.
enum OttoTheme {
    /// Warm near-white stage.
    static let background = Color(red: 0.976, green: 0.976, blue: 0.968)
    /// Cards and fields: pure white, lifted by shadow rather than stroke.
    static let surface = Color.white
    /// Raised controls (circular buttons) and quiet fills.
    static let control = Color(red: 0.937, green: 0.937, blue: 0.925)
    /// Hairline strokes on surfaces.
    static let hairline = Color.black.opacity(0.06)

    /// Ink — the text color and the color of primary actions.
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let textPrimary = ink
    static let textSecondary = ink.opacity(0.52)
    static let textTertiary = ink.opacity(0.30)

    // ── The palette: real colors, used as soft fills with full-strength
    // glyphs. Drawn once here so every screen speaks the same language.
    static let sky = Color(red: 0.42, green: 0.72, blue: 0.96)
    static let mint = Color(red: 0.36, green: 0.82, blue: 0.66)
    static let lavender = Color(red: 0.66, green: 0.58, blue: 0.94)
    static let peach = Color(red: 0.99, green: 0.62, blue: 0.38)
    static let rose = Color(red: 0.96, green: 0.55, blue: 0.72)
    static let lemon = Color(red: 0.98, green: 0.80, blue: 0.30)

    /// Cycling accents for lists (plan cards, automations).
    static let palette: [Color] = [sky, mint, lavender, peach, rose, lemon]

    static let cardRadius: CGFloat = 22
    static let fieldRadius: CGFloat = 24
}

/// The one card treatment: white, continuous corners, a soft drop that
/// lifts it off the warm stage.
struct OttoCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                OttoTheme.surface,
                in: RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                    .stroke(OttoTheme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
    }
}

extension View {
    func ottoCard(padding: CGFloat = 16) -> some View {
        modifier(OttoCard(padding: padding))
    }
}

/// The speckled corona around the orb: thousands of tiny grains, dense at
/// the rim and thinning outward, rendered once into an image and cached.
/// Grains render WHITE and are tinted at display time (colorMultiply), so
/// the same cached fields serve any palette.
@MainActor
enum OrbGrain {
    /// Two independent grain fields; crossfading between them makes the
    /// corona twinkle and drift without any rotation.
    static let fieldA: UIImage = render(canvas: 560, rimRadius: 170, spread: 72, grains: 30000)
    static let fieldB: UIImage = render(canvas: 560, rimRadius: 170, spread: 72, grains: 30000)

    private static func render(
        canvas: CGFloat,
        rimRadius: CGFloat,
        spread: CGFloat,
        grains: Int
    ) -> UIImage {
        let size = CGSize(width: canvas, height: canvas)
        let center = CGPoint(x: canvas / 2, y: canvas / 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            for _ in 0..<grains {
                // Radial placement: hugging the rim, exponential falloff outward,
                // a whisper of spill inward over the edge.
                let angle = Double.random(in: 0..<(2 * .pi))
                let falloff = -log(Double.random(in: 0.0001...1))
                let outward = Double.random(in: 0...1) < 0.92
                let distance = outward
                    ? Double(rimRadius) + falloff * Double(spread) * 0.5
                    : Double(rimRadius) - falloff * Double(spread) * 0.12
                let x = center.x + CGFloat(cos(angle) * distance)
                let y = center.y + CGFloat(sin(angle) * distance)
                let nearness = max(0, 1 - abs(distance - Double(rimRadius)) / (Double(spread) * 1.4))
                let alpha = CGFloat(Double.random(in: 0.15...1) * nearness)
                let dot = CGFloat.random(in: 0.6...1.9)
                cg.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                cg.fillEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
            }
        }
    }
}

/// The orb — Otto's presence, now a small sun on a light stage. A colored
/// gradient sphere inside a tinted grain corona: breathing when idle,
/// burning with real mic energy while listening, pulsing while speaking.
/// (Type name kept from the dark era; every call site compiles unchanged.)
struct EclipseOrb: View {
    var state: VoiceLoopState
    /// Latest normalized mic level (0…1); drives the corona while the mic is hot.
    var level: Float
    var size: CGFloat = 250

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    /// Crossfade phase between the two grain fields — the corona's twinkle.
    @State private var shimmer = false
    /// Autonomous pulse while Otto talks — his output level isn't tapped, so
    /// the voice reads as a rhythmic burn rather than a meter.
    @State private var speakingPulse = false

    private var energy: Double {
        switch state {
        case .idle:
            return 0.55
        case .listening:
            return 0.6 + Double(level) * 0.4
        case .thinking:
            return 0.7
        case .speaking:
            return (speakingPulse ? 0.95 : 0.6) + Double(level) * 0.2
        }
    }

    /// Disc diameter relative to the grain canvas (560 canvas, 170 rim).
    private var discSize: CGFloat { size * (340.0 / 560.0) }

    var body: some View {
        ZStack {
            // Soft colored under-glow so the sphere sits in light.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OttoTheme.sky.opacity(0.30 * energy), .clear],
                        center: .center,
                        startRadius: discSize * 0.42,
                        endRadius: size * 0.52
                    )
                )
                .frame(width: size, height: size)

            // The corona: a blurred under-halo, then two grain fields
            // crossfading and micro-scaling out of phase — tinted sky and
            // lavender so the twinkle reads as color, not noise.
            Image(uiImage: OrbGrain.fieldA)
                .resizable()
                .frame(width: size, height: size)
                .colorMultiply(OttoTheme.sky)
                .opacity(0.5 * energy)
                .blur(radius: 5)
            Image(uiImage: OrbGrain.fieldA)
                .resizable()
                .frame(width: size, height: size)
                .colorMultiply(OttoTheme.sky)
                .opacity(energy * (shimmer ? 1.0 : 0.45))
                .scaleEffect(shimmer ? 1.012 : 1.0)
            Image(uiImage: OrbGrain.fieldB)
                .resizable()
                .frame(width: size, height: size)
                .colorMultiply(OttoTheme.lavender)
                .opacity(energy * (shimmer ? 0.45 : 1.0))
                .scaleEffect(shimmer ? 1.0 : 1.012)

            // The sphere: a diagonal wash of the palette with a top-left
            // highlight that gives it a body, and the thinnest bright edge.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [OttoTheme.mint, OttoTheme.sky, OttoTheme.lavender],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.55), .clear],
                                center: UnitPoint(x: 0.32, y: 0.28),
                                startRadius: 0,
                                endRadius: discSize * 0.7
                            )
                        )
                )
                .frame(width: discSize, height: discSize)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.9 * energy), lineWidth: 1.2)
                        .blur(radius: 0.8)
                )
                .shadow(color: OttoTheme.sky.opacity(0.35 * energy), radius: 24, y: 10)
        }
        .scaleEffect(breathing ? 1.012 : 0.988)
        .scaleEffect(speakingPulse ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: breathing)
        .animation(.linear(duration: 0.09), value: level)
        .onAppear {
            // Reduce Motion: the orb rests — no breathing, no shimmer,
            // no speaking pulse. It still colors and glows.
            guard !reduceMotion else { return }
            breathing = true
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .onChange(of: state) { _, newState in
            if newState == .speaking, !reduceMotion {
                // A strong rhythmic pulse — scale and corona brightness
                // together — for as long as Otto is talking.
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    speakingPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    speakingPulse = false
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Presses compress slightly — every control answers the finger.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The big mic — an ink disc in a soft well, white glyph, gently glowing
/// with the palette. The one dark object on the light stage, so the eye
/// lands on it.
struct MicButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // The soft well the disc sits in.
                Circle()
                    .fill(OttoTheme.control)
                    .frame(width: 104, height: 104)
                Circle()
                    .fill(OttoTheme.ink)
                    .frame(width: 74, height: 74)
                    .shadow(color: OttoTheme.sky.opacity(0.35), radius: 18)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                Image(systemName: systemName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
    }
}

/// A circular light control: white disc, ink glyph, floating on shadow.
struct CircleIconButton: View {
    let systemName: String
    var prominent = false
    var diameter: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.36, weight: .medium))
                .foregroundStyle(prominent ? Color.white : OttoTheme.ink)
                .frame(width: diameter, height: diameter)
                .background(prominent ? OttoTheme.ink : OttoTheme.surface, in: Circle())
                .overlay(Circle().stroke(OttoTheme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.88))
    }
}

/// The ink pill primary action ("Confirm", "Add all", "Send…").
struct InkPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(OttoTheme.ink, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
    }
}
