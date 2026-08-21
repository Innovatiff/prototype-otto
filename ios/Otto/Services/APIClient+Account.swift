import Foundation

extension APIClient {
    /// The one-way door: erases everything server-side, then the auth user.
    /// The caller signs out locally when this returns.
    func deleteAccount() async throws {
        _ = try await jsonRequest(path: "account", method: "DELETE")
    }
}

extension APIClient {
    /// Third-party AI consent — the server refuses model routes without it.
    func grantConsent(version: String) async throws {
        struct Body: Encodable { let version: String }
        let body = try encodeBody(Body(version: version))
        _ = try await jsonRequest(path: "consent", method: "POST", body: body)
    }

    func revokeConsent() async throws {
        _ = try await jsonRequest(path: "consent", method: "DELETE")
    }

    /// Onboarding's spoken "what should I call you?" answer.
    func setAddressTerm(_ term: String) async throws {
        struct Body: Encodable { let term: String }
        let body = try encodeBody(Body(term: term))
        _ = try await jsonRequest(path: "account/address-term", method: "POST", body: body)
    }

    /// Max family seats (up to three emails).
    func setSeats(_ emails: [String]) async throws {
        struct Body: Encodable { let emails: [String] }
        let body = try encodeBody(Body(emails: emails))
        _ = try await jsonRequest(path: "account/seats", method: "POST", body: body)
    }

    /// "Report a response" — into the server-side moderation queue.
    func reportResponse(content: String, context: String?) async throws {
        struct Body: Encodable {
            let content: String
            let context: String?
        }
        let body = try encodeBody(Body(content: content, context: context))
        _ = try await jsonRequest(path: "moderation/report", method: "POST", body: body)
    }

    private func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try OttoCoding.encoder.encode(value)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
