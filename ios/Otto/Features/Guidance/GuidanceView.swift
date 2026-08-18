import SwiftUI

/// The guided session screen — designed for a phone on a bench three feet
/// away, or a counter with wet hands. Huge type, a ring for time, one
/// full-width Done, no chrome anywhere. Voice does everything; the screen
/// confirms it.
struct GuidanceView: View {
    @Bindable var runtime: GuidanceRuntime

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch runtime.phase {
            case .running:
                activeSession
            case .finished(let early):
                finishedView(early: early)
            case .idle:
                Color.black
            }
        }
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(.white.opacity(0.4))
                    .kerning(1.5)
                Spacer()
                if runtime.isPaused {
                    Text("PAUSED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .kerning(1.5)
                } else if runtime.answeringQuestion {
                    Text("OTTO")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .kerning(1.5)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer(minLength: 12)

            // Readable across a room.
            Text(runtime.resting ? "Rest" : (runtime.currentStep?.title ?? ""))
                .font(.system(size: 54, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(3)
                .padding(.horizontal, 24)

            Spacer(minLength: 12)

            centerpiece

            Spacer(minLength: 12)

            if let next = runtime.nextStepTitle {
                Text("Next: \(next)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.3))
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
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white)
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
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                if let status = runtime.statusText {
                    Text(status)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func timerRing(_ timer: GuidanceTimerSnapshot) -> some View {
        let fraction = timer.total > 0 ? max(0, min(1, timer.remaining / timer.total)) : 0
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    timer.isPaused ? Color.orange : Color.white,
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
            VStack(spacing: 2) {
                Text(Self.clockText(timer.remaining))
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if let status = runtime.statusText {
                    Text(status)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 240, height: 240)
    }

    /// One full-width Done — the tap alternative to voice.
    private var doneButton: some View {
        Button {
            runtime.tap(.next)
        } label: {
            Text("Done")
                .font(.title2.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private var secondaryControls: some View {
        HStack {
            Button(runtime.isPaused ? "Resume" : "Pause") {
                runtime.tap(runtime.isPaused ? .resume : .pause)
            }
            Spacer()
            Button("Skip") {
                runtime.tap(.skip)
            }
            Spacer()
            Button("End") {
                runtime.tap(.stop)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.45))
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
                .foregroundStyle(.white)
            Text(early ? "Saved where you stopped" : "That's the session")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let snapshot = runtime.lastSnapshot {
                Text(Self.finishLine(snapshot))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                runtime.reset()
            } label: {
                Text("Done")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
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
