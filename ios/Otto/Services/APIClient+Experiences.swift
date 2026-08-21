import Foundation

/// The Voyages shelf: list, detail, delete. Experiences are created only
/// in conversation (the create_experience tool); these calls just browse
/// and prune what Otto holds.
extension APIClient {

    func listExperiences() async throws -> ExperienceListResponse {
        let data = try await jsonRequest(path: "experiences", method: "GET")
        return try decodeBody(ExperienceListResponse.self, from: data)
    }

    func experienceDetail(id: String) async throws -> Experience {
        let data = try await jsonRequest(path: "experiences/\(id)", method: "GET")
        return try decodeBody(Experience.self, from: data)
    }

    func deleteExperience(id: String) async throws {
        _ = try await jsonRequest(path: "experiences/\(id)", method: "DELETE")
    }
}
