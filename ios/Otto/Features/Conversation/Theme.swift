import SwiftUI
import UIKit

/// Otto's visual language: pure black stage, monochrome type, dark rounded
/// surfaces, circular controls. Presentation only — no view logic here.
enum OttoTheme {
    /// True black stage.
    static let background = Color.black
    /// Cards and fields.
    static let surface = Color(white: 0.09)
    /// Raised controls (circular buttons).
    static let control = Color(white: 0.14)
    /// Hairline strokes on surfaces.
    static let hairline = Color.white.opacity(0.08)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)

    static let cardRadius: CGFloat = 22
    static let fieldRadius: CGFloat = 24
}

/// The speckled corona around the eclipse: thousands of tiny grains, dense
/// at the rim and thinning outward, rendered once into an image and cached.
/// This is what makes the orb read as light, not as a vector circle.
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

/// The eclipse — Otto's presence. A black disc inside a grainy corona:
/// breathing when idle, burning with real mic energy while listening,
/// slowly turning while thinking, pulsing while speaking.
struct EclipseOrb: View {
    var state: VoiceLoopState
    /// Latest normalized mic level (0…1); drives the corona while the mic is hot.
    var level: Float
    var size: CGFloat = 250

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
            // Soft under-glow so the grain sits in light, not on flat black.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.22 * energy), .clear],
                        center: .center,
                        startRadius: discSize * 0.42,
                        endRadius: size * 0.52
                    )
                )
                .frame(width: size, height: size)

            // The corona: a blurred under-halo, then two grain fields
            // crossfading and micro-scaling out of phase — grains twinkle
            // and drift, but nothing rotates.
            Image(uiImage: OrbGrain.fieldA)
                .resizable()
                .frame(width: size, height: size)
                .opacity(0.5 * energy)
                .blur(radius: 5)
            Image(uiImage: OrbGrain.fieldA)
                .resizable()
                .frame(width: size, height: size)
                .opacity(energy * (shimmer ? 1.0 : 0.45))
                .scaleEffect(shimmer ? 1.012 : 1.0)
            Image(uiImage: OrbGrain.fieldB)
                .resizable()
                .frame(width: size, height: size)
                .opacity(energy * (shimmer ? 0.45 : 1.0))
                .scaleEffect(shimmer ? 1.0 : 1.012)

            // The black disc with the thinnest bright edge.
            Circle()
                .fill(Color.black)
                .frame(width: discSize, height: discSize)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.8 * energy), lineWidth: 1.2)
                        .blur(radius: 0.8)
                )
        }
        .scaleEffect(breathing ? 1.012 : 0.988)
        .scaleEffect(speakingPulse ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: breathing)
        .animation(.linear(duration: 0.09), value: level)
        .onAppear {
            breathing = true
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .onChange(of: state) { _, newState in
            if newState == .speaking {
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

/// The big mic — a full-white disc with a soft elevation ring and glow,
/// black glyph, exactly the reference's center control.
struct MicButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // The soft ring the white disc sits in.
                Circle()
                    .fill(Color(white: 0.12))
                    .frame(width: 104, height: 104)
                Circle()
                    .fill(Color.white)
                    .frame(width: 74, height: 74)
                    .shadow(color: .white.opacity(0.22), radius: 18)
                    .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
                Image(systemName: systemName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.black)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A circular monochrome control — hub, mic, settings.
struct CircleIconButton: View {
    let systemName: String
    var prominent = false
    var diameter: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.36, weight: .medium))
                .foregroundStyle(prominent ? Color.black : OttoTheme.textPrimary)
                .frame(width: diameter, height: diameter)
                .background(prominent ? Color.white : OttoTheme.control, in: Circle())
                .overlay(Circle().stroke(OttoTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
