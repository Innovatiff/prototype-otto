import SwiftUI

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

/// The eclipse — Otto's presence. A black disc with a live glowing rim:
/// breathing when idle, burning with real mic energy while listening,
/// slowly turning while thinking, pulsing while speaking.
struct EclipseOrb: View {
    var state: VoiceLoopState
    /// Latest normalized mic level (0…1); drives the rim while the mic is hot.
    var level: Float
    var size: CGFloat = 240

    @State private var breathing = false
    @State private var spin = false

    private var rimEnergy: Double {
        switch state {
        case .idle:
            return 0.45
        case .listening:
            return 0.5 + Double(level) * 0.5
        case .thinking:
            return 0.6
        case .speaking:
            return 0.55 + Double(level) * 0.35
        }
    }

    var body: some View {
        ZStack {
            // Wide soft halo.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.28 * rimEnergy), .clear],
                        center: .center,
                        startRadius: size * 0.30,
                        endRadius: size * 0.68
                    )
                )
                .frame(width: size * 1.36, height: size * 1.36)

            // Bright rim, blurred out from behind the disc.
            Circle()
                .stroke(Color.white.opacity(0.85 * rimEnergy), lineWidth: size * 0.035)
                .frame(width: size, height: size)
                .blur(radius: size * 0.032)

            // Asymmetric highlight that turns while thinking — the "alive" cue.
            Circle()
                .trim(from: 0.05, to: 0.45)
                .stroke(
                    Color.white.opacity(0.5 * rimEnergy),
                    style: StrokeStyle(lineWidth: size * 0.02, lineCap: .round)
                )
                .frame(width: size, height: size)
                .blur(radius: size * 0.02)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(
                    state == .thinking
                        ? .linear(duration: 5).repeatForever(autoreverses: false)
                        : .default,
                    value: spin
                )

            // The black disc, with the thinnest crisp edge.
            Circle()
                .fill(Color.black)
                .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 1).blur(radius: 1.1))
                .frame(width: size, height: size)
        }
        .scaleEffect(breathing ? 1.015 : 0.985)
        .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: breathing)
        .animation(.linear(duration: 0.08), value: level)
        .onAppear {
            breathing = true
            spin = true
        }
        .accessibilityHidden(true)
    }
}

/// A circular monochrome control — mic, send, stop.
struct CircleIconButton: View {
    let systemName: String
    var prominent = false
    var diameter: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.38, weight: .medium))
                .foregroundStyle(prominent ? Color.black : OttoTheme.textPrimary)
                .frame(width: diameter, height: diameter)
                .background(prominent ? Color.white : OttoTheme.control, in: Circle())
                .overlay(Circle().stroke(OttoTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
