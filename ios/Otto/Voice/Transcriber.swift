import AVFoundation
import Foundation
import Speech

/// What the transcriber emits. `endpoint` is the `transcriptionDidEndpoint`
/// event: it fires exactly once per listening session and carries the final
/// transcript plus the instant speech actually stopped (for latency math).
enum TranscriberEvent: Sendable {
    case partial(String)
    case endpoint(transcript: String, speechEndedAt: Date)
}

enum TranscriberError: Error, LocalizedError {
    case localeNotSupported
    case analyzerFormatUnavailable
    case notStarted

    var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            return "On-device transcription does not support this language."
        case .analyzerFormatUnavailable:
            return "The speech analyzer offered no compatible audio format."
        case .notStarted:
            return "The transcriber is not running."
        }
    }
}

/// A mic buffer plus its energy, crossing from the audio render thread into
/// the AudioActor domain.
///
/// `@unchecked Sendable` is justified narrowly: the tap hands us a fresh
/// buffer per callback, we read it on exactly one consumer (the AudioActor
/// chunk loop), and nothing retains it afterward.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let energyDb: Float
    let at: Date
}

/// On-device streaming transcription (SpeechAnalyzer + SpeechTranscriber,
/// iOS 26) with Otto's own endpoint detection layered on top.
///
/// Endpointing is two-tier:
///   (a) the partial transcript reads as a complete utterance AND 350ms of
///       silence has elapsed — the fast path; or
///   (b) the transcript reads unfinished, and silence has outlasted the
///       LEARNED pause window (0.9–2s, adapted to this speaker's rhythm).
/// The silence threshold itself tracks the ambient noise floor.
///
/// Each listening session is single-shot: `start()` builds a fresh analyzer,
/// the endpoint (or `cancel()`) tears it down. The endpoint transcript is the
/// finalized text plus the last volatile partial — we do not wait for the
/// analyzer's finalization pass, which would spend latency the 150ms endpoint
/// budget does not have.
@AudioActor
final class Transcriber {

    // MARK: - Tunables

    /// Endpointing is two-tier and adaptive:
    ///   - an utterance that READS complete fires after a short silence;
    ///   - one that reads unfinished ("I don't…") gets a much wider window,
    ///     and that window is LEARNED from this speaker: every pause they
    ///     talk through stretches it (persisted across launches);
    ///   - the silence threshold self-calibrates to the ambient floor, so a
    ///     soft speaker in a quiet room is not mistaken for silence.

    /// Silence required after a semantically complete utterance.
    var semanticSilenceMs: Double = 350

    /// Bounds for the learned incomplete-utterance window.
    static let minPauseWindowMs: Double = 900
    static let maxPauseWindowMs: Double = 2000

    /// Silence required when the transcript reads unfinished. Learned from
    /// the speaker's own mid-sentence pauses; persisted.
    private(set) var pauseWindowMs: Double

    /// Mic energy below this (dBFS) counts as silence: the tracked ambient
    /// floor plus a margin, clamped so neither a dead-quiet room nor a noisy
    /// one can push it somewhere absurd.
    var silenceThresholdDb: Float {
        min(-35, max(-55, ambientFloorDb + 12))
    }

    private var ambientFloorDb: Float = -60
    private var sessionMaxPauseMs: Double = 0
    private static let pauseWindowKey = "otto.voice.learnedPauseMs"

    // MARK: - State

    private let audioSession: AudioSessionController

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var tapInstalled = false

    private var chunkTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    private var finalizedText = ""
    private var volatileText = ""
    private var speechEverDetected = false
    private var lastVoiceAt = Date()
    private var endpointFired = false
    private(set) var isRunning = false

