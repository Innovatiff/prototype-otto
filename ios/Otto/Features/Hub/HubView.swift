import SwiftUI

/// The hub — everything Otto manages, one dark page, chip-switched:
/// Tasks and Memory live now; Executions and Plans arrive with their
/// phases. Also carries the fresh-conversation action so the stage can
/// stay chromeless.
struct HubView: View {
    enum Pane: String, CaseIterable {
        case tasks = "Tasks"
        case memory = "Memory"
        case executions = "Executions"
        case plans = "Plans"
    }

    @Bindable var tasks: TasksModel
    @Bindable var memory: MemoryModel

    @State private var pane: Pane = .tasks

    var body: some View {
        VStack(spacing: 0) {
            header
            headline
            chips
            content
        }
        .background(OttoTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// Profile row: avatar, greeting, notification bell.
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(OttoTheme.control)
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(OttoTheme.textSecondary)
            }
            .frame(width: 46, height: 46)
            .overlay(Circle().stroke(OttoTheme.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back,")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
                Text("Boss")
                    .font(.headline)
                    .foregroundStyle(OttoTheme.textPrimary)
            }

            Spacer()

            // The bell: reminders live in Tasks.
            Button {
                withAnimation(.snappy(duration: 0.15)) { pane = .tasks }
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .frame(width: 46, height: 46)
                    .background(
                        OttoTheme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(OttoTheme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reminders")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    private var headline: some View {
        Text("Your world, handled.")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(OttoTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Pane.allCases, id: \.self) { candidate in
                    Button {
                        withAnimation(.snappy(duration: 0.15)) { pane = candidate }
                    } label: {
                        Text(candidate.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(pane == candidate ? Color.black : OttoTheme.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                pane == candidate ? Color.white : OttoTheme.surface,
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(OttoTheme.hairline, lineWidth: 1))
                            .shadow(
                                color: .black.opacity(pane == candidate ? 0.45 : 0),
                                radius: 7,
                                y: 3
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .tasks:
            TasksView(model: tasks)
        case .memory:
            MemoryView(model: memory)
        case .executions:
            comingSoon(
                icon: "play.rectangle.on.rectangle",
                title: "Executions",
                caption: "Runs Otto performs on his own land here — arriving with a later phase."
            )
        case .plans:
            comingSoon(
                icon: "calendar.badge.clock",
                title: "Plans",
                caption: "Multi-week plans and their sessions land here — arriving with the planning phase."
            )
        }
    }

    private func comingSoon(icon: String, title: String, caption: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(OttoTheme.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(OttoTheme.textPrimary)
            Text(caption)
                .font(.callout)
                .foregroundStyle(OttoTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
