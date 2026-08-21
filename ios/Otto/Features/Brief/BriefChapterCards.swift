import SwiftUI

/// The synced tour's visuals: while Otto speaks each chapter of the brief,
/// the matching illustration is on stage — no transcript, no captions, just
/// the thing he's talking about, alive. Weather floats and counts up,
/// calendar rows cascade in, the plan's illustration sways, reminders ring
/// in one by one. Intro and outro are orb-only: Otto talking IS the visual.
extension BriefChapterKind {
    /// Chapters that put an illustration on stage. Intro and outro leave
    /// the slot empty and the orb big.
    var hasVisual: Bool {
        switch self {
        case .weather, .calendar, .plans, .reminders: return true
        case .intro, .outro: return false
        }
    }
}

struct BriefChapterCardView: View {
    let chapter: BriefChapter
    let card: BriefCard
    var onStartPlan: (() -> Void)? = nil

    var body: some View {
        switch chapter.kind {
        case .weather:
            WeatherChapterView(weather: card.weather)
        case .calendar:
            CalendarChapterCard(events: card.events, conflicts: card.conflicts)
        case .plans:
            PlansChapterCard(sessions: card.planSessions ?? [], onStart: onStartPlan)
        case .reminders:
            RemindersChapterCard(dueTasks: card.dueTasks, lists: card.lists)
        case .intro, .outro:
            EmptyView()
        }
    }
}

// MARK: - Conversational stage ("speaks and shows")

/// The illustration for whatever Otto is answering right now — the same
/// living visuals the brief tour uses, plus the build-in-progress and
/// armed-automation moments. Calendar renders from the device's own
/// events; everything else arrives in the visual's payload.
struct StageVisualView: View {
    let visual: StageVisual
    var todaysEvents: [CalendarEvent] = []
    var todaysConflicts: [Conflict] = []
    var onStartPlan: (() -> Void)? = nil

    var body: some View {
        switch visual.kind {
        case .weather:
            WeatherChapterView(weather: visual.weather)
        case .calendar:
            CalendarChapterCard(events: todaysEvents, conflicts: todaysConflicts)
        case .reminders:
            RemindersChapterCard(dueTasks: visual.dueTasks ?? [], lists: visual.lists ?? [])
        case .plans:
            PlansChapterCard(sessions: visual.planSessions ?? [], onStart: onStartPlan)
        case .building:
            BuildingView(label: visual.label)
        case .automation:
            AutomationArmedView(label: visual.label ?? "Automation", detail: visual.detail)
        }
    }
}

/// Work in progress, stated calmly: a low card with just the label and a
/// light running its border. Professional, and never a spinner.
struct BuildingView: View {
    var label: String?

    var body: some View {
        Text(label ?? "Working on it")
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(OttoTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .ottoCard()
            .overlay(BorderRunner(cornerRadius: OttoTheme.cardRadius))
    }
}

/// A short bright segment traveling the card's border on a fixed clock —
/// TimelineView-driven so the wrap around the corner never stutters.
private struct BorderRunner: View {
    var cornerRadius: CGFloat
    var tint: Color = OttoTheme.rose

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((time / 2.8).truncatingRemainder(dividingBy: 1.0))
            let length: CGFloat = 0.28
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape
                    .trim(from: phase, to: min(phase + length, 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if phase + length > 1 {
                    shape
                        .trim(from: 0, to: phase + length - 1)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
            .shadow(color: tint.opacity(0.45), radius: 4)
        }
        .allowsHitTesting(false)
    }
}

/// A freshly created automation snapping into place: the bolt springs in,
/// the name and schedule under it, an Armed chip to seal it.
struct AutomationArmedView: View {
    let label: String
    var detail: String?
    @State private var armed = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(OttoTheme.lemon.opacity(0.16))
                    .frame(width: 84, height: 84)
                    .scaleEffect(armed ? 1 : 0.4)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(OttoTheme.lemon)
                    .scaleEffect(armed ? 1 : 0.2)
                    .rotationEffect(.degrees(armed ? 0 : -25))
            }
            Text(label)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(OttoTheme.textSecondary)
            }
            ChapterChip(symbol: "checkmark", text: "Armed", tint: OttoTheme.mint)
                .staggerIn(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .ottoCard()
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.45)) { armed = true }
        }
    }
}

// MARK: - Weather

/// Chrome-less: a living condition icon (the sun turns, everything else
/// drifts), the temperature counting up, detail chips cascading in.
private struct WeatherChapterView: View {
    let weather: CurrentWeather?

