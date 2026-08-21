import SwiftUI

/// Otto's home: nothing but the conversation. A greeting, the orb, the
/// words being exchanged right now, and the mic. Everything else lives in
/// its own tab; a triple-tap anywhere still toggles the debug overlay.
struct ConversationView: View {
    @Bindable var model: ConversationModel
    /// Signed-out state routes here (the Account tab holds sign-in).
    var onOpenAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stage
            statusCaption
            draftCard
            calendarCard
            planScheduleCard
            controlBar
        }
        .background(OttoTheme.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if model.overlayVisible {
                DebugOverlayView(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 130)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .simultaneousGesture(
            TapGesture(count: 3).onEnded {
                withAnimation(.snappy) { model.toggleOverlay() }
            }
        )
        .fullScreenCover(
            isPresented: Binding(
                get: { model.guidance.phase != .idle },
                set: { presented in
                    if !presented {
                        model.guidance.reset()
                    }
                }
            )
        ) {
            GuidanceView(runtime: model.guidance)
        }
        .sheet(item: $model.composeRequest) { request in
            MessageComposeView(request: request) {
                model.composeRequest = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: model.guidance.phase) { _, phase in
            if phase == .idle {
                // A session just wrapped — the chip should show what's next.
                Task { await model.refreshUpNext() }
            }
        }
        .task {
            model.activate()
            model.refreshAccount()
        }
    }

    // MARK: - The stage

    private var stage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            if model.signedIn {
                VStack(spacing: 6) {
                    Text(ConversationModel.greeting(for: Date()))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(OttoTheme.textPrimary)
                    Text("What's first?")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(OttoTheme.textSecondary)
                }
            } else {
                Text("Sign in to talk to Otto.")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
            }

            // Today's session, one tap away — the plan reaching back out.
            // (Hidden during tours: the state dips to idle for an instant
            // between chapters, and the pill must not blink in.)
            if model.signedIn, model.state == .idle, model.briefTourCard == nil,
                model.experienceTourCard == nil,
                let upNext = model.upNextLabel
            {
                Button {
                    model.startUpNext()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(upNext)
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(OttoTheme.ink, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
                .padding(.top, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .accessibilityLabel("Start \(upNext)")
            }

            Spacer(minLength: 18)

            EclipseOrb(
                state: model.state,
                level: model.micBars.last ?? 0,
                size: orbIsBig ? 320 : 150
            )

            Spacer(minLength: 16)

            if model.briefTourCard != nil {
                tourSlide
            } else if model.experienceTourCard != nil {
                experienceTourSlide
            } else if let visual = model.stageVisual {
                // Speaks and shows: the illustration for what Otto is
                // answering right now, slid in mid-turn by the server.
                StageVisualView(
                    visual: visual,
                    todaysEvents: model.todaysEvents,
                    todaysConflicts: model.todaysConflicts
                ) {
                    model.startTourPlanSession()
                }
                .id(model.stageVisualID)
                .padding(.horizontal, 16)
                .frame(maxHeight: 400)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
            } else if let offer = model.walkthroughOffer {
                WalkthroughCardView(
                    walkthrough: offer,
                    onStart: {
                        Haptics.press()
                        Task { await model.startWalkthrough() }
                    },
                    onDismiss: { model.dismissWalkthrough() }
                )
                .padding(.horizontal, 16)
                .frame(maxHeight: 400)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let card = model.briefCard {
                BriefCardView(card: card) {
                    model.dismissBrief()
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: 400)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let experience = model.experienceCard {
                ExperienceRestCard(experience: experience) {
                    model.dismissExperienceCard()
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let plan = model.planCard {
                // The detail lives here; the voice speaks only the summary.
                PlanCardView(plan: plan) {
                    model.dismissPlan()
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: 400)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                dialogue
                    .frame(maxHeight: 170)
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    /// The orb holds center stage until an illustration needs the room —
    /// the brief's resting card, a plan card, a tour chapter, or a data
    /// stage visual. Building and armed-automation moments are compact, so
    /// the orb stays big behind them.
    private var orbIsBig: Bool {
        model.briefCard == nil && model.planCard == nil && model.walkthroughOffer == nil
            && model.experienceTourCard == nil && model.experienceCard == nil
            && !tourVisualActive && !stageDataVisualActive
    }

    private var tourVisualActive: Bool {
        guard let chapter = model.briefChapter else { return false }
        return chapter.kind.hasVisual
    }

    private var stageDataVisualActive: Bool {
        switch model.stageVisual?.kind {
        case .weather, .calendar, .reminders, .plans: return true
        case .building, .automation, nil: return false
        }
    }

    /// The experience presentation slot — same slide mechanics as the
    /// brief tour, driven by the experience's own chapters.
    private var experienceTourSlide: some View {
        ZStack {
            if let chapter = model.experienceChapter, let tour = model.experienceTourCard {
                ExperienceChapterCardView(chapter: chapter, experience: tour)
                    .id(model.experienceChapterIndex)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: 400)
    }

    /// The tour's stage slot: each chapter's illustration slides in from
    /// the right while the previous slides out to the left, in step with
    /// the speech. Intro and outro leave the slot empty — the orb alone
    /// carries those moments.
    private var tourSlide: some View {
        ZStack {
            if let chapter = model.briefChapter, let tour = model.briefTourCard,
                chapter.kind.hasVisual
            {
                BriefChapterCardView(chapter: chapter, card: tour) {
                    model.startTourPlanSession()
                }
                .id(model.briefChapterIndex)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: 400)
    }

    /// The words of the current exchange only — no scrollback, no bubbles.
    @ViewBuilder
    private var dialogue: some View {
        if !model.signedIn {
            InkPillButton(title: "Go to Account") {
                onOpenAccount()
            }
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    if let user = lastUserLine {
                        Text(user.text)
                            .font(.subheadline)
                            .foregroundStyle(OttoTheme.textSecondary)
                            .opacity(user.isFinal ? 1 : 0.65)
                    }
                    if let otto = lastOttoLine {
                        Text(otto)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(OttoTheme.textPrimary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    if let notice = latestNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 30)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
        }
    }

    private var lastUserLine: TranscriptEntry? {
        model.entries.last(where: { $0.role == .user })
    }

    private var lastOttoLine: String? {
        model.entries.last(where: { $0.role == .otto })?.text
    }

    /// Only a notice that is the latest thing that happened.
    private var latestNotice: String? {
        if let last = model.entries.last, last.role == .notice {
            return last.text
        }
        return nil
    }

    // MARK: - Status

    @ViewBuilder
    private var statusCaption: some View {
        Group {
            // A running generation owns the caption: a progress state, not a
            // spinner, across both the thinking and speaking phases.
            switch model.planPhase {
            case .designing:
                Text("Designing your week…")
                    .foregroundStyle(OttoTheme.textSecondary)
            case .scheduling:
                Text("Scheduling sessions…")
                    .foregroundStyle(OttoTheme.textSecondary)
            case .idle:
                if model.briefTourCard != nil {
                    // Steady through the whole tour — the voice state dips
                    // to idle between chapters and must not flicker this.
                    Text("Your morning brief")
                        .foregroundStyle(OttoTheme.textTertiary)
                } else if let tour = model.experienceTourCard {
                    Text(
                        tour.kind == .trip
                            ? "Your trip" : tour.kind == .date ? "Your date" : "Your day out"
                    )
                    .foregroundStyle(OttoTheme.textTertiary)
                } else {
                    switch model.state {
                    case .idle:
                        Color.clear
                    case .listening:
                        Text("Listening")
                            .foregroundStyle(OttoTheme.textSecondary)
                    case .thinking:
                        ThinkingIndicator()
                    case .speaking:
                        Text("Speak to interrupt")
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                }
            }
        }
        .font(.caption)
        .frame(height: 26)
        .animation(.snappy(duration: 0.2), value: model.state)
        .animation(.snappy(duration: 0.2), value: model.planPhase)
    }

    // MARK: - Draft confirmation card

    @ViewBuilder
    private var draftCard: some View {
        if case .confirming(let request) = model.draftStage {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEXT TO \(request.recipientName.uppercased())")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OttoTheme.rose)
                Text(request.body)
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textPrimary)
                    .lineLimit(4)
                HStack {
                    Button("Cancel") {
                        model.cancelDraftTapped()
                    }
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textSecondary)
                    Spacer()
                    InkPillButton(title: "Send…") {
                        model.confirmDraftTapped()
                    }
                }
            }
            .ottoCard(padding: 14)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Calendar confirmation card

    /// Visible while a calendar change awaits confirmation — the tapped
    /// alternative to saying "yes". The write is verified by read-back.
    @ViewBuilder
    private var calendarCard: some View {
        if case .confirming(let change) = model.calendarStage {
            VStack(alignment: .leading, spacing: 8) {
                switch change {
                case .create(let draft):
                    Text("ADD TO CALENDAR")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OttoTheme.sky)
                    Text(draft.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(OttoTheme.textPrimary)
                    Text(
                        "\(draft.startsAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute())) – \(draft.endsAt.formatted(date: .omitted, time: .shortened))"
                    )
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
                    if let location = draft.location {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textTertiary)
                    }
                case .move(let original, let newStart, _):
                    Text("MOVE EVENT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OttoTheme.sky)
                    Text(original.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(OttoTheme.textPrimary)
                    Text("from  \(original.startsAt.formatted(.dateTime.weekday().month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(OttoTheme.textSecondary)
                    Text("to  \(newStart.formatted(.dateTime.weekday().month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(OttoTheme.textPrimary)
                }
                HStack {
                    Button("Cancel") {
                        model.cancelCalendarTapped()
                    }
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textSecondary)
                    Spacer()
                    InkPillButton(title: "Confirm") {
                        model.confirmCalendarTapped()
                    }
                }
            }
            .ottoCard(padding: 14)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Plan scheduling confirmation card

    /// Inline verification: exactly what will be added, confirmed by tap or
    /// voice. Every write is verified by read-back before success is spoken.
    @ViewBuilder
    private var planScheduleCard: some View {
        if model.planScheduleStage == .offering {
            VStack(alignment: .leading, spacing: 8) {
                Text("ADD TO CALENDAR")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OttoTheme.sky)
                Text("\(model.planScheduleDrafts.count) sessions")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(OttoTheme.textPrimary)
                ForEach(model.planScheduleDrafts.prefix(3)) { item in
                    HStack(spacing: 8) {
                        Text(
                            item.draft.startsAt.formatted(
                                .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                    .hour().minute()
                            )
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OttoTheme.textSecondary)
                        Text(item.draft.title)
                            .font(.caption)
                            .foregroundStyle(OttoTheme.textPrimary)
                            .lineLimit(1)
                    }
                }
                if model.planScheduleDrafts.count > 3 {
                    Text("+ \(model.planScheduleDrafts.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(OttoTheme.textTertiary)
                }
                HStack {
                    Button("Not now") {
                        model.cancelPlanScheduleTapped()
                    }
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textSecondary)
                    Spacer()
                    InkPillButton(title: "Add all") {
                        model.confirmPlanScheduleTapped()
                    }
                }
            }
            .ottoCard(padding: 14)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - The mic

    private var controlBar: some View {
        MicButton(systemName: micIsIdle ? "mic.fill" : "stop.fill") {
            Haptics.press()
            model.toggleVoice()
        }
        .disabled(!model.signedIn)
        .accessibilityLabel(micIsIdle ? "Start voice conversation" : "Stop")
        .padding(.top, 2)
        .padding(.bottom, 66)
    }

    /// Steady stop glyph through any tour — the state's between-chapter
    /// idle dips must not flash the mic icon.
    private var micIsIdle: Bool {
        model.state == .idle && model.briefTourCard == nil
            && model.experienceTourCard == nil
    }
}
