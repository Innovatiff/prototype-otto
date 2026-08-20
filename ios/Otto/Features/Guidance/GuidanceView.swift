import SwiftUI

/// The guided session screen — designed for a phone on a bench three feet
/// away, or a counter with wet hands. Light like the rest of the app:
/// huge ink type, each step illustrated in its own color, a colored ring
/// for time, one full-width Done. Voice does everything; the screen
/// confirms it.
struct GuidanceView: View {
    @Bindable var runtime: GuidanceRuntime

    /// The current step's illustration (a moon while resting).
    private var currentArt: StepArt.Art {
        if runtime.resting {
            return StepArt.Art(symbol: "moon.zzz.fill", paletteIndex: 2)
        }
        guard let step = runtime.currentStep else {
            return StepArt.Art(symbol: "sparkles", paletteIndex: 2)
        }
        return StepArt.art(for: step.title, cue: step.cue, domain: runtime.sessionDomain)
    }

    var body: some View {
        ZStack {
            OttoTheme.background.ignoresSafeArea()
            switch runtime.phase {
            case .running:
                activeSession
            case .finished(let early):
                finishedView(early: early)
            case .idle:
                OttoTheme.background
            }
        }
        .preferredColorScheme(.light)
        .statusBarHidden()
    }

    // MARK: - The active session

    private var activeSession: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.top, 14)
                .padding(.horizontal, 24)

            HStack {
                Text(runtime.sessionTitle.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OttoTheme.textTertiary)
                    .kerning(1.5)
                Spacer()
                if runtime.isPaused {
                    Text("PAUSED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OttoTheme.peach)
                        .kerning(1.5)
                } else if runtime.answeringQuestion {
                    Text("OTTO")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OttoTheme.textSecondary)
                        .kerning(1.5)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer(minLength: 12)

            // The slide: this step's illustration, then its title, readable
            // across a room. The id swap animates each step in — the screen
            // visibly turns a page instead of mutating text.
            VStack(spacing: 18) {
                StepIllustration(art: currentArt, size: 88)
                Text(runtime.resting ? "Rest" : (runtime.currentStep?.title ?? ""))
                    .font(.system(size: 50, weight: .heavy, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .lineLimit(3)
                    .padding(.horizontal, 24)
            }
            .id("step-\(runtime.stepIndex)-\(runtime.resting)")
            .transition(
                .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                )
            )

            Spacer(minLength: 12)

            centerpiece

            Spacer(minLength: 12)

            if let next = runtime.nextStepTitle {
                Text("Next: \(next)")
                    .font(.subheadline)
                    .foregroundStyle(OttoTheme.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            doneButton
            secondaryControls
        }
    }

    /// A thin bar across the top — the whole session at a glance.
    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OttoTheme.control)
                Capsule()
                    .fill(StepArt.color(for: currentArt))
                    .frame(
                        width: proxy.size.width
                            * (runtime.totalSteps > 0
                                ? CGFloat(runtime.stepIndex) / CGFloat(runtime.totalSteps)
                                : 0)
                    )
            }
        }
        .frame(height: 4)
        .animation(.snappy, value: runtime.stepIndex)
    }

    /// The middle of the screen: a big ring while anything counts down,
    /// otherwise the target in huge type.
    @ViewBuilder
    private var centerpiece: some View {
        if let timer = runtime.timer {
            // The runtime polls twice a second; observation re-renders the
            // ring on each update, and the linear animation glides between.
            timerRing(timer)
        } else {
            VStack(spacing: 10) {
                if let target = Self.targetText(runtime.currentStep) {
                    Text(target)
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(OttoTheme.textPrimary)
                        .monospacedDigit()
                }
                if let status = runtime.statusText {
                    Text(status)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(OttoTheme.textSecondary)
                }
            }
        }
    }

    private func timerRing(_ timer: GuidanceTimerSnapshot) -> some View {
        let fraction = timer.total > 0 ? max(0, min(1, timer.remaining / timer.total)) : 0
        // The last ten seconds lean in: the ring thickens and the digits
        // grow, in step with the "Ten seconds" clip and its haptic.
        let urgent = timer.remaining <= 10 && !timer.isPaused
        let ringColor = timer.isPaused ? OttoTheme.peach : StepArt.color(for: currentArt)
        return ZStack {
            Circle()
                .stroke(OttoTheme.control, lineWidth: urgent ? 17 : 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: urgent ? 17 : 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
            VStack(spacing: 2) {
                Text(Self.clockText(timer.remaining))
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.3), value: Self.clockText(timer.remaining))
                    .scaleEffect(urgent ? 1.07 : 1.0)
                if let status = runtime.statusText {
                    Text(status)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(OttoTheme.textSecondary)
                }
            }
        }
        .frame(width: 240, height: 240)
        .animation(.snappy(duration: 0.35), value: urgent)
        .accessibilityLabel("Timer, \(Self.clockText(timer.remaining)) remaining")
    }

    /// One full-width Done — the tap alternative to voice. The tick is the
    /// finger's acknowledgment; the heavier thunk lands when the step
    /// actually advances.
    private var doneButton: some View {
        Button {
            Haptics.tick()
            runtime.tap(.next)
        } label: {
            Text("Done")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(OttoTheme.ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .padding(.horizontal, 24)
        .accessibilityHint("Completes the current set or step, same as saying done")
    }

    private var secondaryControls: some View {
        HStack {
            Button(runtime.isPaused ? "Resume" : "Pause") {
                Haptics.tap()
                runtime.tap(runtime.isPaused ? .resume : .pause)
            }
            .accessibilityLabel(runtime.isPaused ? "Resume session" : "Pause session")
            Spacer()
            Button("Skip") {
                Haptics.tap()
                runtime.tap(.skip)
            }
            .accessibilityLabel("Skip this step")
            Spacer()
            Button("End") {
                Haptics.tap()
                runtime.tap(.stop)
            }
            .accessibilityLabel("End the session")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(OttoTheme.textSecondary)
        .padding(.horizontal, 40)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    // MARK: - Finished

    private func finishedView(early: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: early ? "flag.checkered" : "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(early ? OttoTheme.textPrimary : OttoTheme.mint)
            Text(early ? "Saved where you stopped" : "That's the session")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let snapshot = runtime.lastSnapshot {
                Text(Self.finishLine(snapshot))
                    .font(.title3)
                    .foregroundStyle(OttoTheme.textSecondary)
            }
            Spacer()
            Button {
                Haptics.tap()
                runtime.reset()
            } label: {
                Text("Done")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(OttoTheme.ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.97))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Display helpers (pure)

    /// "3 × 8" / "12:00" — the target in its biggest honest form.
    static func targetText(_ step: Step?) -> String? {
        guard let step else { return nil }
        if let target = step.target {
            if let sets = target.sets, let reps = target.reps {
                return "\(sets) × \(reps)"
            }
            if let reps = target.reps {
                return "\(reps)"
            }
            if let seconds = target.durationSec {
                return clockText(TimeInterval(seconds))
            }
        }
        return nil
    }

    static func clockText(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func finishLine(_ snapshot: GuidanceSnapshot) -> String {
        let done = snapshot.completedSteps.count
        let total = snapshot.totalSteps
        let minutes = max(1, Int(Date().timeIntervalSince(snapshot.startedAt) / 60))
        return "\(done) of \(total) steps · \(minutes) min"
    }
}
