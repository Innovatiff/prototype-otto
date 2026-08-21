import SwiftUI

/// The Plans page, minimal: a tinted UP NEXT tile per plan — short title,
/// two chips, one play button — and a compact row per plan underneath.
/// Everything dense (goal, week by week, sessions, history) lives one tap
/// away in the detail screen.
struct PlansView: View {
    @Bindable var model: PlansModel
    /// Dismisses the hub and starts listening — the user says what changed.
    let onAdaptPlan: () -> Void
    /// Dismisses the hub and launches the guided session for this plan.
    let onStartSession: (Plan) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = model.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if model.activePlans.isEmpty {
                    emptyState
                } else {
                    upNextSection
                    plansSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    // MARK: - Up next: one tile per plan, reference-style

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("UP NEXT")
            ForEach(Array(model.activePlans.enumerated()), id: \.element.id) { index, active in
                UpNextTile(
                    active: active,
                    model: model,
                    onAdaptPlan: onAdaptPlan,
                    onStartSession: onStartSession
                )
                .cascadeIn(index)
            }
        }
    }

    // MARK: - The plans themselves, one quiet row each

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("YOUR PLANS")
            ForEach(Array(model.activePlans.enumerated()), id: \.element.id) { index, active in
                NavigationLink {
                    PlanDetailView(
                        active: active,
                        model: model,
                        onAdaptPlan: onAdaptPlan,
                        onStartSession: onStartSession
                    )
                } label: {
                    PlanRow(active: active, model: model)
                }
                .buttonStyle(.plain)
                .cascadeIn(index + 2)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(OttoTheme.textTertiary)
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

// MARK: - Naming

/// "Full Body B — Hinge & Pull Emphasis" → "Full Body B". The em-dash
/// detail belongs to the detail screen, not a tile.
func sessionShortTitle(_ title: String) -> String {
    title.components(separatedBy: " — ").first?
        .trimmingCharacters(in: .whitespaces) ?? title
}

// MARK: - The up-next tile (the reference design)

/// A tinted box: short session title, "NN min" + day chips, one round
/// play button. Tapping the box opens the plan; the button starts it.
private struct UpNextTile: View {
    let active: PlanSummary
    @Bindable var model: PlansModel
    let onAdaptPlan: () -> Void
    let onStartSession: (Plan) -> Void

    private var tint: Color {
        StepArt.color(for: StepArt.art(for: "", domain: active.meta.domain))
    }

    var body: some View {
        Group {
            if let plan = model.details[active.id] {
                if let next = PlanScheduling.nextOccurrence(in: plan, now: Date()) {
                    NavigationLink {
                        PlanDetailView(
                            active: active,
                            model: model,
                            onAdaptPlan: onAdaptPlan,
                            onStartSession: onStartSession
                        )
                    } label: {
                        tile(plan: plan, next: next)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.98))
                }
                // A finished plan has no next occurrence — no tile.
            } else {
                // Placeholder keeps the slot (and this view in the
                // hierarchy, so the load below actually fires).
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(height: 72)
                    .overlay(ProgressView().tint(OttoTheme.textTertiary))
            }
        }
        .task(id: active.id) { await model.loadDetail(id: active.id) }
    }

    private func tile(
        plan: Plan, next: (entry: ScheduledSession, session: Session, date: Date)
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                Text(sessionShortTitle(next.session.title))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(OttoTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    TileChip(text: "\(next.session.estimatedMinutes) min")
                    TileChip(text: dayLabel(next.date))
                }
            }
            Spacer(minLength: 8)
            Button {
                Haptics.press()
                onStartSession(plan)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(OttoTheme.ink, in: Circle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.88))
            .accessibilityLabel("Start \(sessionShortTitle(next.session.title))")
        }
        .padding(14)
        .background(
            tint.opacity(0.30),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private func dayLabel(_ date: Date) -> String {
        Foundation.Calendar.current.isDateInToday(date)
            ? "Today"
            : date.formatted(.dateTime.weekday(.abbreviated))
    }
}

private struct TileChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(OttoTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(OttoTheme.surface, in: Capsule())
    }
}

// MARK: - The plan row

private struct PlanRow: View {
    let active: PlanSummary
    let model: PlansModel

