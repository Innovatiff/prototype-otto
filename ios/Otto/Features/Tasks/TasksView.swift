import SwiftUI

/// Lists grouped by context, reminders sorted by fire time, tappable
/// checkboxes, swipe to delete. Stays live while Otto works — items added
/// by voice animate in.
struct TasksView: View {
    @Bindable var model: TasksModel

    var body: some View {
        NavigationStack {
            Group {
                if model.tasks.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    taskList
                }
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .refreshable { await model.load() }
        }
    }

    private var taskList: some View {
        List {
            if !model.reminders.isEmpty {
                Section("Reminders") {
                    ForEach(model.reminders) { task in
                        reminderRow(task)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                deleteButton(task)
                            }
                    }
                }
            }
            ForEach(model.contextGroups, id: \.context) { group in
                Section(group.context ?? "Untagged") {
                    ForEach(group.tasks) { task in
                        taskCell(task)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                deleteButton(task)
                            }
                    }
                }
            }
            if let errorText = model.errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func deleteButton(_ task: OttoTask) -> some View {
        Button("Delete", role: .destructive) {
            Task { await model.delete(task) }
        }
    }

    private func reminderRow(_ task: OttoTask) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                if let context = task.context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let fireAt = TasksModel.fireDate(of: task) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(fireAt, style: .time)
                        .font(.callout.monospacedDigit())
                    Text(fireAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func taskCell(_ task: OttoTask) -> some View {
        if task.items.isEmpty {
            Text(task.title)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let open = task.items.filter { !$0.checked }.count
                HStack {
                    Text(task.title)
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(open) left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(task.items) { listItem in
                    itemRow(listItem, in: task)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func itemRow(_ listItem: ListItem, in task: OttoTask) -> some View {
        Button {
            Task { await model.toggle(item: listItem, in: task) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: listItem.checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(listItem.checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(listItem.text)
                    .strikethrough(listItem.checked)
                    .foregroundStyle(listItem.checked ? .secondary : .primary)
                if let quantity = listItem.quantity {
                    Text(quantity)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No tasks yet")
                .font(.headline)
            Text("Ask Otto — \"remind me to call the dentist at three\" or \"add milk to my Walmart list.\"")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
