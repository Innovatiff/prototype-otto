import ActivityKit
import SwiftUI
import WidgetKit

/// Otto on the outside: the Up Next widget (the daily re-entry point) and
/// the guided-session Live Activity (the session on the Lock Screen).
@main
struct OttoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        OttoSessionLiveActivity()
    }
}

/// The widget's own slice of the design system — the app's theme types
/// aren't in this target, so the few colors live here, matched by value.
private enum WidgetTheme {
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let peach = Color(red: 0.99, green: 0.62, blue: 0.38)
    static let textSecondary = ink.opacity(0.55)
}

// MARK: - Up Next widget

private struct UpNextEntry: TimelineEntry {
    let date: Date
    let upNext: WidgetUpNext?
}

private struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: .now, upNext: WidgetUpNext(title: "Full Body B", minutes: 35, dayLabel: "Today"))
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(UpNextEntry(date: .now, upNext: WidgetUpNext.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        // The app pushes reloads on every refresh; the half-hour fallback
        // just keeps the day label honest across midnight.
        let entry = UpNextEntry(date: .now, upNext: WidgetUpNext.load())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OttoUpNext", provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.976, green: 0.976, blue: 0.968)
                }
        }
        .configurationDisplayName("Up Next")
        .description("Today's session and a one-tap line to Otto.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        if let upNext = entry.upNext {
            content(upNext)
                .widgetURL(URL(string: "otto://start"))
        } else {
            askOtto
                .widgetURL(URL(string: "otto://listen"))
        }
    }

    private func content(_ upNext: WidgetUpNext) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("UP NEXT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WidgetTheme.peach)
                Text(upNext.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetTheme.ink)
                    .lineLimit(2)
                Text("\(upNext.minutes) min · \(upNext.dayLabel)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetTheme.textSecondary)
                Spacer(minLength: 0)
                playRow
            }
            if family == .systemMedium {
                Spacer(minLength: 0)
                Link(destination: URL(string: "otto://listen")!) {
                    micCircle(size: 52, glyph: 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var playRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Start")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(WidgetTheme.ink, in: Capsule())
    }

    private var askOtto: some View {
        VStack(spacing: 8) {
            micCircle(size: 44, glyph: 17)
            Text("Ask Otto")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetTheme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func micCircle(size: CGFloat, glyph: CGFloat) -> some View {
        Image(systemName: "mic.fill")
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(WidgetTheme.ink, in: Circle())
    }
}

// MARK: - Guided session Live Activity

struct OttoSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OttoSessionAttributes.self) { context in
            // The Lock Screen banner.
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(WidgetTheme.peach)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.sessionTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(context.state.stepTitle)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    ProgressView(
                        value: Double(context.state.stepIndex + 1),
                        total: Double(max(1, context.state.totalSteps))
                    )
                    .tint(WidgetTheme.peach)
                }
                Spacer(minLength: 0)
                Text("\(context.state.stepIndex + 1)/\(context.state.totalSteps)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 0.976, green: 0.976, blue: 0.968))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(WidgetTheme.peach)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.stepTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(context.attributes.sessionTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.stepIndex + 1)/\(context.state.totalSteps)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(WidgetTheme.peach)
            } compactTrailing: {
                Text("\(context.state.stepIndex + 1)/\(context.state.totalSteps)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(WidgetTheme.peach)
            }
        }
    }
}
