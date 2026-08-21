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
            header
            Rectangle()
                .fill(OttoTheme.hairline)
                .frame(height: 1)
            stepsPreview
            HStack {
                Button("Not now") {
                    onDismiss()
                }
                .font(.callout)
                .foregroundStyle(OttoTheme.textSecondary)
                Spacer()
                InkPillButton(title: "Start walkthrough") {
                    onStart()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    private var header: some View {
        HStack(spacing: 14) {
            StepIllustration(
                art: StepArt.art(for: session.title, domain: walkthrough.domain.rawValue),
                size: 52
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .lineLimit(2)
                Text("\(session.estimatedMinutes) min · \(session.steps.count) steps")
                    .font(.subheadline)
                    .foregroundStyle(OttoTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OttoTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(OttoTheme.control, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss walkthrough")
        }
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
