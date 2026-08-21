import SwiftUI

/// The walkthrough offer: Otto built the steps, the user decides. A domain
/// illustration, the honest minutes, the first steps cascading in — and
/// one Start button that hands the session to the guidance runtime.
struct WalkthroughCardView: View {
    let walkthrough: Walkthrough
    let onStart: () -> Void
    let onDismiss: () -> Void

    private var session: Session { walkthrough.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerTile
            stepsPreview
            Button("Not now") {
                onDismiss()
            }
            .font(.callout)
            .foregroundStyle(OttoTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    /// The reference tile: tinted box, short title, two chips, one round
    /// play button. The steps preview cascades in underneath.
    private var headerTile: some View {
        let art = StepArt.art(for: session.title, domain: walkthrough.domain.rawValue)
        let tint = StepArt.color(for: art)
        return HStack(spacing: 12) {
            Image(systemName: art.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(OttoTheme.surface, in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(sessionShortTitle(session.title))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(OttoTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    chip("\(session.estimatedMinutes) min")
                    chip("\(session.steps.count) steps")
                }
            }
            Spacer(minLength: 8)
            Button {
                onStart()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(OttoTheme.ink, in: Circle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.88))
            .accessibilityLabel("Start \(session.title)")
        }
        .padding(12)
        .background(
            tint.opacity(0.30),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(OttoTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(OttoTheme.surface, in: Capsule())
    }

    private var stepsPreview: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(session.steps.prefix(4).enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 12) {
                    StepIllustration(
                        art: StepArt.art(
                            for: step.title,
                            cue: step.cue,
                            domain: walkthrough.domain.rawValue
                        ),
                        size: 30
                    )
                    Text(step.title)
                        .font(.callout)
                        .foregroundStyle(OttoTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let duration = step.target?.durationSec, step.type == .timed {
                        Text(Self.minutesLabel(seconds: duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                }
                .cascadeIn(index)
            }
            if session.steps.count > 4 {
                Text("+ \(session.steps.count - 4) more steps")
                    .font(.caption2)
                    .foregroundStyle(OttoTheme.textTertiary)
                    .cascadeIn(4)
            }
        }
    }

    static func minutesLabel(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(Int((Double(seconds) / 60).rounded())) min"
    }
}

/// The same rise-and-fade cascade the stage visuals use, local to this file.
private struct CascadeIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(
                    .spring(duration: 0.5, bounce: 0.25).delay(0.12 + Double(index) * 0.07)
                ) {
                    shown = true
                }
            }
    }
}

extension View {
    fileprivate func cascadeIn(_ index: Int) -> some View { modifier(CascadeIn(index: index)) }
}
