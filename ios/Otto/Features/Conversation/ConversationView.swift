import SwiftUI

/// Otto's stage. No header, no chrome: a title, the eclipse, the words
/// being exchanged right now, and three controls. History and management
/// live in the hub; typing lives in settings; a triple-tap anywhere still
/// toggles the debug overlay.
struct ConversationView: View {
    @Bindable var model: ConversationModel
    /// Settings sheet (server URL, account, typed fallback input).
    @Bindable var settings: DebugModel
    @Bindable var memory: MemoryModel
    @Bindable var tasks: TasksModel
    @Bindable var plans: PlansModel
    /// Owned by the app; the settings sheet flips its consent and the view
    /// kicks an immediate first sync on opt-in.
    var calendarSync: CalendarSyncService
    @State private var showingSettings = false
    @State private var showingHub = false

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
        .sheet(isPresented: $showingHub) {
            HubView(
                tasks: tasks,
                memory: memory,
                plans: plans,
                onAdaptPlan: {
                    // Adaptation is spoken: close the hub, open the mic, and
                    // the user says what changed.
                    showingHub = false
                    model.beginPlanAdaptation()
                },
                onStartSession: { plan in
                    showingHub = false
                    Task {
                        // Let the sheet finish dismissing before the
                        // full-screen cover presents — simultaneous
                        // transitions can drop the presentation.
                        try? await Task.sleep(for: .milliseconds(300))
                        await model.startSession(with: plan)
                    }
                }
            )
        }
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
        .sheet(isPresented: $showingSettings) {
            DebugView(
                model: settings,
                onBriefScheduleChange: { enabled, hour, minute in
                    model.setBriefSchedule(enabled: enabled, hour: hour, minute: minute)
                },
                onCalendarSyncChange: { enabled in
                    if enabled {
                        // Consent just granted — push the first view now so
                        // meeting prep can arm today, not tomorrow.
                        Task { await calendarSync.syncIfNeeded(force: true) }
                    }
                }
            )
        }
        .sheet(item: $model.composeRequest) { request in
            MessageComposeView(request: request) {
                model.composeRequest = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: showingSettings) { _, isPresented in
            if !isPresented {
                model.refreshAccount()
                Task { await model.refreshUpNext() }
            }
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
                Text("What's first?")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(OttoTheme.textPrimary)
            } else {
                Text("Sign in to talk to Otto.")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(OttoTheme.textPrimary)
            }

            // Today's session, one tap away — the plan reaching back out.
            if model.signedIn, model.state == .idle, let upNext = model.upNextLabel {
                Button {
                    model.startUpNext()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(upNext)
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(OttoTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(OttoTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(OttoTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .accessibilityLabel("Start \(upNext)")
            }

            Spacer(minLength: 18)

            EclipseOrb(
                state: model.state,
                level: model.micBars.last ?? 0,
                size: model.briefCard == nil && model.planCard == nil ? 320 : 150
            )

            Spacer(minLength: 16)

            if let card = model.briefCard {
                BriefCardView(card: card) {
                    model.dismissBrief()
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: 400)
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

    /// The words of the current exchange only — no scrollback, no bubbles.
    @ViewBuilder
    private var dialogue: some View {
        if !model.signedIn {
            Button("Open Settings") {
                showingSettings = true
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Color.white, in: Capsule())
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
                    .foregroundStyle(OttoTheme.textTertiary)
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
                    Button {
                        model.confirmDraftTapped()
                    } label: {
                        Text("Send…")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(
                OttoTheme.surface,
                in: RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                    .stroke(OttoTheme.hairline, lineWidth: 1)
            )
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
                        .foregroundStyle(OttoTheme.textTertiary)
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
                        .foregroundStyle(OttoTheme.textTertiary)
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
                    Button {
                        model.confirmCalendarTapped()
                    } label: {
                        Text("Confirm")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(
                OttoTheme.surface,
                in: RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                    .stroke(OttoTheme.hairline, lineWidth: 1)
            )
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
                    .foregroundStyle(OttoTheme.textTertiary)
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
                    Button {
                        model.confirmPlanScheduleTapped()
                    } label: {
                        Text("Add all")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(
                OttoTheme.surface,
                in: RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                    .stroke(OttoTheme.hairline, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Controls: hub · mic · settings

    private var controlBar: some View {
        HStack {
            CircleIconButton(systemName: "square.grid.2x2") {
                Haptics.tap()
                showingHub = true
            }
            .accessibilityLabel("Hub")

            Spacer()

            MicButton(systemName: model.state == .idle ? "mic.fill" : "stop.fill") {
                Haptics.press()
                model.toggleVoice()
            }
            .disabled(!model.signedIn)
            .accessibilityLabel(model.state == .idle ? "Start voice conversation" : "Stop")

            Spacer()

            CircleIconButton(systemName: "gearshape") {
                Haptics.tap()
                showingSettings = true
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 34)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}
