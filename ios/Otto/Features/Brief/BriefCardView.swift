import SwiftUI

/// The structured half of the morning brief — on screen while the spoken
/// half plays. The voice is the summary; this is the detail.
struct BriefCardView: View {
    let card: BriefCard
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let weather = card.weather {
                        weatherRow(weather)
                    }
                    if !card.conflicts.isEmpty {
                        conflictsSection
                    }
                    if !card.events.isEmpty {
                        eventsSection
                    }
                    if !card.dueTasks.isEmpty {
                        dueSection
                    }
                    if !card.lists.isEmpty {
                        listsSection
                    }
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
            Text("TODAY")
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
            .accessibilityLabel("Dismiss brief")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func weatherRow(_ weather: CurrentWeather) -> some View {
        HStack(spacing: 10) {
            Text("\(Int(weather.temperatureC.rounded()))°")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(OttoTheme.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("feels \(Int(weather.apparentC.rounded()))°")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
                if !weather.advice.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(weather.advice, id: \.self) { tag in
                            Text(tag.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(OttoTheme.sky, in: Capsule())
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var conflictsSection: some View {
        section("NEEDS A DECISION") {
            ForEach(Array(card.conflicts.enumerated()), id: \.offset) { _, conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(conflict.eventA.title)  ×  \(conflict.eventB.title)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(OttoTheme.textPrimary)
                    Text(
                        conflict.kind == .overlap
                            ? "Overlap by \(conflict.minutesShort) min"
                            : "\(conflict.minutesShort) min short for travel"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var eventsSection: some View {
        section("SCHEDULE") {
            ForEach(card.events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(event.isAllDay ? "all day" : event.startsAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OttoTheme.textSecondary)
                        .frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.callout)
                            .foregroundStyle(OttoTheme.textPrimary)
                        if let location = event.location {
                            Text(location)
                                .font(.caption2)
                                .foregroundStyle(OttoTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private var dueSection: some View {
        section("DUE TODAY") {
            ForEach(card.dueTasks, id: \.taskId) { task in
                HStack(spacing: 10) {
                    Text(task.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OttoTheme.textSecondary)
                        .frame(width: 64, alignment: .leading)
                    Text(task.title)
                        .font(.callout)
                        .foregroundStyle(OttoTheme.textPrimary)
                }
            }
        }
    }

    private var listsSection: some View {
        section("OPEN LISTS") {
            ForEach(card.lists, id: \.taskId) { list in
                HStack {
                    Text(list.context ?? list.title)
                        .font(.callout)
                        .foregroundStyle(OttoTheme.textPrimary)
                    Spacer()
                    Text("\(list.openCount) open")
                        .font(.caption)
                        .foregroundStyle(OttoTheme.textSecondary)
                }
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
}