    private var eventContinuation: AsyncStream<TranscriberEvent>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
        let stored = UserDefaults.standard.double(forKey: Self.pauseWindowKey)
        self.pauseWindowMs =
            stored >= Self.minPauseWindowMs ? min(stored, Self.maxPauseWindowMs) : 1100
    }

    /// Mic energy (dBFS) per chunk while listening — drives the waveform.
    /// Single consumer; lossy buffering, levels are display-only.
    func levels() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(8))
        levelContinuation = continuation
        return stream
    }

    // MARK: - Model assets

    /// Resolves the transcription locale and downloads the on-device model if
    /// anything is missing. Call once at app start (and show progress UI in
    /// a later phase — the download can be tens of megabytes).
    static func ensureModelInstalled() async throws -> Locale {
        let preferred = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        guard let locale = preferred ?? fallback else {
            throw TranscriberError.localeNotSupported
        }
        try await installAssetsIfNeeded(for: locale)
        return locale
    }

    /// Asks the system for whatever assets our exact module configuration
    /// still needs. Never gate this on `installedLocales`: the language
    /// models are shared system assets that iOS deletes under disk pressure,
    /// so "installed once" guarantees nothing. When everything is present the
    /// request comes back nil and this returns immediately.
    private static func installAssetsIfNeeded(for locale: Locale) async throws {
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Must match the live transcriber's configuration in start() so
            // the asset check covers what we actually run.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Events

    /// Single-consumer stream of partials and the endpoint. VoiceLoop owns it.
    func events() -> AsyncStream<TranscriberEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            eventContinuation = continuation
        }
    }

    /// The transcript so far (finalized + volatile), for UI display.
    func currentTranscript() -> String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lifecycle

    func start(locale: Locale) async throws {
        guard !isRunning else { return }

        finalizedText = ""
        volatileText = ""
        speechEverDetected = false
        endpointFired = false
        lastVoiceAt = Date()
        sessionMaxPauseMs = 0

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // volatileResults: continuous partials; fastResults: bias toward
            // latency over polish. Both serve the 800ms budget.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        var bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        if bestFormat == nil {
            // No format means the language model is not actually available —
            // the system may have evicted it since the last check. One
            // install-and-retry heals that without user intervention.
            try await Self.installAssetsIfNeeded(for: locale)
            bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        guard let format = bestFormat else {
            throw TranscriberError.analyzerFormatUnavailable
        }
        analyzerFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputSequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = builder
        try await analyzer.start(inputSequence: inputSequence)

        let (chunks, chunkContinuation) = AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        pendingChunkContinuation = chunkContinuation
        try installTap()

        chunkTask = Task { @AudioActor in
            await self.consumeChunks(chunks)
        }
        resultsTask = Task { @AudioActor in
            await self.consumeResults(of: transcriber)
        }
        // A route change rebuilds the engine and may change the mic format;
        // reinstall the tap against whatever the hardware now provides.
        let restarts = audioSession.engineRestartedStream()
        restartTask = Task { @AudioActor in
            for await _ in restarts {
                guard self.isRunning else { continue }
                self.reinstallTapAfterRestart()
            }
        }

        isRunning = true
    }

    /// Cancels mid-stream: tears everything down and emits nothing.
    func cancel() {
        teardown()
    }

    // MARK: - Mic tap

    /// Feeds the current listening session's chunk stream; kept so a
    /// mid-session tap reinstall (route change) targets the same stream.
    private var pendingChunkContinuation: AsyncStream<AudioChunk>.Continuation?

    private func installTap() throws {
        guard let continuation = pendingChunkContinuation else {
            throw TranscriberError.notStarted
        }
        let inputNode = audioSession.engine.inputNode
        // Read the live format — voice processing changes it, and caching a
        // stale one raises an exception inside installTap.
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            throw TranscriberError.analyzerFormatUnavailable
        }
        if let analyzerFormat {
            converter = AVAudioConverter(from: micFormat, to: analyzerFormat)
        }
        // ~21ms per callback at 48kHz: the granularity of endpoint detection.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { @Sendable buffer, _ in
            // Audio render thread: compute energy, hand off, touch nothing else.
            let energy = Transcriber.rmsDb(of: buffer)
            continuation.yield(AudioChunk(buffer: buffer, energyDb: energy, at: Date()))
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        audioSession.engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func reinstallTapAfterRestart() {
        removeTap()
        // The chunk stream stays; only the tap and converter are rebuilt
        // against whatever format the new route provides.
        do {
            try installTap()
        } catch {
            print("Transcriber: tap reinstall after route change failed: \(error)")
        }
    }

    // MARK: - Chunk consumption (VAD + analyzer feed)

    private func consumeChunks(_ chunks: AsyncStream<AudioChunk>) async {
        for await chunk in chunks {
            guard isRunning else { break }
            levelContinuation?.yield(chunk.energyDb)
            feedAnalyzer(chunk.buffer)
            updateEndpointState(energyDb: chunk.energyDb, at: chunk.at)
        }
    }

    private func feedAnalyzer(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let analyzerFormat, let inputBuilder else { return }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else { return }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func updateEndpointState(energyDb: Float, at: Date) {
        guard !endpointFired else { return }

        trackAmbient(energyDb)

        if energyDb > silenceThresholdDb {
            if speechEverDetected {
                // A pause the user then talked through is their rhythm, not
                // an ending — remember the longest one.
                let gapMs = at.timeIntervalSince(lastVoiceAt) * 1000
                if gapMs >= 300 {
                    sessionMaxPauseMs = max(sessionMaxPauseMs, min(gapMs, Self.maxPauseWindowMs))
                }
            }
            speechEverDetected = true
            lastVoiceAt = at
            return
        }
        guard speechEverDetected else { return }

        let transcript = currentTranscript()
        guard !transcript.isEmpty else { return }

        let silenceMs = at.timeIntervalSince(lastVoiceAt) * 1000
        let window = Self.isSemanticallyComplete(transcript) ? semanticSilenceMs : pauseWindowMs
        if silenceMs >= window {
            fireEndpoint(transcript: transcript)
        }
    }

    /// Quiet chunks pull the floor down quickly; louder ones leak it up very
    /// slowly, so a noisy minute cannot permanently deafen the endpointer.
    private func trackAmbient(_ energyDb: Float) {
        if energyDb < ambientFloorDb + 6 {
            ambientFloorDb = 0.9 * ambientFloorDb + 0.1 * energyDb
        } else {
            ambientFloorDb = min(ambientFloorDb + 0.05, -45)
        }
    }

    /// Folds this session's observed pauses into the persistent window:
    /// growing readily, shrinking cautiously — cutting someone off costs far
    /// more than waiting an extra beat.
    private func adaptPauseWindow() {
        let target = min(Self.maxPauseWindowMs, max(Self.minPauseWindowMs, sessionMaxPauseMs + 300))
        let blended =
            target > pauseWindowMs
            ? 0.5 * pauseWindowMs + 0.5 * target
            : 0.9 * pauseWindowMs + 0.1 * target
        pauseWindowMs = min(Self.maxPauseWindowMs, max(Self.minPauseWindowMs, blended))
        UserDefaults.standard.set(pauseWindowMs, forKey: Self.pauseWindowKey)
    }

    private func fireEndpoint(transcript: String) {
        endpointFired = true
        adaptPauseWindow()
        let endedAt = lastVoiceAt
        eventContinuation?.yield(.endpoint(transcript: transcript, speechEndedAt: endedAt))
        teardown()
    }

    // MARK: - Results consumption

    private func consumeResults(of transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalizedText += text
                    volatileText = ""
                } else {
                    volatileText = text
                }
                if !endpointFired {
                    eventContinuation?.yield(.partial(currentTranscript()))
                }
            }
        } catch is CancellationError {
            // Normal teardown.
        } catch {
            // cancelAndFinishNow ends this sequence; anything else is logged
            // and the endpoint rules still apply to whatever text we have.
            print("Transcriber: results stream ended: \(error)")
        }
    }

    // MARK: - Semantic completion

    /// Words a trailing fragment hangs on — an utterance ending in one of
    /// these is mid-thought no matter how long the pause feels. Curation
    /// leans toward holding: an extra beat of patience is cheap, a
    /// mid-sentence cut is not.
    private static let continuationWords: Set<String> = [
        // conjunctions / prepositions / articles
        "and", "or", "but", "to", "the", "a", "an", "my", "your", "of", "in",
        "on", "at", "for", "with", "so", "then", "that", "if", "because",
        "also", "plus", "about", "when", "where", "how", "who", "why",
        // linking / auxiliary verbs, incl. negations — "I don't…" hangs
        "is", "are", "was", "were", "be", "been",
        "do", "does", "did", "don't", "doesn't", "didn't",
        "can", "can't", "cannot", "will", "won't", "would", "wouldn't",
        "could", "couldn't", "should", "shouldn't", "isn't", "aren't", "wasn't",
        // dangling subjects — "remind me when I…" hangs
        "i", "i'm", "i'll", "i've", "we", "we're", "you're", "they're",
        "he's", "she's",
        // transitive verbs left hanging — "add…", "remind…"
        "get", "buy", "add", "need", "want", "make", "remind", "text", "tell",
        "call", "take", "send", "check", "put", "pick",
        // fillers
        "um", "uh", "like",
    ]

    /// Whole utterances that are complete despite being short — answers and
    /// acknowledgments must fire fast, not wait out the incomplete window.
    private static let completeShortAnswers: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "sure", "okay", "ok", "stop",
        "cancel", "done", "right", "correct", "thanks", "thank you",
        "go ahead", "send it", "never mind", "morning", "good morning",
        "hello", "hey otto",
    ]

    /// Heuristic for "parses as a complete utterance": terminal punctuation
    /// always qualifies; known short answers qualify; otherwise three-plus
    /// words not ending on a continuation word. The on-device intent
    /// classifier replaces this in a later phase.
    static func isSemanticallyComplete(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.unicodeScalars.last, ".!?".unicodeScalars.contains(last) {
            return true
        }
        let lowered = trimmed.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if completeShortAnswers.contains(lowered) {
            return true
        }
        let words = lowered.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 3, let lastWord = words.last else { return false }
        let stripped = lastWord.trimmingCharacters(in: .punctuationCharacters)
        return !continuationWords.contains(stripped)
    }

    // MARK: - Energy

    /// RMS energy of the buffer's first channel in dBFS. Runs on the audio
    /// render thread — keep it allocation-free.
    nonisolated static func rmsDb(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return -120
        }
        let samples = channelData[0]
        let frameCount = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frameCount)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }

    // MARK: - Teardown

    private func teardown() {
        isRunning = false
        removeTap()
        inputBuilder?.finish()
        inputBuilder = nil
        pendingChunkContinuation = nil

        chunkTask?.cancel()
        chunkTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        restartTask?.cancel()
        restartTask = nil

        if let analyzer {
            self.analyzer = nil
            Task { @AudioActor in
                await analyzer.cancelAndFinishNow()
            }
        }
        converter = nil
    }
}
