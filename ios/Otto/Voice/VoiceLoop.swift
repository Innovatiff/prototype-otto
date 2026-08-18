import AVFoundation
import Foundation

// MARK: - Public surface

enum VoiceLoopState: String, Sendable {
    case idle
    case listening
    case thinking
    case speaking
}

/// The per-turn latency ledger. Every stage the 800ms budget governs.
struct TurnTimings: Sendable {
    /// Last voiced instant before the endpoint (nil for typed turns).
    var speechEndedAt: Date?
    var endpointDetectedAt: Date?
    var requestSentAt: Date?
    var firstTokenAt: Date?
    var firstClauseAt: Date?
    var firstAudioAt: Date?

    /// The governing number: speech end to first audible sound.
    var totalLatencyMs: Double? {
        guard let start = speechEndedAt, let end = firstAudioAt else { return nil }
        return end.timeIntervalSince(start) * 1000
    }

    var endpointMs: Double? { intervalMs(speechEndedAt, endpointDetectedAt) }
    var networkToFirstTokenMs: Double? { intervalMs(requestSentAt, firstTokenAt) }
    var firstClauseMs: Double? { intervalMs(firstTokenAt, firstClauseAt) }
    var ttsToFirstAudioMs: Double? { intervalMs(firstClauseAt, firstAudioAt) }
    /// For typed turns, where there is no speech end to measure from.
    var requestToFirstAudioMs: Double? { intervalMs(requestSentAt, firstAudioAt) }

    private func intervalMs(_ from: Date?, _ to: Date?) -> Double? {
        guard let from, let to else { return nil }
        return to.timeIntervalSince(from) * 1000
    }
}

/// Where a running plan generation is, per the server's streamed events.
enum PlanProgressStage: String, Sendable {
    case designing
    case scheduling
}

/// Everything the conversation UI needs, on one lossless stream. Mic levels
/// ride a separate lossy stream so a slow UI can never drop a transcript.
enum ConversationEvent: Sendable {
    case state(VoiceLoopState)
    case userPartial(String)
    case userFinal(String)
    case ottoToken(String)
    case ottoDone
    /// A task the server created or updated this turn — drives reminder
    /// scheduling now, and the task UI later.
    case task(OttoTask)
    /// A message draft from the server. Nothing is sent; the client reads it
    /// back aloud and hands off to the system compose sheet.
    case draft(recipientName: String, body: String)
    /// A proposed calendar change. The model confirms, writes via EventKit,
    /// and reports success only after read-back.
    case calendarProposal(CalendarProposal)
    /// A final utterance claimed by an armed capture (draft confirmations)
    /// instead of becoming a server turn.
    case capturedUtterance(String)
    /// The utterance asked for the morning brief — the model runs the brief
    /// flow (calendar + POST /brief) instead of a server turn.
    case briefRequested
    /// A final utterance heard while guidance listening is active. Never a
    /// server turn from here: the guidance runtime classifies it on device
    /// (commands respond instantly) and only off-script questions escalate.
    case guidanceUtterance(String)
    /// Plan generation progress — drives the on-screen state text
    /// ("Designing your week…"), never a spinner.
    case planProgress(PlanProgressStage)
    /// The finished plan, for the SCREEN. The voice gets only a summary;
    /// the full plan is never spoken.
    case planReady(Plan)
    /// Generation failed server-side; the UI clears its progress state.
    case planFailed
    /// The server's effective conversation session for the last turn — the
    /// model persists it so a relaunch resumes the same conversation.
    case session(String)
    case timing(TurnTimings)
    case notice(String)
}

/// Snapshot for the debug overlay.
struct VoiceDebugSnapshot: Sendable {
    var state: VoiceLoopState
    var bargeThresholdDb: Float
    var lastMicLevelDb: Float
    var voiceProcessingEnabled: Bool
    var clipPlayLatencyMs: Double?
    /// Adaptive endpointing readouts: the live silence threshold and the
    /// learned incomplete-utterance pause window.
    var endpointThresholdDb: Float
    var pauseWindowMs: Double
    var timings: TurnTimings
}

// MARK: - Mic level monitor (speaking phase)

/// Owns the mic tap while Otto speaks — the transcriber's tap is gone by
/// then, but the mic must stay hot for barge-in. Taps are strictly
/// sequential: VoiceLoop stops this monitor before the transcriber starts
/// and vice versa; the input bus only ever carries one tap.
@AudioActor
final class MicLevelMonitor {

