import Foundation
import Observation

/// State for the Voyages shelf. The server is the truth: the list holds
/// summaries, details load on demand and cache by id.
@MainActor
@Observable
final class ExperiencesModel {

    private(set) var experiences: [ExperienceSummary] = []
    private(set) var details: [String: Experience] = [:]
    private(set) var isLoading = false
    var errorMessage: String?

    private let auth: any AuthProvider

    init(auth: any AuthProvider) {
        self.auth = auth
    }

    func load() async {
        guard let client = makeClient() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.listExperiences()
            experiences = response.experiences
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load voyages: \(error.localizedDescription)"
        }
    }

    func loadDetail(id: String) async {
        guard details[id] == nil, let client = makeClient() else { return }
        do {
            details[id] = try await client.experienceDetail(id: id)
        } catch {
            errorMessage = "Couldn't load that voyage: \(error.localizedDescription)"
        }
    }

    func delete(_ summary: ExperienceSummary) async {
        guard let client = makeClient() else { return }
        do {
            try await client.deleteExperience(id: summary.id)
            experiences.removeAll { $0.id == summary.id }
            details[summary.id] = nil
        } catch {
            errorMessage = "Couldn't delete it: \(error.localizedDescription)"
        }
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }
}