    var body: some View {
        HStack(spacing: 12) {
            StepIllustration(
                art: StepArt.art(for: "", domain: active.meta.domain),
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(active.meta.domain.capitalized)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
                Text(active.meta.goal)
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            TileChip(
                text: "Wk \(PlansModel.week(of: active, now: Date()))/"
                    + "\(PlansModel.weekCount(horizonDays: active.meta.horizonDays))"
            )
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OttoTheme.textTertiary)
        }
        .ottoCard(padding: 13)
    }
}

// MARK: - Appear cascade

private struct CascadeIn: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(
                    .spring(duration: 0.45, bounce: 0.22).delay(Double(index) * 0.06)
                ) {
                    shown = true
                }
            }
    }
}

extension View {
    fileprivate func cascadeIn(_ index: Int) -> some View { modifier(CascadeIn(index: index)) }
}

// MARK: - The detail screen (everything dense lives here)

struct PlanDetailView: View {
    let active: PlanSummary
    @Bindable var model: PlansModel
    let onAdaptPlan: () -> Void
    let onStartSession: (Plan) -> Void

    var body: some View {
        ScrollView {
            PlanSectionView(
                active: active,
                model: model,
                onAdaptPlan: onAdaptPlan,
                onStartSession: onStartSession
            )
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(OttoTheme.background)
        .navigationTitle(active.meta.domain.capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One active plan in full: overview → weeks → sessions → history.
/// Selecting a historical version shows it read-only in the same slot.
private struct PlanSectionView: View {
    let active: PlanSummary
    @Bindable var model: PlansModel
    let onAdaptPlan: () -> Void
    let onStartSession: (Plan) -> Void

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
        .ottoCard(padding: 16)
        .padding(.horizontal, 18)
        .task(id: shownId) { await model.loadDetail(id: shownId) }
    }

    // MARK: - Overview: goal, horizon, sessions per week

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(active.meta.goal)
                    .font(.headline)
                    .foregroundStyle(OttoTheme.textPrimary)
                Spacer()
                Text(active.meta.domain.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OttoTheme.textTertiary)
            }
            Text(overviewLine)
                .font(.caption)
                .foregroundStyle(OttoTheme.textSecondary)

            HStack(spacing: 10) {
                if let plan = model.details[active.id],
                   let next = PlanScheduling.nextOccurrence(in: plan, now: Date()) {
                    Button {
                        Haptics.tick()
                        onStartSession(plan)
                    } label: {
                        Label(Self.startLabel(next), systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(OttoTheme.ink, in: Capsule())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.95))
                }
                Button(action: onAdaptPlan) {
                    Label("Adapt", systemImage: "mic.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(OttoTheme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(OttoTheme.control, in: Capsule())
                        .overlay(Capsule().stroke(OttoTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            Text("Adapt by voice — tell Otto what changed: an injury, missed days, a new schedule.")
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
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(OttoTheme.peach, in: Capsule())
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
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.steps) { step in
                            HStack(alignment: .center, spacing: 10) {
                                StepIllustration(
                                    art: StepArt.art(
                                        for: step.title,
                                        cue: step.cue,
                                        domain: plan.meta.domain
                                    ),
                                    size: 34
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(step.title)
                                            .font(.caption.weight(.medium))
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
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        StepIllustration(
                            art: StepArt.art(for: session.title, domain: plan.meta.domain),
                            size: 40
                        )
                        Text(sessionShortTitle(session.title))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(OttoTheme.textPrimary)
                            .lineLimit(1)
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

    /// "Start Lower A" today, "Start Lower A · Thu" for a future one —
    /// always the SHORT session name; the pill must never wrap.
    private static func startLabel(
        _ next: (entry: ScheduledSession, session: Session, date: Date)
    ) -> String {
        let name = sessionShortTitle(next.session.title)
        if Foundation.Calendar.current.isDateInToday(next.date) {
            return "Start \(name)"
        }
        let day = next.date.formatted(.dateTime.weekday(.abbreviated))
        return "Start \(name) · \(day)"
    }

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
        return entries
            .map { sessionShortTitle(titlesById[$0.sessionId] ?? $0.sessionId) }
            .joined(separator: " · ")
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
