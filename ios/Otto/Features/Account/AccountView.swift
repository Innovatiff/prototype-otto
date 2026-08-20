import SwiftUI

/// The Account tab: who you are, what Otto holds for you (tasks, memory),
/// and the settings underneath. Light, calm, and one tap from everything.
struct AccountView: View {
    @Bindable var settings: DebugModel
    @Bindable var tasks: TasksModel
    @Bindable var memory: MemoryModel
    var onBriefScheduleChange: ((Bool, Int, Int) -> Void)?
    var onCalendarSyncChange: ((Bool) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                manageSection
                settingsSection
            }
            .scrollContentBackground(.hidden)
            .background(OttoTheme.background)
            .navigationTitle("Account")
            .safeAreaPadding(.bottom, 64)
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [OttoTheme.mint, OttoTheme.sky, OttoTheme.lavender],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "person.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.signedInUserId != nil ? "Welcome back" : "Not signed in")
                        .font(.headline)
                        .foregroundStyle(OttoTheme.textPrimary)
                    Text(
                        settings.signedInUserId != nil
                            ? "Otto is listening for you."
                            : "Sign in under Settings to start."
                    )
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var manageSection: some View {
        Section("Otto holds") {
            NavigationLink {
                TasksView(model: tasks)
                    .background(OttoTheme.background)
                    .navigationTitle("Tasks")
            } label: {
                accountRow(icon: "checklist", color: OttoTheme.mint, title: "Tasks & reminders")
            }
            NavigationLink {
                MemoryView(model: memory)
                    .background(OttoTheme.background)
                    .navigationTitle("Memory")
            } label: {
                accountRow(icon: "brain.head.profile", color: OttoTheme.lavender, title: "Memory")
            }
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                DebugView(
                    model: settings,
                    onBriefScheduleChange: onBriefScheduleChange,
                    onCalendarSyncChange: onCalendarSyncChange
                )
            } label: {
                accountRow(icon: "gearshape.fill", color: OttoTheme.sky, title: "Settings")
            }
        } footer: {
            Text("Server, sign-in, morning brief, calendar sync, and the typed fallback.")
        }
    }

    private func accountRow(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title)
                .foregroundStyle(OttoTheme.textPrimary)
        }
    }
}
