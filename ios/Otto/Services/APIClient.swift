import Foundation

/// Typed client errors. Raw server text only ever appears inside `http`
/// bodies, which the server guarantees are structured JSON error envelopes.
enum APIError: Error, LocalizedError {
    case invalidURL
    case notHTTP
    /// A non-2xx response. 4xx is never retried; 5xx lands here only after
    /// retries are exhausted.
    case http(status: Int, body: String)
    case decoding(underlying: any Error)
    case transport(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .notHTTP:
            return "The response was not HTTP."
        case .http(let status, let body):
            return "Server returned \(status): \(body.isEmpty ? "no body" : body)"
        case .decoding(let underlying):
            return "Could not decode the server's response: \(underlying.localizedDescription)"
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        }
    }
}

/// Talks to the Otto backend.
///
/// - Attaches a Firebase ID token as a Bearer header on every request
///   (fetched fresh from the AuthProvider per attempt).
/// - Retries with exponential backoff on 5xx only — never on 4xx, and never
///   once a stream has started delivering events.
struct APIClient: Sendable {
    let baseURL: URL
    let auth: any AuthProvider
    let session: URLSession = .shared

    /// Total attempts for a request that keeps answering 5xx.
    private static let maxAttempts = 3
    private static let backoffBaseSeconds = 0.5

    init(baseURL: URL, auth: any AuthProvider) {
        self.baseURL = baseURL
        self.auth = auth
    }

    // MARK: - /converse

    /// Streams one turn. Events arrive in order; the stream finishes after the
    /// server's `done` event (or throws a typed error). Cancelling the
    /// consuming task cancels the underlying request.
    func converse(_ turn: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamConverse(turn, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func streamConverse(
        _ turn: TurnRequest,
        into continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(turn)
        } catch {
            throw APIError.decoding(underlying: error)
        }

        var attempt = 0
        while true {
            attempt += 1
            let request = try await makeRequest(path: "converse", body: body)

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                // Transport failures are not 5xx — the retry policy does not
                // cover them.
                throw APIError.transport(underlying: error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw APIError.notHTTP
            }

            switch http.statusCode {
            case 200...299:
                try await forward(bytes, into: continuation)
                return
            case 500...599 where attempt < Self.maxAttempts:
                _ = await drainBody(bytes)
                // 0.5s, 1s, 2s… — exponential, 5xx only.
                let delay = Self.backoffBaseSeconds * Double(1 << (attempt - 1))
                try await Task.sleep(for: .seconds(delay))
            default:
                // 4xx immediately; 5xx once retries are exhausted.
                throw APIError.http(status: http.statusCode, body: await drainBody(bytes))
            }
        }
    }

    /// Reads SSE lines, decodes each `data:` payload as a TurnEvent, and
    /// yields it. Our server emits exactly one single-line `data:` field per
    /// event, so multi-line SSE data concatenation is intentionally not
    /// implemented.
    private func forward(
        _ bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws {
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else {
                    continue
                }
                let payload = Data(line.dropFirst("data: ".count).utf8)
                let event: TurnEvent
                do {
                    event = try OttoCoding.decoder.decode(TurnEvent.self, from: payload)
                } catch {
                    throw APIError.decoding(underlying: error)
                }
                continuation.yield(event)
                if event.type == .done {
                    return
                }
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(underlying: error)
        }
    }

    // MARK: - Helpers

    private func makeRequest(path: String, body: Data) async throws -> URLRequest {
        // A fresh (cached-if-valid) token per attempt, on every request.
        let token = try await auth.idToken()
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// Best-effort read of an error body, capped so a huge response cannot
    /// balloon memory. Never throws — the status code is the primary signal.
    private func drainBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 16_384 {
                    break
                }
            }
        } catch {
            // Partial bodies are fine.
        }
        return String(decoding: data, as: UTF8.self)
    }
}
