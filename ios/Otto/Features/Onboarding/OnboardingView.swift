import AuthenticationServices
import SwiftUI

/// First run, in the order that converts: sign in → AI consent → Otto asks
/// three questions BY VOICE → calendar in context → the activation moment
/// (a REAL plan or brief) → and only then the paywall (presented by
/// RootView once the artifact is on stage). Value before payment.
@MainActor
@Observable
final class OnboardingModel {

    enum Stage {
        case welcome
        case signIn
        case consent
        case voiceSetup
        case calendar
        case activation
    }

    static let completedKey = "otto.onboarding.completed"
    static let consentVersion = "2026-08"
    /// Set when the activation artifact lands; RootView shows the paywall
    /// once and clears it.
    static let paywallPendingKey = "otto.onboarding.paywallPending"

    var stage: Stage = .welcome
    var questionText = ""
    var goalText = ""
    var busy = false
    var errorMessage: String?

    private let conversation: ConversationModel
    private let auth: EmailPasswordAuth
    private var appleNonce = ""

    init(conversation: ConversationModel, auth: EmailPasswordAuth) {
        self.conversation = conversation
        self.auth = auth
    }

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    // MARK: - Sign in with Apple

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        appleNonce = AppleSignIn.makeNonce()
        request.requestedScopes = [.email]
        request.nonce = AppleSignIn.sha256(appleNonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let token = AppleSignIn.identityToken(from: authorization) else {
                errorMessage = "Apple didn't return a credential. Try again."
                return
            }
            busy = true
            Task {
                do {
                    try await self.auth.signInWithApple(idToken: token, rawNonce: self.appleNonce)
                    self.conversation.refreshAccount()
                    withAnimation(.snappy) { self.stage = .consent }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
                self.busy = false
            }
        case .failure:
            // Cancelled — stay put, no scolding.
            break
        }
    }

    // MARK: - Consent

    func acceptConsent() {
        busy = true
        Task {
            do {
                if let client = self.makeClient() {
                    try await client.grantConsent(version: Self.consentVersion)
                }
                UserDefaults.standard.set(Self.consentVersion, forKey: "otto.consent.version")
                withAnimation(.snappy) { self.stage = .voiceSetup }
                self.startVoiceQuestions()
            } catch {
                self.errorMessage = "Couldn't save consent: \(error.localizedDescription)"
            }
            self.busy = false
        }
    }

    /// Declining is real: onboarding completes into the limited state and
    /// every model feature stays off (the SERVER refuses independently).
    func declineConsent() {
        finish()
    }

    // MARK: - The three voice questions

    private func startVoiceQuestions() {
        Task {
            await self.conversation.beginOnboardingVoice()
            await self.askName()
        }
    }

    private func askName() async {
        questionText = "What should I call you?"
        await speakAndCapture("I'm Otto. First things first — what should I call you?") { reply in
            Task {
                let term = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty, let client = self.makeClient() {
                    try? await client.setAddressTerm(String(term.prefix(40)))
                }
                await self.askWakeTime()
            }
        }
    }

