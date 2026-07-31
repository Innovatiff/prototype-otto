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
    let onNewConversation: () -> Void

    @State private var pane: Pane = .tasks
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            chips
            content
        }
        .background(OttoTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Otto's desk")
                .font(.title3.weight(.semibold))
                .foregroundStyle(OttoTheme.textPrimary)
            Spacer()
            Button {
                onNewConversation()
                dismiss()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(OttoTheme.control, in: Capsule())
                    .overlay(Capsule().stroke(OttoTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Pane.allCases, id: \.self) { candidate in
                    Button {
                        withAnimation(.snappy(duration: 0.15)) { pane = candidate }
                    } label: {
                        Text(candidate.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(pane == candidate ? Color.black : OttoTheme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                pane == candidate ? Color.white : OttoTheme.surface,
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(OttoTheme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
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