    struct Sample: Sendable {
        let db: Float
        let durationMs: Double
    }

    private let audioSession: AudioSessionController
    private var continuation: AsyncStream<Sample>.Continuation?
    private var installed = false
    private var active = false
    private var restartTask: Task<Void, Never>?

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
    }

    /// Single consumer; lossy — a dropped level sample is meaningless.
    func samples() -> AsyncStream<Sample> {
        let (stream, newContinuation) = AsyncStream.makeStream(of: Sample.self, bufferingPolicy: .bufferingNewest(8))
        continuation = newContinuation
        return stream
    }

    func start() {
        active = true
        watchRestartsIfNeeded()
        installTap()
    }

    func stop() {
        active = false
        removeTap()
    }

    private func installTap() {
        guard active, !installed, let continuation else { return }
        let inputNode = audioSession.engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            // The engine treats the requested size as advisory and often
            // delivers far bigger buffers; measure what actually arrived or
            // the barge sustain accumulates several times too slowly.
            let durationMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
            continuation.yield(Sample(db: Transcriber.rmsDb(of: buffer), durationMs: durationMs))
        }
        installed = true
    }

    private func removeTap() {
        guard installed else { return }
        audioSession.engine.inputNode.removeTap(onBus: 0)
        installed = false
    }

    private func watchRestartsIfNeeded() {
        guard restartTask == nil else { return }
        let restarts = audioSession.engineRestartedStream()
        restartTask = Task { @AudioActor in
            for await _ in restarts {
                // Formats may have changed; rebuild the tap if we own the bus.
                self.removeTap()
                self.installTap()
            }
        }
    }
}

// MARK: - VoiceLoop

