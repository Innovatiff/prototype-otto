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
    /// White on tinted tiles; control-grey on white cards.
    var fill: Color = OttoTheme.surface

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(OttoTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
    }
}

/// The hero glyph drifts gently — still under Reduce Motion.
private struct PlanFloaty: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .offset(y: up ? -4 : 4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
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
                    + "\(PlansModel.weekCount(horizonDays: active.meta.horizonDays))",
                fill: OttoTheme.control
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
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(OttoTheme.background)
        .navigationTitle(active.meta.domain.capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One active plan in full — illustrated, not narrated: a gradient hero
/// with the goal and a filling progress bar, the weeks as rows of session
/// glyphs, the sessions as tiles that open into their steps. Selecting a
/// historical version shows it read-only in the same slot.
private struct PlanSectionView: View {
    let active: PlanSummary
    @Bindable var model: PlansModel
    let onAdaptPlan: () -> Void
    let onStartSession: (Plan) -> Void

    /// nil = the current (active) version.
    @State private var selectedVersionId: String?
    @State private var progressShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shownId: String { selectedVersionId ?? active.id }
    private var shownPlan: Plan? { model.details[shownId] }
    private var chain: [PlanSummary] { model.chain(for: active) }

    private var tint: Color {
        StepArt.color(for: StepArt.art(for: "", domain: active.meta.domain))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
                .cascadeIn(0)
            actionsCard
                .cascadeIn(1)
            if selectedVersionId != nil {
                supersededBanner
                    .ottoCard(padding: 12)
            }
            if let plan = shownPlan {
                weeksCard(plan)
                    .cascadeIn(2)
                sessionsCard(plan)
                    .cascadeIn(3)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textTertiary)
            }
            if chain.count > 1 {
                historyCard
                    .cascadeIn(4)
            }
        }
        .task(id: shownId) { await model.loadDetail(id: shownId) }
    }

    // MARK: - Hero: the scene, the goal, the progress

    private var hero: some View {
        let art = StepArt.art(for: "", domain: active.meta.domain)
        let weeks = PlansModel.weekCount(horizonDays: active.meta.horizonDays)
        let week = min(max(1, PlansModel.week(of: active, now: Date())), weeks)
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 180)
            Image(systemName: art.symbol)
                .font(.system(size: 62, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .modifier(PlanFloaty())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 18)
                .padding(.trailing, 20)
            VStack(alignment: .leading, spacing: 10) {
                Text(active.meta.goal)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    heroChip("\(weeks) wks")
                    if let plan = model.details[active.id] {
                        let perWeek = Self.typicalPerWeek(plan)
                        if perWeek > 0 { heroChip("\(perWeek)×/wk") }
                    }
                    heroChip("v\(active.meta.version)")
                }
                // The plan's clock, filling instead of talking.
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule()
                                .fill(.white)
                                .frame(
                                    width: progressShown
                                        ? proxy.size.width * CGFloat(week) / CGFloat(max(1, weeks))
                                        : 0
                                )
                        }
                    }
                    .frame(height: 7)
                    Text("Week \(week) of \(weeks)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(16)
        }
        .onAppear {
            if reduceMotion {
                progressShown = true
                return
            }
            withAnimation(.spring(duration: 0.9, bounce: 0.1).delay(0.25)) {
                progressShown = true
            }
        }
    }

    private func heroChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(0.22), in: Capsule())
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Spacer(minLength: 0)
            }
            Text("Adapt by voice — tell Otto what changed: an injury, missed days, a new schedule.")
                .font(.caption2)
                .foregroundStyle(OttoTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard(padding: 14)
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

    // MARK: - Week by week: glyphs, not sentences

    private func weeksCard(_ plan: Plan) -> some View {
        let titlesById = Dictionary(
            plan.sessions.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentWeek = PlansModel.week(of: active, now: Date()) - 1
        return section("WEEK BY WEEK") {
            ForEach(0..<PlansModel.weekCount(horizonDays: plan.meta.horizonDays), id: \.self) { week in
                let entries = plan.schedule
                    .filter { $0.dayOffset / 7 == week }
                    .sorted { $0.dayOffset < $1.dayOffset }
                HStack(spacing: 10) {
                    Text("W\(week + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(week == currentWeek ? tint : OttoTheme.textSecondary)
                        .frame(width: 30, alignment: .leading)
                    if entries.isEmpty {
                        Text("rest")
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textTertiary)
                    } else {
                        // A glyph per session — the week readable at a glance.
                        HStack(spacing: 6) {
                            ForEach(Array(entries.prefix(6).enumerated()), id: \.offset) { _, entry in
                                StepIllustration(
                                    art: StepArt.art(
                                        for: titlesById[entry.sessionId] ?? "",
                                        domain: plan.meta.domain
                                    ),
                                    size: 26
                                )
                            }
                            if entries.count > 6 {
                                Text("+\(entries.count - 6)")
                                    .font(.caption2)
                                    .foregroundStyle(OttoTheme.textTertiary)
                            }
                        }
                    }
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
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    week == currentWeek ? tint.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        }
    }

    // MARK: - Sessions (tap to see steps)

    private func sessionsCard(_ plan: Plan) -> some View {
        section("SESSIONS — tap for steps") {
            ForEach(plan.sessions) { session in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(session.steps.enumerated()), id: \.element.id) { index, step in
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
                            .cascadeIn(index)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        StepIllustration(
                            art: StepArt.art(for: session.title, domain: plan.meta.domain),
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sessionShortTitle(session.title))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(OttoTheme.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                TileChip(text: "\(session.estimatedMinutes) min", fill: OttoTheme.control)
                                TileChip(text: "\(session.steps.count) steps", fill: OttoTheme.control)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .tint(OttoTheme.textSecondary)
            }
        }
    }

    // MARK: - Version history

    private var historyCard: some View {
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

    /// Every section is its own quiet card now — no more one long wall.
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OttoTheme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard(padding: 14)
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
