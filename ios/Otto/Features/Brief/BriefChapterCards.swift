import SwiftUI

/// The synced tour's visuals: while Otto speaks each chapter of the brief,
/// the matching card is on stage — weather while the weather is spoken, the
/// day's events while the calendar is spoken, reminders while they are.
/// Empty chapters show their emptiness proudly; the words say the same.
extension BriefChapterKind {
    /// Intro and outro are orb-only — no card slides in for them.
    var hasVisual: Bool {
        switch self {
        case .weather, .calendar, .reminders: return true
        case .intro, .outro: return false
        }
    }
}

struct BriefChapterCardView: View {
    let chapter: BriefChapter
    let card: BriefCard

    var body: some View {
        Group {
            switch chapter.kind {
            case .weather:
                WeatherChapterCard(weather: card.weather)
            case .calendar:
                CalendarChapterCard(events: card.events, conflicts: card.conflicts)
            case .reminders:
                RemindersChapterCard(dueTasks: card.dueTasks, lists: card.lists)
            case .intro, .outro:
                EmptyView()
            }
        }
    }
}

// MARK: - Weather

private struct WeatherChapterCard: View {
    let weather: CurrentWeather?

    /// The advice decides the face of the card — rain beats cold beats wind.
    private var art: (symbol: String, tint: Color) {
        guard let weather else { return ("cloud", OttoTheme.sky) }
        if weather.advice.contains(.rain) { return ("cloud.rain.fill", OttoTheme.sky) }
        if weather.advice.contains(.cold) { return ("snowflake", OttoTheme.lavender) }
        if weather.advice.contains(.wind) { return ("wind", OttoTheme.mint) }
        return ("sun.max.fill", OttoTheme.lemon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChapterLabel(text: "WEATHER", tint: art.tint)
            if let weather {
                HStack(spacing: 16) {
                    IconTile(symbol: art.symbol, tint: art.tint, side: 64, glyph: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(weather.temperatureC.rounded()))°")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(OttoTheme.textPrimary)
                        Text("Feels like \(Int(weather.apparentC.rounded()))°")
                            .font(.subheadline)
                            .foregroundStyle(OttoTheme.textSecondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    if weather.precipitationProbability > 0 {
                        ChapterChip(
                            symbol: "drop.fill",
                            text: "\(weather.precipitationProbability)% rain",
                            tint: OttoTheme.sky
                        )
                    }
                    ChapterChip(
                        symbol: "wind",
                        text: "\(Int(weather.windKmh.rounded())) km/h",
                        tint: OttoTheme.mint
                    )
                }
            } else {
                ChapterEmptyState(
                    symbol: "cloud",
                    tint: OttoTheme.sky,
                    title: "No weather right now",
                    detail: "Couldn't reach the forecast."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
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
                    title: "Nothing on the calendar",
                    detail: "The day is yours."
                )
            } else {
                if let conflict = conflicts.first {
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
                        OttoTheme.peach.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(events.prefix(5)) { event in
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
                    }
                    if events.count > 5 {
                        Text("+ \(events.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
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
                    title: "Nothing due today",
                    detail: "All clear."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(dueTasks.prefix(4), id: \.taskId) { task in
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
                    }
                    ForEach(lists.prefix(3), id: \.taskId) { list in
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
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
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

/// An empty chapter states its emptiness kindly, matching the spoken line.
private struct ChapterEmptyState: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, side: 56, glyph: 24)
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(OttoTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}
