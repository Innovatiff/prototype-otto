import SwiftUI

/// Everything Otto remembers — visible, editable, deletable.
struct MemoryView: View {
    @Bindable var model: MemoryModel
    @State private var confirmingDeleteAll = false
    @FocusState private var focusedMemory: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.memories.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    memoryList
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete All", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .disabled(model.memories.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete all memories?",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { await model.deleteAll() }
                }
            } message: {
                Text("Otto permanently forgets every stored fact. This cannot be undone.")
            }
            .task { await model.load() }
            .refreshable { await model.load() }
        }
    }

    private var memoryList: some View {
        List {
            ForEach(model.grouped, id: \.category) { group in
                Section(group.category.rawValue.capitalized) {
                    ForEach(group.memories) { memory in
                        row(for: memory)
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

    @ViewBuilder
    private func row(for memory: Memory) -> some View {
        Group {
            if model.editingId == memory.id {
                TextField("Memory", text: $model.editText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focusedMemory, equals: memory.id)
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await model.commitEdit() }
                    }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(memory.content)
                        .strikethrough(memory.supersededBy != nil)
                        .foregroundStyle(memory.supersededBy != nil ? .secondary : .primary)
                    HStack(spacing: 8) {
                        Text(memory.createdAt, style: .date)
                        if memory.userEdited {
                            Text("edited by you")
                        }
                        if memory.supersededBy != nil {
                            Text("replaced")
                        }
                        if memory.conflictsWith != nil {
                            Text("conflicts with an edit")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.beginEditing(memory)
                    focusedMemory = memory.id
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", role: .destructive) {
                Task { await model.delete(memory) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Nothing remembered yet")
                .font(.headline)
            Text(
                """
                As you talk, Otto keeps short, durable facts — preferences, \
                constraints, schedules, goals — so answers fit you instead of \
                being generic. Everything he stores appears here, in plain \
                words. Edit anything (your edits are never overwritten) or \
                delete anything, anytime. Audio is never stored.
                """
            )
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
