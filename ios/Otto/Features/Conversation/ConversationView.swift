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
    @State private var showingSettings = false
    @State private var showingHub = false

    var body: some View {
        VStack(spacing: 0) {
            stage
            statusCaption
            draftCard
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
            HubView(tasks: tasks, memory: memory)
        }
        .sheet(isPresented: $showingSettings) {
            DebugView(model: settings, onBriefScheduleChange: { enabled, hour, minute in
                model.setBriefSchedule(enabled: enabled, hour: hour, minute: minute)
            })
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

            Spacer(minLength: 18)

            EclipseOrb(
                state: model.state,
                level: model.micBars.last ?? 0,
                size: model.briefCard == nil ? 320 : 150
            )

            Spacer(minLength: 16)

            if let card = model.briefCard {
                BriefCardView(card: card) {
                    model.dismissBrief()
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
        .font(.caption)
        .frame(height: 26)
        .animation(.snappy(duration: 0.2), value: model.state)
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

    // MARK: - Controls: hub · mic · settings

    private var controlBar: some View {
        HStack {
            CircleIconButton(systemName: "square.grid.2x2") {
                showingHub = true
            }
            .accessibilityLabel("Hub")

            Spacer()

            MicButton(systemName: model.state == .idle ? "mic.fill" : "stop.fill") {
                model.toggleVoice()
            }
            .disabled(!model.signedIn)
            .accessibilityLabel(model.state == .idle ? "Start voice conversation" : "Stop")

            Spacer()

            CircleIconButton(systemName: "gearshape") {
                showingSettings = true
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 34)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}
