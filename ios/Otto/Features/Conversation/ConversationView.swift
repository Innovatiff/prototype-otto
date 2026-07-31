import SwiftUI

/// The one conversation screen.
///
/// Transcript in the middle, live status strip above the bottom bar, and a
/// permanently visible text field — voice is the default, never a
/// requirement. Triple-tap anywhere toggles the debug overlay.
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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        draftCard
                        statusStrip
                        composerBar
                    }
                    .background(.bar)
                }
                .navigationTitle("Otto")
                .navigationBarTitleDisplayMode(.inline)
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
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.entries.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
                ForEach(model.entries) { entry in
                    row(for: entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.signedIn {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Tap the mic and start talking,\nor type below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 12) {
                Text("Sign in to talk to Otto.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    showingSettings = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(entry.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(entry.isFinal ? 1 : 0.65)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .otto:
            Text(entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 32)
                .textSelection(.enabled)
        case .notice:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Draft confirmation card

    /// Visible while a draft awaits confirmation — the tapped alternative to
    /// saying "yes". Send hands off to the system compose sheet.
    @ViewBuilder
    private var draftCard: some View {
        if case .confirming(let request) = model.draftStage {
            VStack(alignment: .leading, spacing: 6) {
                Text("Text to \(request.recipientName)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(request.body)
                    .font(.callout)
                    .lineLimit(4)
                HStack {
                    Button("Cancel", role: .cancel) {
                        model.cancelDraftTapped()
                    }
                    Spacer()
                    Button("Send…") {
                        model.confirmDraftTapped()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
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
                    .foregroundStyle(.secondary)
            case .thinking:
                ThinkingIndicator()
            case .speaking:
                WaveformView(levels: model.micBars, dimmed: true)
                Text("Speak to interrupt")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: model.state == .idle ? 0 : 40)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.2), value: model.state)
    }

    // MARK: - Composer

    private var composerBar: some View {
        HStack(spacing: 10) {
            TextField("Message Otto…", text: $model.composerText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .submitLabel(.send)
                .onSubmit { model.sendTyped() }

            if hasComposerText {
                Button {
                    model.sendTyped()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!model.signedIn)
                .accessibilityLabel("Send")
            } else {
                Button {
                    model.toggleVoice()
                } label: {
                    Image(systemName: model.state == .idle ? "mic.circle.fill" : "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.state == .idle ? AnyShapeStyle(.tint) : AnyShapeStyle(.red))
                }
                .disabled(!model.signedIn)
                .accessibilityLabel(model.state == .idle ? "Start voice conversation" : "Stop")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.15), value: hasComposerText)
    }

    private var hasComposerText: Bool {
        !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