/// The orchestrator: idle → listening → thinking → speaking → (listening |
/// idle). Its own actor, as specified — every mutable bit of conversation
/// state lives behind this isolation, and the audio components stay behind
/// AudioActor.
///
/// The mic stays active during `speaking` (via MicLevelMonitor); sustained
/// input energy above the barge threshold interrupts Otto: 120ms fade, SSE
/// cancelled, partial response discarded, straight back to listening.
actor VoiceLoop {

    // MARK: Tunables

    /// Barge trigger: mic energy must exceed this for the sustain window.
    /// Must sit ABOVE the post-echo-cancellation residual of Otto's own
    /// voice (typically < -45dB with voice processing on) and below normal
    /// speech at arm's length (≈ -35..-20dB). Tune from the debug overlay.
    private(set) var bargeThresholdDb: Float = -30

    /// How long input must stay above threshold before barging.
    private(set) var bargeSustainMs: Double = 200

    // MARK: State

    private(set) var state: VoiceLoopState = .idle

    private var conversationActive = false
    private var resumeAfterInterruption = false
    private var captureNextFinalUtterance = false
    /// Guided-session listening: every final utterance emits as
    /// .guidanceUtterance and listening restarts — never a server turn.
    private var guidanceModeActive = false
    private var turnGeneration = 0
    private var timings = TurnTimings()
    private var lastMicLevelDb: Float = -120
    private var bargeAccumulatedMs: Double = 0

    // MARK: Components (all AudioActor-isolated)

    private let auth: any AuthProvider
    private var serverURL: URL?
    private var sessionId: String?
    /// Today's and tomorrow's events, refreshed by the model; rides on every
    /// turn so schedule questions need no tool call.
    private var calendarContext: [CalendarEvent] = []
    private var locale: Locale?

    private var audioSession: AudioSessionController?
    private var transcriber: Transcriber?
    private var speaker: (any Speaker)?
    private var instrumentation: (any SpeakerInstrumentation)?
    private var clipCache: ClipCache?
    private var micMonitor: MicLevelMonitor?

    // MARK: Turn plumbing

    private var currentClauseBuffer: ClauseBuffer?
    private var turnTask: Task<Void, Never>?
    private var pipeTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?

    private var eventContinuation: AsyncStream<ConversationEvent>.Continuation?
    private var micLevelContinuation: AsyncStream<Float>.Continuation?

    init(auth: any AuthProvider) {
        self.auth = auth
    }

    // MARK: - Public API

    func configure(serverURL: URL) {
        self.serverURL = serverURL
    }

    /// Seeds (or clears) the conversation session to continue server-side.
    /// After each turn the loop adopts whatever session the server reports,
    /// so callers only need this at launch and on explicit reset.
    func setSession(_ id: String?) {
        sessionId = id
    }

    /// Arms a single-shot claim on the NEXT final utterance: it is emitted as
    /// .capturedUtterance and never becomes a server turn. The draft flow
    /// uses this for spoken confirmations.
    func armUtteranceCapture() {
        captureNextFinalUtterance = true
    }

    func disarmUtteranceCapture() {
        captureNextFinalUtterance = false
    }

    /// Ambient calendar context for the next turns; [] when unavailable.
    func setCalendarContext(_ events: [CalendarEvent]) {
        calendarContext = events
    }

    /// Speaks locally — no server turn — through the same speaker pipeline,
    /// returning when playback finishes. Used for draft read-backs and flow
    /// prompts, where the exact words must be deterministic.
    func announce(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let components = try await ensureComponents()
            try await components.session.start()
        } catch {
            emit(.notice("Audio unavailable: \(error.localizedDescription)"))
            return
        }
        if state == .listening, let transcriber {
            await transcriber.cancel()
        }
        if state == .speaking || state == .thinking {
            await abortTurn(fade: true)
        }
        setState(.speaking)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        continuation.yield(trimmed)
        continuation.finish()
        if let speaker {
            try? await speaker.speak(stream)
        }
        if conversationActive || guidanceModeActive {
            await startListening()
        } else {
            setState(.idle)
        }
    }

    /// Guidance listening: the mic stays hot for the whole session, and
    /// EVERY final utterance is emitted as .guidanceUtterance — nothing
    /// becomes a server turn from the loop itself. First run installs the
    /// on-device model exactly like a conversation start.
    func startGuidanceListening() async {
        guidanceModeActive = true
        guard await AudioSessionController.requestMicrophonePermission() else {
            emit(.notice("Microphone access is required for guided sessions."))
            guidanceModeActive = false
            return
        }
        do {
            let components = try await ensureComponents()
            try await components.session.start()
            if locale == nil {
                emit(.notice("Preparing on-device transcription…"))
                locale = try await Transcriber.ensureModelInstalled()
            }
        } catch {
            emit(.notice("Voice unavailable: \(error.localizedDescription)"))
            guidanceModeActive = false
            return
        }
        await startListening()
    }

    /// Ends guidance listening. If no conversation is active either, the
    /// transcriber stops and the loop goes idle (the audio session itself is
    /// governed by the guidance hold, not by this).
    func stopGuidanceListening() async {
        guidanceModeActive = false
        if !conversationActive {
            if let transcriber {
                await transcriber.cancel()
            }
            setState(.idle)
        }
    }

    /// Guided-session audio keepalive. On: the audio session starts (if
    /// needed) and stays active — conversation teardown can no longer
    /// deactivate it — so timers and cues survive the screen locking and
    /// app switches. Off: the hold lifts; the next natural stop releases
    /// audio as usual.
    func setGuidanceHold(_ on: Bool) async {
        if on {
            do {
                let components = try await ensureComponents()
                try await components.session.beginGuidanceHold()
            } catch {
                emit(.notice("Audio unavailable: \(error.localizedDescription)"))
            }
        } else if let audioSession {
            await audioSession.endGuidanceHold()
            if state == .idle {
                await audioSession.stop()
            }
        }
    }

    /// Plays one cached guidance clip through the speaker pipeline — the
    /// guided session's zero-latency vocabulary. No state churn: guidance
    /// owns the audio while a session runs.
    func playClip(_ clip: CachedClip) async {
        do {
            let components = try await ensureComponents()
            try await components.session.start()
        } catch {
            return
        }
        if let speaker {
            try? await speaker.speak(clip: clip)
        }
    }

    func setBargeThreshold(_ db: Float) {
        bargeThresholdDb = db
    }

    /// Lossless event stream for the conversation UI. Single consumer.
    func events() -> AsyncStream<ConversationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConversationEvent.self)
        eventContinuation = continuation
        return stream
    }

    /// Lossy mic-level stream for the waveform. Single consumer.
    func micLevels() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(8))
        micLevelContinuation = continuation
        return stream
    }

    func debugSnapshot() async -> VoiceDebugSnapshot {
        VoiceDebugSnapshot(
            state: state,
            bargeThresholdDb: bargeThresholdDb,
            lastMicLevelDb: lastMicLevelDb,
            voiceProcessingEnabled: await audioSession?.isVoiceProcessingEnabled ?? false,
            clipPlayLatencyMs: await clipCache?.lastPlayLatencyMs,
            endpointThresholdDb: await transcriber?.silenceThresholdDb ?? -44,
            pauseWindowMs: await transcriber?.pauseWindowMs ?? 1100,
            timings: timings
        )
    }

    /// idle → listening. Requests mic permission, starts the engine, starts
    /// the transcriber. The conversation then cycles on its own until
    /// stopConversation() or an unrecoverable interruption.
    func startConversation() async {
        guard state == .idle else { return }
        conversationActive = true

        guard await AudioSessionController.requestMicrophonePermission() else {
            emit(.notice("Microphone access is required for voice. You can still type."))
            conversationActive = false
            return
        }
        do {
            let components = try await ensureComponents()
            try await components.session.start()
            if locale == nil {
                // First run downloads the on-device model; show why we wait.
                emit(.notice("Preparing on-device transcription…"))
                locale = try await Transcriber.ensureModelInstalled()
            }
        } catch {
            emit(.notice("Voice unavailable: \(error.localizedDescription)"))
            conversationActive = false
            return
        }
        await startListening()
    }

    /// Any state → idle. Everything torn down, audio session released.
    func stopConversation() async {
        conversationActive = false
        await abortTurn(fade: true)
        if let transcriber {
            await transcriber.cancel()
        }
        if let audioSession {
            await audioSession.stop()
        }
        setState(.idle)
    }

    /// The typed path — identical spoken response pipeline, no transcription.
    /// Works with or without an active voice conversation.
    func submitText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let components = try await ensureComponents()
            // Playback needs the engine even when the mic was never granted.
            try await components.session.start()
        } catch {
            emit(.notice("Audio unavailable: \(error.localizedDescription)"))
            return
        }
        if state == .listening, let transcriber {
            await transcriber.cancel()
        }
        if state == .speaking || state == .thinking {
            await abortTurn(fade: true)
        }
        emit(.userFinal(trimmed))
        await runTurn(transcript: trimmed, speechEndedAt: nil, endpointAt: nil)
    }

    // MARK: - Components

    private struct Components {
        let session: AudioSessionController
        let transcriber: Transcriber
    }

    private func ensureComponents() async throws -> Components {
        if let audioSession, let transcriber {
            return Components(session: audioSession, transcriber: transcriber)
        }
        let session = await AudioSessionController()
        let cache = await ClipCache(audioSession: session)
        let speakerImpl = await SystemSpeaker(audioSession: session, clipCache: cache)
        let newTranscriber = await Transcriber(audioSession: session)
        let monitor = await MicLevelMonitor(audioSession: session)

        audioSession = session
        clipCache = cache
        speaker = speakerImpl
        instrumentation = speakerImpl
        transcriber = newTranscriber
        micMonitor = monitor

        // Persistent consumers — live for the app's lifetime.
        let transcriberEvents = await newTranscriber.events()
        Task {
            for await event in transcriberEvents {
                self.handleTranscriberEvent(event)
            }
        }
        let listeningLevels = await newTranscriber.levels()
        Task {
            for await db in listeningLevels {
                self.relayListeningLevel(db)
            }
        }
        let speakingLevels = await monitor.samples()
        Task {
            for await sample in speakingLevels {
                await self.processBargeSample(sample)
            }
        }
        let sessionStates = await session.stateStream()
        Task {
            for await sessionState in sessionStates {
                await self.handleSessionState(sessionState)
            }
        }
        // First-launch clip rendering happens off the critical path.
        Task {
            await cache.prepare()
        }
        return Components(session: session, transcriber: newTranscriber)
    }

    // MARK: - Listening

    private func startListening() async {
        guard conversationActive || guidanceModeActive, let transcriber, let locale else {
            setState(.idle)
            return
        }
        setState(.listening)
        do {
            try await transcriber.start(locale: locale)
        } catch {
            emit(.notice("Could not start listening: \(error.localizedDescription)"))
            setState(.idle)
        }
    }

    private func handleTranscriberEvent(_ event: TranscriberEvent) {
        switch event {
        case .partial(let text):
            emit(.userPartial(text))
        case .endpoint(let transcript, let speechEndedAt):
            guard state == .listening else { return }
            emit(.userFinal(transcript))
            if guidanceModeActive {
                // The guidance runtime owns every utterance while a session
                // runs — commands classify on device, questions escalate
                // from there (Step 6). Keep listening either way.
                emit(.guidanceUtterance(transcript))
                Task {
                    await self.startListening()
                }
                return
            }
            if captureNextFinalUtterance {
                // Claimed by the draft flow — no server turn; keep listening.
                captureNextFinalUtterance = false
                emit(.capturedUtterance(transcript))
                Task {
                    await self.startListening()
                }
                return
            }
            if BriefTriggers.matches(transcript) {
                // The brief needs the on-device calendar — never a server turn.
                emit(.briefRequested)
                Task {
                    await self.startListening()
                }
                return
            }
            Task {
                await self.runTurn(
                    transcript: transcript,
                    speechEndedAt: speechEndedAt,
                    endpointAt: Date()
                )
            }
        }
    }

    private func relayListeningLevel(_ db: Float) {
        lastMicLevelDb = db
        if state == .listening {
            micLevelContinuation?.yield(db)
        }
    }

    // MARK: - The turn

    private func runTurn(transcript: String, speechEndedAt: Date?, endpointAt: Date?) async {
        guard let serverURL else {
            emit(.notice("No server URL configured."))
            await startListening()
            return
        }
        turnGeneration += 1
        let generation = turnGeneration
        bargeAccumulatedMs = 0

        timings = TurnTimings()
        timings.speechEndedAt = speechEndedAt
        timings.endpointDetectedAt = endpointAt

        setState(.thinking)

        let clauseBuffer = ClauseBuffer()
        currentClauseBuffer = clauseBuffer

        // Pipe clause units to the speaker, timestamping the first.
        let (unitStream, unitContinuation) = AsyncStream.makeStream(of: String.self)
        pipeTask = Task {
            for await unit in clauseBuffer.units {
                self.noteFirstClause()
                unitContinuation.yield(unit)
            }
            unitContinuation.finish()
        }

        timings.requestSentAt = Date()
        let turn = TurnRequest(
            turnId: UUID().uuidString,
            text: transcript,
            clientTimestamp: Date(),
            timezone: TimeZone.current.identifier,
            sessionId: sessionId,
            events: calendarContext.isEmpty ? nil : calendarContext
        )
        let client = APIClient(baseURL: serverURL, auth: auth)
        turnTask = Task {
            await self.consumeTurnStream(client: client, turn: turn, clauseBuffer: clauseBuffer, unitStream: unitStream, generation: generation)
        }
    }

    private func consumeTurnStream(
        client: APIClient,
        turn: TurnRequest,
        clauseBuffer: ClauseBuffer,
        unitStream: AsyncStream<String>,
        generation: Int
    ) async {
        do {
            for try await event in client.converse(turn) {
                guard generation == turnGeneration else { return }
                switch event.type {
                case .token:
                    let token = event.data?.stringValue ?? ""
                    if timings.firstTokenAt == nil {
                        timings.firstTokenAt = Date()
                        await enterSpeaking(unitStream: unitStream, generation: generation)
                    }
                    clauseBuffer.ingest(token)
                    emit(.ottoToken(token))
                case .done:
                    if let id = event.data?.objectValue?["sessionId"]?.stringValue {
                        sessionId = id
                        emit(.session(id))
                    }
                case .error:
                    emit(.notice("Server error: \(event.data?.stringValue ?? "unknown")"))
                case .taskCreated, .taskUpdated:
                    if let task = event.data?.decoded(as: OttoTask.self) {
                        emit(.task(task))
                    }
                case .draft:
                    if let payload = event.data?.objectValue,
                       let recipientName = payload["recipientName"]?.stringValue,
                       let body = payload["body"]?.stringValue {
                        emit(.draft(recipientName: recipientName, body: body))
                    }
                case .calendarProposal:
                    if let proposal = event.data?.decoded(as: CalendarProposal.self) {
                        emit(.calendarProposal(proposal))
                    }
                case .planProgress:
                    if let raw = event.data?.objectValue?["stage"]?.stringValue,
                       let stage = PlanProgressStage(rawValue: raw) {
                        emit(.planProgress(stage))
                    }
                case .planReady:
                    // data = { plan, plansCreatedThisMonth } — the meter
                    // rides the response for the UI to show later (Phase 7).
                    if let plan = event.data?.objectValue?["plan"]?.decoded(as: Plan.self) {
                        emit(.planReady(plan))
                    }
                case .planFailed:
                    emit(.planFailed)
                }
            }
            clauseBuffer.finish()
        } catch is CancellationError {
            clauseBuffer.cancel()
            return
        } catch {
            emit(.notice("Request failed: \(error.localizedDescription)"))
            clauseBuffer.finish()
        }
        await finishTurn(generation: generation)
    }

    private func enterSpeaking(unitStream: AsyncStream<String>, generation: Int) async {
        guard generation == turnGeneration else { return }
        setState(.speaking)
        // THE MIC STAYS ACTIVE: the monitor owns the tap while Otto talks.
        if let micMonitor {
            await micMonitor.start()
        }
        speakTask = Task {
            await self.runSpeaker(unitStream)
        }
    }

    private func runSpeaker(_ unitStream: AsyncStream<String>) async {
        guard let speaker else { return }
        do {
            try await speaker.speak(unitStream)
        } catch {
            // SystemSpeaker is itself the fallback synthesizer and never
            // throws; a future premium speaker failing lands here, and
            // silence is the worst failure — say so at minimum.
            emit(.notice("Speech output failed: \(error.localizedDescription)"))
        }
    }

    private func noteFirstClause() {
        if timings.firstClauseAt == nil {
            timings.firstClauseAt = Date()
        }
    }

    private func finishTurn(generation: Int) async {
        guard generation == turnGeneration else { return }
        if let speakTask {
            await speakTask.value
        }
        speakTask = nil
        pipeTask = nil
        turnTask = nil
        currentClauseBuffer = nil

        if let instrumentation {
            timings.firstAudioAt = await instrumentation.lastFirstAudioAt
        }
        emit(.timing(timings))
        emit(.ottoDone)
        logTurn()

        if let micMonitor {
            await micMonitor.stop()
        }
        guard generation == turnGeneration else { return }
        if conversationActive {
            await startListening()
        } else {
            setState(.idle)
        }
    }

    // MARK: - Barge-in

    private func processBargeSample(_ sample: MicLevelMonitor.Sample) async {
        lastMicLevelDb = sample.db
        guard state == .speaking else {
            bargeAccumulatedMs = 0
            return
        }
        micLevelContinuation?.yield(sample.db)

        if sample.db > bargeThresholdDb {
            bargeAccumulatedMs += sample.durationMs
            if bargeAccumulatedMs >= bargeSustainMs {
                bargeAccumulatedMs = 0
                await bargeIn()
            }
        } else {
            bargeAccumulatedMs = 0
        }
    }

    /// The user talked over Otto. Stop (fade), cancel, discard, listen.
    private func bargeIn() async {
        guard state == .speaking else { return }
        emit(.notice("Interrupted."))
        await abortTurn(fade: true)
        emit(.timing(timings))
        if conversationActive {
            await startListening()
        }
    }

    /// Tears down the in-flight turn. The partial response is discarded —
    /// resuming half a thought sounds worse than starting over.
    private func abortTurn(fade: Bool) async {
        turnGeneration += 1
        turnTask?.cancel()
        turnTask = nil
        currentClauseBuffer?.cancel()
        currentClauseBuffer = nil
        if let speaker, fade {
            await speaker.stopImmediately()
        }
        if let speakTask {
            await speakTask.value
        }
        speakTask = nil
        pipeTask = nil
        if let micMonitor {
            await micMonitor.stop()
        }
    }

    // MARK: - Interruptions (calls, Siri, alarms)

    private func handleSessionState(_ sessionState: AudioSessionState) async {
        switch sessionState {
        case .interrupted:
            guard conversationActive else { return }
            resumeAfterInterruption = true
            // No fade: the system already silenced our output.
            await abortTurn(fade: false)
            if let transcriber {
                await transcriber.cancel()
            }
            setState(.idle)
        case .active:
            if conversationActive, resumeAfterInterruption, state == .idle {
                resumeAfterInterruption = false
                await startListening()
            }
        case .inactive:
            break
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: VoiceLoopState) {
        guard newState != state else { return }
        state = newState
        emit(.state(newState))
    }

    private func emit(_ event: ConversationEvent) {
        eventContinuation?.yield(event)
    }

    private func logTurn() {
        let total = timings.totalLatencyMs.map { String(format: "%.0f", $0) } ?? "n/a"
        let network = timings.networkToFirstTokenMs.map { String(format: "%.0f", $0) } ?? "n/a"
        let clause = timings.firstClauseMs.map { String(format: "%.0f", $0) } ?? "n/a"
        let tts = timings.ttsToFirstAudioMs.map { String(format: "%.0f", $0) } ?? "n/a"
        print("voiceloop_turn total=\(total)ms network=\(network)ms clause=\(clause)ms tts=\(tts)ms")
    }
}
