import Foundation

extension APIClient {
    /// The one-way door: erases everything server-side, then the auth user.
    /// The caller signs out locally when this returns.
    func deleteAccount() async throws {
        _ = try await jsonRequest(path: "account", method: "DELETE")
    }
}
