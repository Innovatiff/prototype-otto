import Foundation

/// The auth seam.
///
/// Everything downstream (APIClient, views) depends only on this protocol.
/// Phase 0 ships `EmailPasswordAuth` (Firebase email/password); Sign in with
/// Apple drops in later as a second implementation without touching any call
/// site.
///
/// `Sendable` because an AuthProvider crosses concurrency domains — the
/// MainActor UI holds it and background request tasks read tokens from it.
protocol AuthProvider: Sendable {
    /// The signed-in user's uid, or nil when signed out.
    var currentUserId: String? { get }
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws
    func signOut() throws
    /// A fresh (or cached-but-valid) ID token to attach as a Bearer header.
    func idToken() async throws -> String
}

enum AuthProviderError: Error, LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in."
        }
    }
}
