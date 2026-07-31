import SwiftUI

/// The one conversation screen — Otto's stage.
///
/// Pure black, monochrome type, the eclipse orb as the idle centerpiece.
/// Transcript with no bubbles: your words small and muted, Otto's in white.
/// The text field stays permanently visible (voice is the default, never a
/// requirement), and a triple-tap anywhere toggles the debug overlay.
struct ConversationView: View {
    @Bindable var model: ConversationModel
    /// The Phase 0 debug screen, reused as settings: server URL + account.
    @Bindable var settings: DebugModel
    /// Everything Otto remembers — viewable, editable, deletable.
    @Bindable var memory: MemoryModel
    /// Lists and reminders, live-updated as Otto works.
    @Bindable var tasks: TasksModel
    @State private var showingSettings = false
    @State private var showingMemory = false
    @State private var showingTasks = false

    var body: some View {
        NavigationStack {
            transcript
                .background(OttoTheme.background)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        draftCard
                        statusStrip
                        composerBar
                    }
                    .background(OttoTheme.background)
                }
                .navigationTitle("Otto")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(OttoTheme.background, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.newConversation()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New conversation")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingTasks = true
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel("Tasks")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingMemory = true
                        } label: {
                            Image(systemName: "brain")
                        }
                        .accessibilityLabel("Memory")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        .overlay(alignment: .bottom) {
            if model.overlayVisible {
                DebugOverlayView(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .simultaneousGesture(
            TapGesture(count: 3).onEnded {
                withAnimation(.snappy) { model.toggleOverlay() }
            }
        )
        .sheet(isPresented: $showingSettings) {
            DebugView(model: settings)
        }
        .sheet(isPresented: $showingMemory) {
            MemoryView(model: memory)
        }
        .sheet(isPresented: $showingTasks) {
            TasksView(model: tasks)
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

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.entries.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                }
                ForEach(model.entries) { entry in
                    row(for: entry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 28) {
            if model.signedIn {
                Text("Lists, reminders, texts — just say it.")
                    .font(.footnote)
                    .foregroundStyle(OttoTheme.textTertiary)
                Text("What's first?")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(OttoTheme.textPrimary)
                EclipseOrb(
                    state: model.state,
                    level: model.micBars.last ?? 0,
                    size: 230
                )
                .padding(.vertical, 12)
            } else {
                EclipseOrb(state: .idle, level: 0, size: 180)
                    .padding(.top, 20)
                Text("Sign in to talk to Otto.")
                    .font(.callout)
                    .foregroundStyle(OttoTheme.textSecondary)
                Button("Open Settings") {
                    showingSettings = true
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Color.white, in: Capsule())
            }
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .font(.subheadline)
                .foregroundStyle(OttoTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 56)
                .opacity(entry.isFinal ? 1 : 0.6)
        case .otto:
            Text(entry.text)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(OttoTheme.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
                .textSelection(.enabled)
        case .notice:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(OttoTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Draft confirmation card

    /// Visible while a draft awaits confirmation — the tapped alternative to
    /// saying "yes". Send hands off to the system compose sheet.
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
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    // MARK: - Status strip

    /// Fixed-height strip so the layout never jumps between states: waveform
    /// while the mic is capturing, breathing dots while thinking, dimmed
    /// waveform while Otto speaks (the mic stays hot for barge-in).
    private var statusStrip: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .idle:
                EmptyView()
            case .listening:
                WaveformView(levels: model.micBars)
                Text("Listening")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
            case .thinking:
                ThinkingIndicator()
            case .speaking:
                WaveformView(levels: model.micBars, dimmed: true)
                Text("Speak to interrupt")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textTertiary)
            }
        }
        .frame(height: model.state == .idle ? 0 : 40)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.2), value: model.state)
    }

    // MARK: - Composer

    private var composerBar: some View {
        HStack(spacing: 12) {
            TextField(
                "",
                text: $model.composerText,
                prompt: Text("Message Otto…").foregroundStyle(OttoTheme.textTertiary),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(OttoTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                OttoTheme.surface,
                in: RoundedRectangle(cornerRadius: OttoTheme.fieldRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OttoTheme.fieldRadius, style: .continuous)
                    .stroke(OttoTheme.hairline, lineWidth: 1)
            )
            .submitLabel(.send)
            .onSubmit { model.sendTyped() }

            if hasComposerText {
                CircleIconButton(systemName: "arrow.up", prominent: true) {
                    model.sendTyped()
                }
                .disabled(!model.signedIn)
                .accessibilityLabel("Send")
            } else {
                CircleIconButton(
                    systemName: model.state == .idle ? "mic" : "stop.fill",
                    prominent: model.state != .idle
                ) {
                    model.toggleVoice()
                }
                .disabled(!model.signedIn)
                .accessibilityLabel(model.state == .idle ? "Start voice conversation" : "Stop")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.15), value: hasComposerText)
    }

    private var hasComposerText: Bool {
        !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
