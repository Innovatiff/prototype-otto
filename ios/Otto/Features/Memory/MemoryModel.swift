import Foundation
import Observation

/// State for the memory screen: everything Otto knows, editable and
/// deletable. The privacy promise made concrete.
@MainActor
@Observable
final class MemoryModel {

    private(set) var memories: [Memory] = []
    private(set) var isLoading = false
    private(set) var errorText: String?

    /// Inline editing: the row being edited and its working text.
    private(set) var editingId: String?
    var editText = ""

    private let auth: any AuthProvider

    init(auth: any AuthProvider) {
        self.auth = auth
    }

    /// Fixed presentation order; groups with no memories are dropped.
    static let categoryOrder: [MemoryCategory] = [
        .identity, .schedule, .preference, .constraint, .goal, .context,
    ]

    /// Grouped by category; within a group the server's newest-first order
    /// is preserved.
    var grouped: [(category: MemoryCategory, memories: [Memory])] {
        Self.categoryOrder.compactMap { category in
            let inCategory = memories.filter { $0.category == category }
            return inCategory.isEmpty ? nil : (category, inCategory)
        }
    }

    func load() async {
        guard let client = makeClient() else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            memories = try await client.listMemories()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func beginEditing(_ memory: Memory) {
        editingId = memory.id
        editText = memory.content
    }

    func cancelEditing() {
        editingId = nil
        editText = ""
    }

    /// Saves the edit; the server re-embeds and marks userEdited, which
    /// protects the memory from auto-overwrite forever after.
    func commitEdit() async {
        guard let id = editingId else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingId = nil
        guard let index = memories.firstIndex(where: { $0.id == id }),
              !text.isEmpty,
              text != memories[index].content,
              let client = makeClient()
        else { return }
        do {
            memories[index] = try await client.updateMemory(id: id, content: text)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func delete(_ memory: Memory) async {
        guard let client = makeClient() else { return }
        do {
            try await client.deleteMemory(id: memory.id)
            memories.removeAll { $0.id == memory.id }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func deleteAll() async {
        guard let client = makeClient() else { return }
        do {
            try await client.deleteAllMemories()
            memories = []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else {
            errorText = "Invalid server URL."
            return nil
        }
        guard auth.currentUserId != nil else {
            errorText = "Sign in to see what Otto remembers."
            return nil
        }
        return APIClient(baseURL: url, auth: auth)
    }
}
