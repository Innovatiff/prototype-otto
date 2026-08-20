import SwiftUI

/// The synced tour's visuals: every topic Otto speaks has a matching visual
/// on stage — animated type for the intro and outro, a chrome-less weather
/// composition, cards for the calendar, today's plan sessions, and
/// reminders. Each visual is ALIVE while he talks: the spoken words sweep
/// through in a karaoke highlight, rows cascade in, icons float and sway,
/// the temperature counts up. Empty chapters show their emptiness kindly;
/// the words say the same.
extension BriefChapterKind {
    /// Hero chapters are pure animated type — the orb keeps the stage.
    var isHero: Bool { self == .intro || self == .outro }
}

struct BriefChapterCardView: View {
    let chapter: BriefChapter
    let card: BriefCard
    var onStartPlan: (() -> Void)? = nil

    var body: some View {
        switch chapter.kind {
        case .intro:
            HeroChapterView(text: chapter.spoken, tint: OttoTheme.sky)
        case .outro:
            HeroChapterView(text: chapter.spoken, tint: OttoTheme.lavender)
        case .weather:
            WeatherChapterView(weather: card.weather, spoken: chapter.spoken)
        case .calendar:
            CalendarChapterCard(
                events: card.events,
                conflicts: card.conflicts,
                spoken: chapter.spoken
            )
        case .plans:
            PlansChapterCard(
                sessions: card.planSessions ?? [],
                spoken: chapter.spoken,
                onStart: onStartPlan
            )
        case .reminders:
            RemindersChapterCard(
                dueTasks: card.dueTasks,
                lists: card.lists,
                spoken: chapter.spoken
            )
        }
    }
}

// MARK: - Hero (intro / outro)

/// Not a card at all: the spoken line as big centered type, words lighting
/// up as they're said.
private struct HeroChapterView: View {
    let text: String
    let tint: Color

    var body: some View {
        KaraokeText(
            text: text,
            tint: tint,
            font: .system(size: 25, weight: .semibold, design: .rounded),
            baseColor: OttoTheme.textPrimary,
            centered: true
        )
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Weather

/// Chrome-less: a floating condition icon, the temperature counting up,
/// detail chips cascading in, and the advice line sweeping word by word.
private struct WeatherChapterView: View {
    let weather: CurrentWeather?
    let spoken: String

    /// The advice decides the face — rain beats cold beats wind.
    private var art: (symbol: String, tint: Color) {
        guard let weather else { return ("cloud", OttoTheme.sky) }
        if weather.advice.contains(.rain) { return ("cloud.rain.fill", OttoTheme.sky) }
        if weather.advice.contains(.cold) { return ("snowflake", OttoTheme.lavender) }
        if weather.advice.contains(.wind) { return ("wind", OttoTheme.mint) }
        return ("sun.max.fill", OttoTheme.lemon)
    }

    var body: some View {
        VStack(spacing: 14) {
            if let weather {
                HStack(spacing: 18) {
                    IconTile(symbol: art.symbol, tint: art.tint, side: 76, glyph: 34)
                        .floaty()
                    VStack(alignment: .leading, spacing: 0) {
                        CountUpDegrees(value: Int(weather.temperatureC.rounded()))
                            .font(.system(size: 58, weight: .bold, design: .rounded))
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
                IconTile(symbol: "cloud", tint: OttoTheme.sky, side: 64, glyph: 28)
                    .floaty()
            }
            KaraokeText(
                text: spoken,
                tint: art.tint,
                font: .system(size: 16, weight: .medium, design: .rounded),
                baseColor: OttoTheme.textSecondary,
                centered: true
            )
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Calendar

private struct CalendarChapterCard: View {
    let events: [CalendarEvent]
    let conflicts: [Conflict]
    let spoken: String

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
                    ForEach(Array(events.prefix(4).enumerated()), id: \.element.id) { index, event in
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
                    if events.count > 4 {
                        Text("+ \(events.count - 4) more")
                            .font(.caption2)
                            .foregroundStyle(OttoTheme.textTertiary)
                            .staggerIn(5)
                    }
                }
            }
            SpokenFooter(text: spoken, tint: OttoTheme.sky)
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
    let spoken: String
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
                                size: 56
                            )
                            .sway()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.sessionTitle)
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
                                    .transition(.scale.combined(with: .opacity))
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
            SpokenFooter(text: spoken, tint: OttoTheme.rose)
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
    let spoken: String

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
            SpokenFooter(text: spoken, tint: OttoTheme.lavender)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }
}

// MARK: - Karaoke text

/// The spoken words on screen, lighting up in a steady sweep that tracks
/// the voice: said words in full color, the word being said tinted and
/// popped a touch larger, unsaid words faint. The sweep is estimated from
/// speech cadence — no TTS timings exist — and lands close enough to feel
/// synced.
struct KaraokeText: View {
    let text: String
    var tint: Color = OttoTheme.sky
    var font: Font = .system(size: 16, weight: .medium, design: .rounded)
    var baseColor: Color = OttoTheme.textPrimary
    var centered = false
    /// Roughly conversational TTS pace (~170 words per minute).
    var wordInterval: Double = 0.36

    @State private var revealed = 0

    private var words: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 6, centered: centered) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(font)
                    .foregroundStyle(index == revealed - 1 ? tint : baseColor)
                    .opacity(index < revealed ? 1 : 0.22)
                    .scaleEffect(
                        index == revealed - 1 ? 1.12 : (index < revealed ? 1.0 : 0.96)
                    )
                    .animation(.spring(duration: 0.3, bounce: 0.35), value: revealed)
            }
        }
        .task {
            for index in words.indices {
                try? await Task.sleep(for: .seconds(index == 0 ? 0.2 : wordInterval))
                if Task.isCancelled { return }
                revealed = index + 1
            }
        }
    }
}

/// The chapter's sentence at the foot of a card, sweeping as it's said.
private struct SpokenFooter: View {
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(OttoTheme.hairline)
                .frame(height: 1)
            KaraokeText(
                text: text,
                tint: tint,
                font: .system(size: 15, weight: .medium, design: .rounded),
                baseColor: OttoTheme.textSecondary
            )
        }
    }
}

/// Leading-or-centered wrapping rows of word views — Text concatenation
/// can't scale a single word, so each word is its own view.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 6
    var centered = false

    private struct Arrangement {
        var frames: [CGRect] = []
        var rowOf: [Int] = []
        var rowWidths: [CGFloat] = []
        var size: CGSize = .zero
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        var result = Arrangement()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var row = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                result.rowWidths.append(x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
                row += 1
            }
            result.frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            result.rowOf.append(row)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        result.rowWidths.append(max(0, x - spacing))
        let contentWidth = result.rowWidths.max() ?? 0
        result.size = CGSize(
            width: maxWidth.isFinite ? min(contentWidth, maxWidth) : contentWidth,
            height: y + rowHeight
        )
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            let shift =
                centered
                ? (arrangement.size.width - arrangement.rowWidths[arrangement.rowOf[index]]) / 2
                : 0
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX + shift, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
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

extension View {
    fileprivate func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }
    fileprivate func floaty() -> some View { modifier(Floaty()) }
    fileprivate func sway() -> some View { modifier(Sway()) }
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

/// An empty chapter states its emptiness with a scaled-in tile; the
/// karaoke footer speaks the kind line.
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