    /// The advice decides the face — rain beats cold beats wind.
    private var art: (symbol: String, tint: Color) {
        guard let weather else { return ("cloud", OttoTheme.sky) }
        if weather.advice.contains(.rain) { return ("cloud.rain.fill", OttoTheme.sky) }
        if weather.advice.contains(.cold) { return ("snowflake", OttoTheme.lavender) }
        if weather.advice.contains(.wind) { return ("wind", OttoTheme.mint) }
        return ("sun.max.fill", OttoTheme.lemon)
    }

    var body: some View {
        VStack(spacing: 18) {
            if let weather {
                HStack(spacing: 20) {
                    weatherIcon
                    VStack(alignment: .leading, spacing: 0) {
                        CountUpDegrees(value: Int(weather.temperatureC.rounded()))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(OttoTheme.textPrimary)
                        Text("Feels like \(Int(weather.apparentC.rounded()))°")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(OttoTheme.textSecondary)
                    }
                }
                HStack(spacing: 8) {
                    if weather.precipitationProbability > 0 {
                        ChapterChip(
                            symbol: "drop.fill",
                            text: "\(weather.precipitationProbability)% rain",
                            tint: OttoTheme.sky
                        )
                        .staggerIn(0)
                    }
                    ChapterChip(
                        symbol: "wind",
                        text: "\(Int(weather.windKmh.rounded())) km/h",
                        tint: OttoTheme.mint
                    )
                    .staggerIn(1)
                }
            } else {
                ChapterEmptyState(symbol: "cloud", tint: OttoTheme.sky, title: "No weather right now")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The sun rotates forever; every other condition drifts gently.
    @ViewBuilder
    private var weatherIcon: some View {
        let tile = IconTile(symbol: art.symbol, tint: art.tint, side: 84, glyph: 38)
        if art.symbol == "sun.max.fill" {
            tile.spinSlow()
        } else {
            tile.floaty()
        }
    }
}

// MARK: - Calendar

private struct CalendarChapterCard: View {
    let events: [CalendarEvent]
    let conflicts: [Conflict]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChapterLabel(text: "TODAY", tint: OttoTheme.sky)
            if events.isEmpty {
                ChapterEmptyState(
                    symbol: "calendar",
                    tint: OttoTheme.mint,
                    title: "Nothing on the calendar"
                )
            } else {
                if let conflict = conflicts.first {
                    ConflictBanner(conflict: conflict)
                        .staggerIn(0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(events.prefix(5).enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(
                                event.isAllDay
                                    ? "all day"
                                    : event.startsAt.formatted(date: .omitted, time: .shortened)
                            )
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(OttoTheme.sky)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(OttoTheme.sky.opacity(0.14), in: Capsule())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(OttoTheme.textPrimary)
                                    .lineLimit(1)
                                if let location = event.location {
                                    Text(location)
                                        .font(.caption2)
                                        .foregroundStyle(OttoTheme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .staggerIn(index + 1)
                    }
                    if events.count > 5 {
                        Text("+ \(events.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(OttoTheme.textTertiary)
                            .staggerIn(6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }
}

/// The clash, breathing gently so it reads as live, not decorative.
private struct ConflictBanner: View {
    let conflict: Conflict
    @State private var glow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(conflict.eventA.title)  ×  \(conflict.eventB.title)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(OttoTheme.textPrimary)
            Text(
                conflict.kind == .overlap
                    ? "Overlap by \(conflict.minutesShort) min"
                    : "\(conflict.minutesShort) min short for travel"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(OttoTheme.peach)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            OttoTheme.peach.opacity(glow ? 0.18 : 0.10),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

// MARK: - Plans

/// Today's plan sessions: the domain illustration sways while he talks,
/// done sessions wear a checkmark, and the next one is a tap away.
private struct PlansChapterCard: View {
    let sessions: [BriefPlanSession]
    var onStart: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChapterLabel(text: "ON THE PLAN", tint: OttoTheme.rose)
            if sessions.isEmpty {
                ChapterEmptyState(
                    symbol: "moon.zzz.fill",
                    tint: OttoTheme.lavender,
                    title: "Rest day"
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    // Offset-keyed: the same template can legally appear
                    // twice in one day, so sessionId is not unique here.
                    ForEach(Array(sessions.prefix(2).enumerated()), id: \.offset) {
                        index, session in
                        HStack(spacing: 14) {
                            StepIllustration(
                                art: StepArt.art(for: session.sessionTitle, domain: session.domain),
                                size: 60
                            )
                            .sway()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.sessionTitle)
                                    .font(.system(size: 21, weight: .bold, design: .rounded))
                                    .foregroundStyle(OttoTheme.textPrimary)
                                    .lineLimit(1)
                                Text(sessionSubtitle(session))
                                    .font(.subheadline)
                                    .foregroundStyle(OttoTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            if session.completed {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(OttoTheme.mint)
                            }
                        }
                        .staggerIn(index)
                    }
                    if sessions.count > 2 {
                        Text("+ \(sessions.count - 2) more")
                            .font(.caption2)
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                }
                if sessions.contains(where: { !$0.completed }), let onStart {
                    InkPillButton(title: "Start session") {
                        onStart()
                    }
                    .staggerIn(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    private func sessionSubtitle(_ session: BriefPlanSession) -> String {
        var parts = ["Week \(session.week)"]
        if let time = session.timeOfDay {
            parts.append(time)
        }
        if session.completed {
            parts.append("done")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reminders

private struct RemindersChapterCard: View {
    let dueTasks: [BriefDueTask]
    let lists: [BriefListCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChapterLabel(text: "REMINDERS", tint: OttoTheme.lavender)
            if dueTasks.isEmpty && lists.isEmpty {
                ChapterEmptyState(
                    symbol: "checkmark.seal.fill",
                    tint: OttoTheme.mint,
                    title: "Nothing due today"
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(dueTasks.prefix(4).enumerated()), id: \.element.taskId) {
                        index, task in
                        HStack(spacing: 12) {
                            IconTile(symbol: "bell.fill", tint: OttoTheme.lavender)
                            Text(task.title)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(OttoTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(task.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OttoTheme.textSecondary)
                        }
                        .staggerIn(index)
                    }
                    ForEach(Array(lists.prefix(3).enumerated()), id: \.element.taskId) {
                        index, list in
                        HStack(spacing: 12) {
                            IconTile(symbol: "checklist", tint: OttoTheme.rose)
                            Text(list.context ?? list.title)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(OttoTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(list.openCount) open")
                                .font(.caption)
                                .foregroundStyle(OttoTheme.textSecondary)
                        }
                        .staggerIn(dueTasks.prefix(4).count + index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }
}

// MARK: - Motion modifiers

/// Rows cascade in: a small rise + fade, each a beat after the last.
private struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(
                    .spring(duration: 0.5, bounce: 0.25).delay(0.12 + Double(index) * 0.07)
                ) {
                    shown = true
                }
            }
    }
}

/// Gentle vertical drift, forever — ambient life for a hero icon.
private struct Floaty: ViewModifier {
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .offset(y: up ? -4 : 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}

/// A slow rock back and forth — the plan illustration warming up.
private struct Sway: ViewModifier {
    @State private var tilted = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(tilted ? 3 : -3))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    tilted = true
                }
            }
    }
}

/// A full continuous turn — the sun doing sun things, gears doing gear
/// things (reversed for the meshed partner).
private struct SpinSlow: ViewModifier {
    var duration: Double = 22
    var reverse = false
    @State private var turned = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(turned ? (reverse ? -360 : 360) : 0))
            .onAppear {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    turned = true
                }
            }
    }
}

extension View {
    fileprivate func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }
    fileprivate func floaty() -> some View { modifier(Floaty()) }
    fileprivate func sway() -> some View { modifier(Sway()) }
    fileprivate func spinSlow(duration: Double = 22, reverse: Bool = false) -> some View {
        modifier(SpinSlow(duration: duration, reverse: reverse))
    }
}

/// The temperature rolling up from zero on arrival.
private struct CountUpDegrees: View {
    let value: Int
    @State private var shown = 0

    var body: some View {
        Text("\(shown)°")
            .contentTransition(.numericText(value: Double(shown)))
            .monospacedDigit()
            .task {
                try? await Task.sleep(for: .seconds(0.25))
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 0.9)) { shown = value }
            }
    }
}

// MARK: - Shared pieces

private struct ChapterLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 34
    var glyph: CGFloat = 15

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(
                tint.opacity(0.15),
                in: RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
            )
    }
}

private struct ChapterChip: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// An empty chapter states its emptiness with a scaled-in tile.
private struct ChapterEmptyState: View {
    let symbol: String
    let tint: Color
    let title: String
    @State private var shown = false

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, side: 56, glyph: 24)
                .scaleEffect(shown ? 1 : 0.6)
                .opacity(shown ? 1 : 0)
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.45).delay(0.15)) {
                shown = true
            }
        }
    }
}
