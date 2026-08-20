import SwiftUI

/// The automations management screen: built-ins with toggles and time
/// controls, custom automations with swipe-to-delete, quiet hours. Every
/// row shows the schedule and how the last run ended — "suppressed" is a
/// success state and reads that way.
struct AutomationsView: View {
    @Bindable var model: AutomationsModel

    var body: some View {
        List {
            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            builtInSection
            customSection
            quietSection
        }
        .navigationTitle("Automations")
        .task {
            await model.load()
        }
        .refreshable {
            await model.load()
        }
        .overlay {
            if model.isLoading && model.automations.isEmpty {
                ProgressView()
            }
        }
    }

    private var builtInSection: some View {
        Section {
            ForEach(model.builtIns) { automation in
                AutomationRow(model: model, automation: automation)
            }
        } header: {
            Text("Built in")
        } footer: {
            Text(
                "Otto only speaks when there's something worth saying — a run "
                    + "marked \u{201C}suppressed\u{201D} checked and correctly stayed quiet."
            )
        }
    }

    @ViewBuilder
    private var customSection: some View {
        if !model.customs.isEmpty {
            Section {
                ForEach(model.customs) { automation in
                    AutomationRow(model: model, automation: automation)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Haptics.caution()
                                Task { await model.delete(automation) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("Custom")
            } footer: {
                Text("Created by voice — \u{201C}every Friday afternoon, check my calendar…\u{201D}")
            }
        }
    }

    private var quietSection: some View {
        Section {
            QuietHoursRow(model: model)
        } header: {
            Text("Quiet hours")
        } footer: {
            Text(
                "No pushes inside this window, except automations you "
                    + "deliberately scheduled inside it."
            )
        }
    }
}

/// One automation: name, schedule, last-run line, enable toggle — and for
/// fixed schedules, an inline time control (the brief's shows wake time).
private struct AutomationRow: View {
    let model: AutomationsModel
    let automation: Automation

    /// Each automation type wears its own color and glyph.
    private var typeArt: (symbol: String, color: Color) {
        switch automation.type {
        case .morningBrief: return ("sun.max.fill", OttoTheme.lemon)
        case .eveningShutdown: return ("moon.stars.fill", OttoTheme.lavender)
        case .meetingPrep: return ("person.2.fill", OttoTheme.sky)
        case .planCheckin: return ("chart.bar.fill", OttoTheme.mint)
        case .weeklyReview: return ("clock.arrow.circlepath", OttoTheme.peach)
        case .custom: return ("sparkles", OttoTheme.rose)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 12) {
                    Image(systemName: typeArt.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(typeArt.color)
                        .frame(width: 38, height: 38)
                        .background(
                            typeArt.color.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                        Text(AutomationScheduleText.describe(automation.schedule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            AutomationScheduleText.lastRunLine(
                                lastRunAt: automation.lastRunAt,
                                lastResult: automation.lastResult
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            if automation.enabled, case .fixed(_, let timeOfDay) = automation.schedule {
                DatePicker(
                    timeLabel,
                    selection: timeBinding(stored: timeOfDay),
                    displayedComponents: .hourAndMinute
                )
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String { automation.label }

    private var timeLabel: String {
        switch automation.type {
        case .morningBrief:
            return "Wake time"
        case .eveningShutdown:
            return "Workday ends"
        default:
            return "Time"
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { automation.enabled },
            set: { enabled in
                Haptics.tap()
                Task { await model.setEnabled(automation, enabled: enabled) }
            }
        )
    }

    /// The picker shows wake time for the brief (stored time + lead) and
    /// the stored time for everything else; writes go through the model,
    /// which reverses the mapping.
    private func timeBinding(stored: String) -> Binding<Date> {
        let display =
            automation.type == .morningBrief
            ? AutomationScheduleText.wakeDisplay(fromStored: stored)
            : stored
        return Binding(
            get: { AutomationScheduleText.pickerDate(from: display) },
            set: { picked in
                Task { await model.setTime(automation, picked: picked) }
            }
        )
    }
}

private struct QuietHoursRow: View {
    let model: AutomationsModel
    @State private var start = Date()
    @State private var end = Date()
    @State private var seeded = false

    var body: some View {
        Group {
            DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
            DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            start = AutomationScheduleText.pickerDate(from: model.quietHoursStart)
            end = AutomationScheduleText.pickerDate(from: model.quietHoursEnd)
        }
        .onChange(of: model.quietHoursStart) { _, value in
            start = AutomationScheduleText.pickerDate(from: value)
        }
        .onChange(of: model.quietHoursEnd) { _, value in
            end = AutomationScheduleText.pickerDate(from: value)
        }
        .onChange(of: start) { _, _ in
            push()
        }
        .onChange(of: end) { _, _ in
            push()
        }
    }

    private func push() {
        guard seeded else { return }
        Task { await model.setQuietHours(start: start, end: end) }
    }
}
