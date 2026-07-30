import AVFoundation
import Foundation

/// Text-to-speech output.
///
/// Isolated to AudioActor (the shared audio domain from Step 1): conformers
/// hold non-Sendable AVFoundation objects, and VoiceLoop — its own actor —
/// awaits these members. The member set matches the Phase 1 spec exactly;
/// ElevenLabsSpeaker arrives as a second conformer at the end of the phase.
@AudioActor
protocol Speaker {
    /// Speaks an async stream of text (speakable units from the ClauseBuffer),
    /// beginning with the first unit without waiting for the stream to finish.
    func speak(_ stream: AsyncStream<String>) async throws
    func speak(clip: CachedClip) async throws
    /// Fades out over ~120ms, then stops and discards everything queued.
    /// Never hard-cuts — a hard cut sounds broken.
    func stopImmediately() async
    var isSpeaking: Bool { get }
}

/// Timing surface for the Step 6 latency ledger, separate so the Speaker
/// protocol stays exactly as specified.
@AudioActor
protocol SpeakerInstrumentation {
    /// When the current/most recent session scheduled its first audio.
    var lastFirstAudioAt: Date? { get }
}

/// A synthesized buffer crossing from the synthesizer's delivery queue into
/// the AudioActor domain (used by SystemSpeaker and ClipCache rendering).
/// `@unchecked Sendable` is justified narrowly: each buffer is freshly
/// created by the synthesizer, handed to exactly one consumer, and never
/// touched after scheduling.
struct SynthesizedBuffer: @unchecked Sendable {
    let buffer: AVAudioBuffer
}

/// AVSpeechSynthesizer-backed Speaker.
///
/// Speech is synthesized into buffers (`write(_:toBufferCallback:)`) and
/// scheduled on the engine's playback node rather than played through the
/// synthesizer's own output. Two load-bearing reasons:
///
/// 1. The voice-processing unit hears the playback as its echo-cancellation
///    reference, which is what keeps the mic from triggering barge-in off
///    Otto's own voice.
/// 2. `stopImmediately()` can ramp the player node's volume over 120ms and
///    then purge — the synthesizer's direct output can only hard-cut.
///
/// Synthesis runs faster than realtime, so clause N+1 synthesizes while
/// clause N is still playing; the player node queues buffers in order.
@AudioActor
final class SystemSpeaker: Speaker, SpeakerInstrumentation {

    private let audioSession: AudioSessionController
    private let synthesizer = AVSpeechSynthesizer()

    private(set) var isSpeaking = false
    private(set) var lastFirstAudioAt: Date?

    /// Injected at init; speak(clip:) prefers it over live synthesis.
    private let clipCache: ClipCache?

    /// Incremented on every session start, stop, and engine restart; buffer
    /// and completion callbacks carry the generation they belong to and are
    /// ignored once it is stale.
    private var generation = 0
    private var outstandingBuffers = 0
    private var stopping = false
    private var playerStarted = false

    private var utteranceContinuation: CheckedContinuation<Void, Never>?
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var restartTask: Task<Void, Never>?

    init(audioSession: AudioSessionController, clipCache: ClipCache? = nil) {
        self.audioSession = audioSession
        self.clipCache = clipCache
    }

    // MARK: - Speaker

    func speak(_ stream: AsyncStream<String>) async {
        let session = beginSession()
        for await unit in stream {
            guard session == generation, !stopping else { break }
            let text = unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            await synthesize(text, session: session)
        }
        await waitForDrain(session: session)
        if session == generation {
            isSpeaking = false
        }
    }

    func speak(clip: CachedClip) async {
        // Cache first — pre-rendered playback with nothing to synthesize.
        if let cached = clipCache?.buffer(for: clip) {
            await playCachedBuffer(cached)
            return
        }
        // Fallback: live synthesis through the streaming path. Silence is the
        // worst possible failure; a slow clip beats no clip.
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        continuation.yield(clip.rawValue)
        continuation.finish()
        await speak(stream)
    }