    private func askWakeTime() async {
        questionText = "What time do you usually get up?"
        await speakAndCapture("Good. What time do you usually get up?") { reply in
            let (hour, minute) = Self.parseWakeTime(reply) ?? (7, 30)
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "otto.brief.enabled")
            defaults.set(hour, forKey: "otto.brief.hour")
            defaults.set(minute, forKey: "otto.brief.minute")
            self.conversation.setBriefSchedule(enabled: true, hour: hour, minute: minute)
            Task { await self.askGoal() }
        }
    }

    private func askGoal() async {
        questionText = "What are you trying to get on top of right now?"
        await speakAndCapture(
            "Last one. What are you trying to get on top of right now?"
        ) { reply in
            self.goalText = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                if !self.goalText.isEmpty, let client = self.makeClient() {
                    try? await client.createMemory(category: "goal", content: self.goalText)
                }
                await self.conversation.endOnboardingVoice()
                withAnimation(.snappy) { self.stage = .calendar }
            }
        }
    }

    private func speakAndCapture(_ line: String, then handler: @escaping (String) -> Void) async {
        conversation.onboardingCapture = handler
        await conversation.onboardingAsk(line)
    }

    /// "7", "7am", "around 6:45", "seven thirty" (digits only; words fall
    /// back to 7:30 — the automations screen can fix it later).
    static func parseWakeTime(_ text: String) -> (Int, Int)? {
        let lowered = text.lowercased()
        guard let match = lowered.range(of: #"(\d{1,2})(?::(\d{2}))?"#, options: .regularExpression)
        else { return nil }
        let parts = lowered[match].split(separator: ":")
        guard var hour = Int(parts.first ?? "") else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        if lowered.contains("pm") && hour < 12 { hour += 12 }
        if lowered.contains("am") && hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    // MARK: - Calendar + activation

    func enableCalendar() {
        UserDefaults.standard.set(true, forKey: CalendarSyncService.consentKey)
        advanceToActivation()
    }

    func skipCalendar() {
        advanceToActivation()
    }

    private func advanceToActivation() {
        withAnimation(.snappy) { stage = .activation }
    }

    /// The activation moment: one REAL artifact from their own answer —
    /// a plan for fitness/productivity goals, today's brief for the rest.
    func runActivation() {
        UserDefaults.standard.set(true, forKey: Self.paywallPendingKey)
        finish()
        let goal = goalText.lowercased()
        let planWords = [
            "workout", "gym", "fit", "strength", "run", "muscle", "weight",
            "study", "learn", "exam", "focus", "productiv", "habit", "read",
        ]
        if !goalText.isEmpty, planWords.contains(where: { goal.contains($0) }) {
            conversation.submitProgrammatic("Build me a plan: \(goalText)")
        } else {
            Task { await self.conversation.runBrief() }
        }
    }

    private func finish() {
        conversation.onboardingCapture = nil
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }
}

// MARK: - The screens

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.stage {
            case .welcome: welcome
            case .signIn: signIn
            case .consent: consent
            case .voiceSetup: voiceSetup
            case .calendar: calendar
            case .activation: activation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OttoTheme.background.ignoresSafeArea())
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(OttoTheme.peach)
            Text("Otto")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
            Text("A coach, a planner, and an assistant.\nYou talk; it handles the day.")
                .font(.callout)
                .foregroundStyle(OttoTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            InkPillButton(title: "Get started") {
                withAnimation(.snappy) { model.stage = .signIn }
            }
            .padding(.bottom, 50)
        }
        .padding(24)
    }

    private var signIn: some View {
        VStack(spacing: 14) {
            Spacer()
            stepHeader("Your account", "Everything Otto holds follows your account, not your phone.")
            SignInWithAppleButton(.signIn) { request in
                model.configureAppleRequest(request)
            } onCompletion: { result in
                model.handleAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(Capsule())
            .padding(.horizontal, 8)
            .disabled(model.busy)
            Text("Or sign in with email later in Settings.")
                .font(.caption)
                .foregroundStyle(OttoTheme.textTertiary)
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(24)
    }

    private var consent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stepHeader("Otto thinks with Claude", nil)
                    .frame(maxWidth: .infinity)
                consentRow(
                    "paperplane.fill", OttoTheme.sky,
                    "What is sent",
                    "Your messages to Otto, calendar context you've enabled, and facts Otto remembers for you."
                )
                consentRow(
                    "building.2.fill", OttoTheme.lavender,
                    "Where it goes",
                    "Anthropic (the maker of Claude) processes it to generate Otto's answers, plans, and briefs."
                )
                consentRow(
                    "lock.shield.fill", OttoTheme.mint,
                    "What never happens",
                    "Your data is not used to train models, and your voice audio never leaves this device."
                )
                Text("You can revoke this anytime in Settings; Otto's model features turn off until you re-enable it.")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textTertiary)
                Spacer(minLength: 20)
                InkPillButton(title: "I agree") {
                    model.acceptConsent()
                }
                .frame(maxWidth: .infinity)
                Button("Not now") {
                    model.declineConsent()
                }
                .font(.callout)
                .foregroundStyle(OttoTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)
            }
            .padding(24)
        }
    }

    private func consentRow(
        _ symbol: String, _ tint: Color, _ title: String, _ body: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(OttoTheme.textPrimary)
                Text(body).font(.caption).foregroundStyle(OttoTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard(padding: 13)
    }

    private var voiceSetup: some View {
        VStack(spacing: 16) {
            Spacer()
            EclipseOrb(state: .listening, level: 0.4, size: 210)
            Text(model.questionText)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Just say it — Otto is listening.")
                .font(.footnote)
                .foregroundStyle(OttoTheme.textTertiary)
            Spacer()
        }
        .padding(24)
    }

    private var calendar: some View {
        VStack(spacing: 14) {
            Spacer()
            stepHeader(
                "The morning brief",
                "With calendar access, Otto opens your day: weather, schedule, conflicts, what's due. Titles and times only — notes and attendees never leave this device."
            )
            InkPillButton(title: "Enable calendar") {
                model.enableCalendar()
            }
            Button("Maybe later") {
                model.skipCalendar()
            }
            .font(.callout)
            .foregroundStyle(OttoTheme.textSecondary)
            Spacer()
        }
        .padding(24)
    }

    private var activation: some View {
        VStack(spacing: 14) {
            Spacer()
            stepHeader(
                model.goalText.isEmpty ? "Let's open your day" : "Watch this",
                model.goalText.isEmpty
                    ? "Otto will run your first brief right now."
                    : "Otto will build your first plan for that — for real, right now."
            )
            InkPillButton(title: "Go") {
                onDone()
                model.runActivation()
            }
            Spacer()
        }
        .padding(24)
    }

    private func stepHeader(_ title: String, _ subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
