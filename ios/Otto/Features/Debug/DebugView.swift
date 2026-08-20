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
        case .taskCreated, .taskUpdated, .draft, .calendarProposal,
             .planProgress, .planReady, .planFailed:
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

    /// Optional hook the conversation screen provides so the wake-time
    /// controls can (re)schedule the weekday brief notifications.
    var onBriefScheduleChange: ((Bool, Int, Int) -> Void)?
    /// Fired when the calendar-sync consent toggle changes.
    var onCalendarSyncChange: ((Bool) -> Void)?
    @State private var briefEnabled = false
    @State private var wakeTime = Date()
    @State private var calendarSyncEnabled = false

    var body: some View {
        // Pushed from the Account tab — no NavigationStack of its own.
        Form {
            briefSection
            calendarSyncSection
            serverSection
            accountSection
            converseSection
        }
        .scrollContentBackground(.hidden)
        .background(OttoTheme.background)
        .navigationTitle("Settings")
        .onAppear {
            briefEnabled = UserDefaults.standard.bool(forKey: "otto.brief.enabled")
            var components = DateComponents()
            components.hour = UserDefaults.standard.object(forKey: "otto.brief.hour") as? Int ?? 7
            components.minute = UserDefaults.standard.object(forKey: "otto.brief.minute") as? Int ?? 30
            wakeTime = Calendar.current.date(from: components) ?? Date()
            calendarSyncEnabled = UserDefaults.standard.bool(forKey: CalendarSyncService.consentKey)
        }
    }

    /// The consent screen for calendar sync. The footer is the contract:
    /// what leaves the device, what never does, and how long it lives.
    private var calendarSyncSection: some View {
        Section {
            Toggle("Calendar sync", isOn: $calendarSyncEnabled)
                .onChange(of: calendarSyncEnabled) { _, enabled in
                    // onAppear seeds this state from defaults; only a REAL
                    // change (the user's tap) may write and kick a sync.
                    let stored = UserDefaults.standard.bool(forKey: CalendarSyncService.consentKey)
                    guard stored != enabled else { return }
                    UserDefaults.standard.set(enabled, forKey: CalendarSyncService.consentKey)
                    onCalendarSyncChange?(enabled)
                }
        } header: {
            Text("Calendar")
        } footer: {
            Text(
                """
                Lets Otto prepare you for meetings and mention your schedule \
                in briefings. Otto uploads a compressed view of your next \
                48 hours — event titles, times, locations, and how many \
                people are attending. Notes, descriptions, and attendee \
                names or emails never leave this device. The server keeps \
                the view for at most 48 hours, then deletes it.
                """
            )
        }
    }

    private var briefSection: some View {
        Section("Morning brief") {
            Toggle("Weekday brief at wake time", isOn: $briefEnabled)
                .onChange(of: briefEnabled) { _, _ in
                    pushBriefSchedule()
                }
            DatePicker("Wake time", selection: $wakeTime, displayedComponents: .hourAndMinute)
                .onChange(of: wakeTime) { _, _ in
                    pushBriefSchedule()
                }
                .disabled(!briefEnabled)
        }
    }

    private func pushBriefSchedule() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: wakeTime)
        onBriefScheduleChange?(briefEnabled, components.hour ?? 7, components.minute ?? 30)
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
