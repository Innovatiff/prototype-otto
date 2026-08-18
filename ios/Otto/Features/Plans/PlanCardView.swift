import SwiftUI

/// The full generated plan, on screen while Otto speaks only its summary —
/// a plan is never read aloud. Weeks first (the shape of the program), then
/// the session templates with their steps.
struct PlanCardView: View {
    let plan: Plan
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    weeksSection
                    sessionsSection
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .background(
            OttoTheme.surface,
            in: RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                .stroke(OttoTheme.hairline, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("YOUR PLAN")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OttoTheme.textTertiary)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OttoTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(OttoTheme.control, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss plan")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.meta.goal)
                .font(.title3.weight(.semibold))
                .foregroundStyle(OttoTheme.textPrimary)
            Text(metaLine)
                .font(.caption)
                .foregroundStyle(OttoTheme.textSecondary)
        }
    }

    private var weeksSection: some View {
        section("WEEK BY WEEK") {
            ForEach(0..<weekCount, id: \.self) { week in
                weekRow(week)
            }
        }
    }

    private func weekRow(_ week: Int) -> some View {
        let entries = entriesInWeek(week)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("W\(week + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(OttoTheme.textSecondary)
                .frame(width: 34, alignment: .leading)
            Text(entries.isEmpty ? "rest" : weekTitles(entries))
                .font(.caption)
                .foregroundStyle(entries.isEmpty ? OttoTheme.textTertiary : OttoTheme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if isDeloadWeek(entries) {
                Text("DELOAD")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white, in: Capsule())
            }
        }
    }

    private var sessionsSection: some View {
        section("SESSIONS") {
            ForEach(plan.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(OttoTheme.textPrimary)
                        Spacer()
                        Text("\(session.estimatedMinutes) min")
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textSecondary)
                    }
                    ForEach(session.steps) { step in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.title)
                                    .font(.caption)
                                    .foregroundStyle(OttoTheme.textPrimary)
                                Spacer()
                                if let target = targetLine(step) {
                                    Text(target)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(OttoTheme.textSecondary)
                                }
                            }
                            Text(step.cue)
                                .font(.caption2)
                                .foregroundStyle(OttoTheme.textTertiary)
                                .lineLimit(3)
                        }
                        .padding(.leading, 10)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OttoTheme.textTertiary)
            content()
        }
    }

    // MARK: - Derivations (pure functions of the plan)

    private var weekCount: Int {
        max(1, Int((Double(plan.meta.horizonDays) / 7).rounded(.up)))
    }

    private var metaLine: String {
        var parts = ["\(weekCount) weeks"]
        let perWeek = typicalSessionsPerWeek
        if perWeek > 0 {
            parts.append("\(perWeek)/week")
        }
        let minutes = plan.sessions.map(\.estimatedMinutes)
        if let shortest = minutes.min(), let longest = minutes.max() {
            parts.append(shortest == longest ? "~\(longest) min" : "~\(shortest)-\(longest) min")
        }
        return parts.joined(separator: " · ")
    }

    /// The most common per-week session count.
    private var typicalSessionsPerWeek: Int {
        var counts: [Int: Int] = [:]
        for entry in plan.schedule {
            counts[entry.dayOffset / 7, default: 0] += 1
        }
        var frequency: [Int: Int] = [:]
        for count in counts.values {
            frequency[count, default: 0] += 1
        }
        return frequency.max { a, b in
            (a.value, a.key) < (b.value, b.key)
        }?.key ?? 0
    }

    private func entriesInWeek(_ week: Int) -> [ScheduledSession] {
        plan.schedule
            .filter { $0.dayOffset / 7 == week }
            .sorted { $0.dayOffset < $1.dayOffset }
    }

    private func weekTitles(_ entries: [ScheduledSession]) -> String {
        let titlesById = Dictionary(
            plan.sessions.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries
            .map { titlesById[$0.sessionId] ?? $0.sessionId }
            .joined(separator: " · ")
    }

    /// Mirrors the server's rule: every entry at or below 0.8 load.
    private func isDeloadWeek(_ entries: [ScheduledSession]) -> Bool {
        !entries.isEmpty
            && entries.allSatisfy { ($0.progression?.loadMultiplier ?? 1.0) <= 0.8 }
    }

    private func targetLine(_ step: Step) -> String? {
        guard let target = step.target else { return nil }
        var parts: [String] = []
        if let sets = target.sets, let reps = target.reps {
            parts.append("\(sets)×\(reps)")
        } else if let reps = target.reps {
            parts.append("\(reps) reps")
        }
        if let load = target.load {
            parts.append(
                load == load.rounded()
                    ? "\(Int(load)) kg"
                    : String(format: "%.1f kg", load)
            )
        }
        if let seconds = target.durationSec {
            parts.append(seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
