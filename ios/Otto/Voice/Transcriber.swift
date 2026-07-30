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
/// Endpointing fires on whichever comes first:
///   (a) 700ms of continuous silence below the VAD energy threshold, or
///   (b) the partial transcript reads as a complete utterance AND 350ms of
///       silence has elapsed.
///
/// Each listening session is single-shot: `start()` builds a fresh analyzer,
/// the endpoint (or `cancel()`) tears it down. The endpoint transcript is the
/// finalized text plus the last volatile partial — we do not wait for the
/// analyzer's finalization pass, which would spend latency the 150ms endpoint
/// budget does not have.
@AudioActor
final class Transcriber {

    // MARK: - Tunables

    /// Mic energy below this (dBFS) counts as silence. With voice processing
    /// enabled the residual floor sits well under this; raise it if endpoint
    /// fires early in noisy rooms.
    var silenceThresholdDb: Float = -44

    /// Rule (a): hard silence endpoint.
    var hardSilenceMs: Double = 700

    /// Rule (b): silence required after a semantically complete utterance.
    var semanticSilenceMs: Double = 350

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

        if energyDb > silenceThresholdDb {
            speechEverDetected = true
            lastVoiceAt = at
            return
        }
        guard speechEverDetected else { return }

        let transcript = currentTranscript()
        guard !transcript.isEmpty else { return }

        let silenceMs = at.timeIntervalSince(lastVoiceAt) * 1000
        let semanticallyDone = Self.isSemanticallyComplete(transcript)
        if silenceMs >= hardSilenceMs || (semanticallyDone && silenceMs >= semanticSilenceMs) {
            fireEndpoint(transcript: transcript)
        }
    }

    private func fireEndpoint(transcript: String) {
        endpointFired = true
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
    /// these is mid-thought no matter how long the pause feels.
    private static let continuationWords: Set<String> = [
        "and", "or", "but", "to", "the", "a", "an", "my", "your", "of", "in",
        "on", "at", "for", "with", "so", "then", "that", "is", "are", "was",
        "if", "because", "um", "uh", "like",
    ]

    /// Phase 1 heuristic for "parses as a complete utterance": terminal
    /// punctuation always qualifies; otherwise three-plus words not ending on
    /// a continuation word. The 50ms on-device intent classifier replaces
    /// this in a later phase.
    static func isSemanticallyComplete(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.unicodeScalars.last, ".!?".unicodeScalars.contains(last) {
            return true
        }
        let words = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace })
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