    /// A cached clip through the normal session machinery, so isSpeaking,
    /// stopImmediately's fade, and the drain bookkeeping all behave exactly
    /// as they do for streamed speech.
    private func playCachedBuffer(_ buffer: AVAudioPCMBuffer) async {
        let session = beginSession()
        ensurePlaybackConnected(format: buffer.format)
        outstandingBuffers += 1
        if lastFirstAudioAt == nil {
            lastFirstAudioAt = Date()
        }
        audioSession.playbackNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            Task { @AudioActor in
                self.bufferPlayed(session: session)
            }
        }
        if !playerStarted {
            audioSession.playbackNode.play()
            playerStarted = true
        }
        await waitForDrain(session: session)
        if session == generation {
            isSpeaking = false
        }
    }

    func stopImmediately() async {
        guard isSpeaking else { return }
        stopping = true
        generation += 1

        // Halt buffer delivery from any in-flight synthesis and release the
        // clause that is waiting on it.
        _ = synthesizer.stopSpeaking(at: .immediate)
        utteranceContinuation?.resume()
        utteranceContinuation = nil

        // 120ms fade on the playback node, then purge what remains queued.
        let node = audioSession.playbackNode
        let startVolume = node.volume
        let steps = 12
        for step in 1...steps {
            node.volume = startVolume * Float(steps - step) / Float(steps)
            try? await Task.sleep(for: .milliseconds(10))
        }
        node.stop()
        node.volume = startVolume
        playerStarted = false

        outstandingBuffers = 0
        drainContinuation?.resume()
        drainContinuation = nil
        isSpeaking = false
    }

    // MARK: - Session

    private func beginSession() -> Int {
        watchEngineRestartsIfNeeded()
        generation += 1
        stopping = false
        isSpeaking = true
        outstandingBuffers = 0
        playerStarted = false
        lastFirstAudioAt = nil
        return generation
    }

    /// One clause: synthesize into buffers, scheduling each as it arrives.
    /// Returns when the synthesizer has delivered the whole clause (playback
    /// usually continues well past this point).
    private func synthesize(_ text: String, session: Int) async {
        let utterance = AVSpeechUtterance(string: text)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            utteranceContinuation = continuation
            synthesizer.write(utterance) { @Sendable rawBuffer in
                // Synthesizer delivery queue: box and hop, nothing else.
                let boxed = SynthesizedBuffer(buffer: rawBuffer)
                Task { @AudioActor in
                    self.handleSynthesized(boxed, session: session)
                }
            }
        }
    }

    private func handleSynthesized(_ boxed: SynthesizedBuffer, session: Int) {
        guard session == generation, !stopping else { return }
        guard let pcm = boxed.buffer as? AVAudioPCMBuffer else {
            return
        }
        // A zero-frame buffer is the synthesizer's end-of-utterance marker.
        guard pcm.frameLength > 0 else {
            utteranceContinuation?.resume()
            utteranceContinuation = nil
            return
        }

        ensurePlaybackConnected(format: pcm.format)
        outstandingBuffers += 1
        if lastFirstAudioAt == nil {
            lastFirstAudioAt = Date()
        }
        audioSession.playbackNode.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            Task { @AudioActor in
                self.bufferPlayed(session: session)
            }
        }
        if !playerStarted {
            audioSession.playbackNode.play()
            playerStarted = true
        }
    }

    private func bufferPlayed(session: Int) {
        guard session == generation else { return }
        outstandingBuffers -= 1
        if outstandingBuffers <= 0 {
            drainContinuation?.resume()
            drainContinuation = nil
        }
    }

    private func waitForDrain(session: Int) async {
        guard session == generation, outstandingBuffers > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainContinuation = continuation
        }
    }

    /// Connect the playback node for the source buffer's format; the session
    /// controller dedupes, so this is a cheap per-buffer call.
    private func ensurePlaybackConnected(format: AVAudioFormat) {
        audioSession.connectPlayback(format: format)
    }

    // MARK: - Engine restarts

    /// A route change purges the player node's queue — the scheduled-buffer
    /// completions will never fire. End the session instead of hanging the
    /// drain; VoiceLoop decides what to do next.
    private func watchEngineRestartsIfNeeded() {
        guard restartTask == nil else { return }
        let restarts = audioSession.engineRestartedStream()
        restartTask = Task { @AudioActor in
            for await _ in restarts {
                self.handleEngineRestart()
            }
        }
    }

    private func handleEngineRestart() {
        playerStarted = false
        guard isSpeaking else { return }
        generation += 1
        outstandingBuffers = 0
        utteranceContinuation?.resume()
        utteranceContinuation = nil
        drainContinuation?.resume()
        drainContinuation = nil
        isSpeaking = false
    }
}
