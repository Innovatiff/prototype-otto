import SwiftUI

/// The hub's Plans pane — viewing only; the guidance runtime is Phase 5.
/// Overview, week-by-week, tappable sessions, version history, and the
/// "Adapt this plan" entry point (adaptation is spoken, so it opens the
/// mic).
struct PlansView: View {
    @Bindable var model: PlansModel
    /// Dismisses the hub and starts listening — the user says what changed.
    let onAdaptPlan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = model.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 18)
                }
                if model.activePlans.isEmpty {
                    emptyState
                } else {
                    ForEach(model.activePlans) { active in
                        PlanSectionView(active: active, model: model, onAdaptPlan: onAdaptPlan)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(OttoTheme.textTertiary)
            Text(model.isLoading ? "Loading plans…" : "No plans yet")
                .font(.headline)
                .foregroundStyle(OttoTheme.textPrimary)
            if !model.isLoading {
                Text("Ask Otto for a workout program, a weekly structure, or a study plan.")
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One active plan: overview → weeks → sessions → history. Selecting a
/// historical version shows it read-only in the same slot.
private struct PlanSectionView: View {
    let active: PlanSummary
    @Bindable var model: PlansModel
    let onAdaptPlan: () -> Void

    /// nil = the current (active) version.
    @State private var selectedVersionId: String?

    private var shownId: String { selectedVersionId ?? active.id }
    private var shownPlan: Plan? { model.details[shownId] }
    private var chain: [PlanSummary] { model.chain(for: active) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            overview
            if selectedVersionId != nil {
                supersededBanner
            }
            if let plan = shownPlan {
                weeksSection(plan)
                sessionsSection(plan)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textTertiary)
            }
            if chain.count > 1 {
                historySection
            }
        }
        .padding(16)
        .background(
            OttoTheme.surface,
            in: RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                .stroke(OttoTheme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .task(id: shownId) { await model.loadDetail(id: shownId) }
    }

    // MARK: - Overview: goal, horizon, sessions per week

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(active.meta.goal)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(OttoTheme.textPrimary)
                Spacer()
                Text(active.meta.domain.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OttoTheme.textTertiary)
            }
            Text(overviewLine)
                .font(.caption)
                .foregroundStyle(OttoTheme.textSecondary)

            Button(action: onAdaptPlan) {
                Label("Adapt this plan", systemImage: "mic.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Text("Tell Otto what changed — an injury, missed days, a new schedule.")
                .font(.caption2)
                .foregroundStyle(OttoTheme.textTertiary)
        }
    }

    private var overviewLine: String {
        let weeks = PlansModel.weekCount(horizonDays: active.meta.horizonDays)
        var parts = ["\(weeks) weeks"]
        if let plan = model.details[active.id] {
            let perWeek = Self.typicalPerWeek(plan)
            if perWeek > 0 { parts.append("\(perWeek) sessions/week") }
        } else {
            parts.append("\(active.scheduleEntryCount) sessions")
        }
        parts.append("week \(PlansModel.week(of: active, now: Date())) of \(weeks)")
        parts.append("v\(active.meta.version)")
        return parts.joined(separator: " · ")
    }

    private var supersededBanner: some View {
        HStack {
            Text("Viewing an earlier version — superseded")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Back to current") {
                withAnimation(.snappy) { selectedVersionId = nil }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(OttoTheme.textPrimary)
        }
    }

    // MARK: - Week by week

    private func weeksSection(_ plan: Plan) -> some View {
        section("WEEK BY WEEK") {
            ForEach(0..<PlansModel.weekCount(horizonDays: plan.meta.horizonDays), id: \.self) { week in
                let entries = plan.schedule
                    .filter { $0.dayOffset / 7 == week }
                    .sorted { $0.dayOffset < $1.dayOffset }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("W\(week + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(OttoTheme.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    Text(entries.isEmpty ? "rest" : Self.weekTitles(entries, plan: plan))
                        .font(.caption)
                        .foregroundStyle(entries.isEmpty ? OttoTheme.textTertiary : OttoTheme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if Self.isDeloadWeek(entries) {
                        Text("DELOAD")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Sessions (tap to see steps)

    private func sessionsSection(_ plan: Plan) -> some View {
        section("SESSIONS — tap for steps") {
            ForEach(plan.sessions) { session in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.steps) { step in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(step.title)
                                        .font(.caption)
                                        .foregroundStyle(OttoTheme.textPrimary)
                                    Spacer()
                                    if let target = Self.targetLine(step) {
                                        Text(target)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(OttoTheme.textSecondary)
                                    }
                                }
                                Text(step.cue)
                                    .font(.caption2)
                                    .foregroundStyle(OttoTheme.textTertiary)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Text(session.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(OttoTheme.textPrimary)
                        Spacer()
                        Text("\(session.estimatedMinutes) min · \(session.steps.count) steps")
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textSecondary)
                    }
                }
                .tint(OttoTheme.textSecondary)
            }
        }
    }

    // MARK: - Version history

    private var historySection: some View {
        section("HISTORY") {
            ForEach(chain) { version in
                Button {
                    withAnimation(.snappy) {
                        selectedVersionId = version.id == active.id ? nil : version.id
                    }
                } label: {
                    HStack {
                        Text("v\(version.meta.version)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(
                                shownId == version.id ? OttoTheme.textPrimary : OttoTheme.textSecondary
                            )
                            .frame(width: 34, alignment: .leading)
                        Text(version.id == active.id ? "current" : "adapted away")
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textSecondary)
                        Spacer()
                        Text(version.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
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

    // MARK: - Derivations

    private static func typicalPerWeek(_ plan: Plan) -> Int {
        var counts: [Int: Int] = [:]
        for entry in plan.schedule {
            counts[entry.dayOffset / 7, default: 0] += 1
        }
        var frequency: [Int: Int] = [:]
        for count in counts.values {
            frequency[count, default: 0] += 1
        }
        return frequency.max { a, b in (a.value, a.key) < (b.value, b.key) }?.key ?? 0
    }

    private static func weekTitles(_ entries: [ScheduledSession], plan: Plan) -> String {
        let titlesById = Dictionary(
            plan.sessions.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.map { titlesById[$0.sessionId] ?? $0.sessionId }.joined(separator: " · ")
    }

    private static func isDeloadWeek(_ entries: [ScheduledSession]) -> Bool {
        !entries.isEmpty
            && entries.allSatisfy { ($0.progression?.loadMultiplier ?? 1.0) <= 0.8 }
    }

    private static func targetLine(_ step: Step) -> String? {
        guard let target = step.target else { return nil }
        var parts: [String] = []
        if let sets = target.sets, let reps = target.reps {
            parts.append("\(sets)×\(reps)")
        } else if let reps = target.reps {
            parts.append("\(reps) reps")
        }
        if let load = target.load {
            parts.append(
                load == load.rounded() ? "\(Int(load)) kg" : String(format: "%.1f kg", load)
            )
        }
        if let seconds = target.durationSec {
            parts.append(seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
