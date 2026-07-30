import Observation
import SwiftUI

/// State for the Phase 0 debug screen: sign in, send text, watch the stream.
@MainActor
@Observable
final class DebugModel {
    // Server
    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.serverURLKey) }
    }

    // Account
    var email = ""
    var password = ""
    var signedInUserId: String?
    var authMessage = ""
    var isAuthBusy = false

    // Converse
    var utterance = ""
    var transcript = ""
    var statusLine = ""
    var isStreaming = false

    /// Shared with ConversationModel so both screens read one server URL.
    static let serverURLKey = "otto.debug.serverURL"
    private let auth: any AuthProvider

    init(auth: any AuthProvider) {
        self.auth = auth
        self.serverURLString =
            UserDefaults.standard.string(forKey: Self.serverURLKey) ?? "http://localhost:8080"
        self.signedInUserId = auth.currentUserId
    }

    var canSubmitCredentials: Bool {
        !email.isEmpty && !password.isEmpty && !isAuthBusy
    }

    var canSend: Bool {
        signedInUserId != nil
            && !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isStreaming
    }

    func signIn() async {
        await runAuth { try await self.auth.signIn(email: self.email, password: self.password) }
    }

    func signUp() async {
        await runAuth { try await self.auth.signUp(email: self.email, password: self.password) }
    }

    func signOut() {
        do {
            try auth.signOut()
            authMessage = ""
        } catch {
            authMessage = error.localizedDescription
        }
        signedInUserId = auth.currentUserId
    }

    private func runAuth(_ operation: () async throws -> Void) async {
        isAuthBusy = true
        authMessage = ""
        do {
            try await operation()
        } catch {
            authMessage = error.localizedDescription
        }
        signedInUserId = auth.currentUserId
        isAuthBusy = false
    }

    func send() async {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        guard let baseURL = URL(string: serverURLString), baseURL.scheme != nil else {
            statusLine = "Invalid server URL."
            return
        }

        transcript = ""
        statusLine = "…"
        isStreaming = true
        defer { isStreaming = false }

        let client = APIClient(baseURL: baseURL, auth: auth)
        let turn = TurnRequest(
            turnId: UUID().uuidString,
            text: text,
            clientTimestamp: Date(),
            timezone: TimeZone.current.identifier
        )

        do {
            // Consuming on the MainActor means every token lands as its own
            // UI update — the transcript grows visibly, word by word.
            for try await event in client.converse(turn) {
                handle(event)
            }
            if statusLine == "…" {
                statusLine = "Stream ended without a done event."
            }
        } catch {
            statusLine = "Error: \(error.localizedDescription)"
        }
    }

    private func handle(_ event: TurnEvent) {
        switch event.type {
        case .token:
            transcript += event.data?.stringValue ?? ""
        case .done:
            let info = event.data?.objectValue
            let tier = info?["tier"]?.stringValue ?? "?"
            let modelName = info?["model"]?.stringValue ?? "on-device"
            statusLine = "done — tier: \(tier), model: \(modelName)"
        case .taskCreated, .taskUpdated:
            statusLine = "(\(event.type.rawValue))"
        case .error:
            statusLine = "Server error event: \(event.data?.stringValue ?? "unknown")"
        }
    }
}

/// One screen: email/password sign-in, a text field, a send button, and the
/// streamed response rendering token by token as it arrives.
struct DebugView: View {
    @Bindable var model: DebugModel

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                accountSection
                converseSection
            }
            .navigationTitle("Otto Debug")
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("http://localhost:8080", text: $model.serverURLString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if let uid = model.signedInUserId {
                LabeledContent("Signed in") {
                    Text(uid)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Button("Sign Out", role: .destructive) {
                    model.signOut()
                }
            } else {
                TextField("Email", text: $model.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                HStack {
                    Button("Sign In") {
                        Task { await model.signIn() }
                    }
                    Spacer()
                    Button("Sign Up") {
                        Task { await model.signUp() }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!model.canSubmitCredentials)
            }
            if !model.authMessage.isEmpty {
                Text(model.authMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var converseSection: some View {
        Section("Converse") {
            TextField("Say something…", text: $model.utterance, axis: .vertical)
                .lineLimit(1...4)
            Button {
                Task { await model.send() }
            } label: {
                if model.isStreaming {
                    ProgressView()
                } else {
                    Text("Send")
                }
            }
            .disabled(!model.canSend)
            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !model.statusLine.isEmpty {
                Text(model.statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
