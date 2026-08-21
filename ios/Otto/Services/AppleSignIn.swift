import AuthenticationServices
import CryptoKit
import Foundation

/// Sign in with Apple → Firebase, the standard nonce dance: a random nonce
/// rides the Apple request as its SHA-256, Apple signs it into the identity
/// token, Firebase verifies the pair. Used from SwiftUI's
/// SignInWithAppleButton, which owns the UI.
enum AppleSignIn {

    /// Random URL-safe nonce for one attempt.
    static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Pulls the identity token out of a successful authorization.
    static func identityToken(from authorization: ASAuthorization) -> String? {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken
        else { return nil }
        return String(data: tokenData, encoding: .utf8)
    }
}
