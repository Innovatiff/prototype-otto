import FirebaseAuth
import Foundation

/// Firebase email/password implementation of `AuthProvider`.
///
/// `@unchecked Sendable`: FirebaseAuth's `Auth` is a thread-safe reference
/// type; this wrapper holds it immutably and adds no state of its own.
final class EmailPasswordAuth: AuthProvider, @unchecked Sendable {
    private let auth: Auth

    init(auth: Auth = Auth.auth()) {
        self.auth = auth
    }

    var currentUserId: String? {
        auth.currentUser?.uid
    }

    func signIn(email: String, password: String) async throws {
        _ = try await auth.signIn(withEmail: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        _ = try await auth.createUser(withEmail: email, password: password)
    }

    func signOut() throws {
        try auth.signOut()
    }

    func idToken() async throws -> String {
        guard let user = auth.currentUser else {
            throw AuthProviderError.notSignedIn
        }
        // Returns the cached token while valid and refreshes transparently
        // otherwise — safe to call once per request.
        return try await user.getIDToken()
    }
}
