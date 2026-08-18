import AVFoundation
import Foundation

/// The single isolation domain for all audio work.
///
/// AVFoundation audio objects (engine, nodes, buffers) are not Sendable, so
/// every component that touches them — the session controller, transcriber,
/// speaker — lives on this one global actor and can share them freely.
/// Nothing here ever runs on the main thread. VoiceLoop (its own actor)
/// coordinates these components through async calls.
@globalActor
actor AudioActor {
    static let shared = AudioActor()
}

enum AudioSessionState: String, Sendable {
    case inactive
    case active
    case interrupted
}

/// Owns the AVAudioSession configuration and the one AVAudioEngine.
///
/// Design notes, load-bearing:
///
/// - Voice processing is enabled on BOTH the input and output nodes before the
///   engine starts. That turns on hardware echo cancellation — without it the
///   mic hears Otto's own voice and barge-in is impossible.
///
/// - All of Otto's playback (Step 3's Speaker) goes through `playbackNode`
///   inside this same engine, not a separate output path. Two reasons: the
///   voice-processing unit then has the playback as its echo-cancellation
///   reference, and a player node's volume can be ramped for the 120ms
///   stop fade — AVSpeechSynthesizer's direct output can only hard-cut.
///
/// - A route change (AirPods connecting mid-conversation) STOPS the engine and
///   can change node formats. `configurationChangeNotification` handling
///   rewires and restarts, then signals `engineRestarted` so tap owners (the
///   transcriber) reinstall their taps against the new input format.
///
/// - Enabling voice processing can change the input node's channel count and
///   sample rate, so consumers must read `currentInputFormat()` AFTER the
///   session is started, never cache a format from before.
///
/// Lifetime: one instance, owned for the life of the app. Observers are
/// registered once and never removed.
@AudioActor
final class AudioSessionController {

    private(set) var state: AudioSessionState = .inactive

    /// The engine is exposed audio-domain-wide (everything on AudioActor);
    /// components outside the audio domain go through VoiceLoop instead.
    let engine = AVAudioEngine()

    /// Attach point for all synthesized speech (Step 3).
    let playbackNode = AVAudioPlayerNode()

    /// True when hardware echo cancellation is actually on. The Simulator can
    /// refuse voice processing; we degrade loudly rather than fail startup —
    /// acceptance runs on a physical device, where this must be true.
    private(set) var isVoiceProcessingEnabled = false

    private var playbackAttached = false
    private var observersInstalled = false
    /// Held for the life of the app; observers are never removed.
    private var observerTokens: [any NSObjectProtocol] = []
    private var stateContinuations: [UUID: AsyncStream<AudioSessionState>.Continuation] = [:]
    private var restartContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    // MARK: - Observation

    /// State transitions, for VoiceLoop and the UI. One stream per caller.
    func stateStream() -> AsyncStream<AudioSessionState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state)
            stateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @AudioActor in
                    self.stateContinuations[id] = nil
                }
            }
        }
    }

    /// Fires after the engine is rebuilt (route/config change). Tap owners
    /// must reinstall their taps when this fires — formats may have changed.
    func engineRestartedStream() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            restartContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @AudioActor in
                    self.restartContinuations[id] = nil
                }
            }
        }
    }

    private func setState(_ newState: AudioSessionState) {
        guard newState != state else { return }
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    // MARK: - Permissions

    /// Must be granted before `start()`. Safe to call repeatedly.
    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard state != .active else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        // 20ms IO buffers keep VAD/endpoint granularity well inside the 150ms
        // endpoint budget. Best-effort: the OS may pick a neighboring value.
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        installObserversIfNeeded()
        try buildGraphAndStart()
        setState(.active)
    }

    /// While a guided session runs, the audio session and engine stay live
    /// even when no cue is playing — that continuous audio rendering is what
    /// keeps timers running behind a locked screen (UIBackgroundModes:
    /// audio). Otto speaks real cues throughout, so this is the legitimate
    /// use of the mode.
    private(set) var guidanceHold = false

    func beginGuidanceHold() throws {
        guidanceHold = true
        try start()
    }

    /// Ends the hold. The session stays active until the next natural
    /// stop() — VoiceLoop's teardown or the app going quiet.
    func endGuidanceHold() {
        guidanceHold = false
    }

    func stop() {
        // A guided session outlives any single conversation; its hold wins
        // over conversation teardown.
        guard !guidanceHold else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        setState(.inactive)
    }

    /// The live mic format. Read AFTER start(), and re-read after every
    /// `engineRestarted` signal — voice processing and route changes both
    /// change it.
    func currentInputFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// The playback node's current source format; nil means the mixer's own.
    private var playbackFormat: AVAudioFormat?

    /// (Re)connects the playback node for an explicit source format — the
    /// speaker and clip cache both call this per buffer, and the mixer
    /// converts to the hardware rate. Deduped: reconnecting with the format
    /// already in place is a no-op.
    func connectPlayback(format: AVAudioFormat?) {
        guard format != playbackFormat else { return }
        engine.connect(playbackNode, to: engine.mainMixerNode, format: format)
        playbackFormat = format
    }

    // MARK: - Graph

    private func buildGraphAndStart() throws {
        // Voice processing must be configured while the engine is stopped.
        if !isVoiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                try engine.outputNode.setVoiceProcessingEnabled(true)
                isVoiceProcessingEnabled = true
            } catch {
                // Simulator, or an exotic route. Without AEC, barge-in will
                // false-trigger off Otto's own voice — degrade loudly.
                isVoiceProcessingEnabled = false
                print("AudioSession: voice processing unavailable (\(error)); echo cancellation OFF")
            }
        }

        if !playbackAttached {
            engine.attach(playbackNode)
            playbackAttached = true
        }
        // nil format: let the engine negotiate against the (possibly VP-altered)
        // mixer format at connect time. Reset the tracker so the next
        // connectPlayback(format:) call reconnects for its source format.
        engine.connect(playbackNode, to: engine.mainMixerNode, format: nil)
        playbackFormat = nil

        // Touching inputNode materializes the mic path within the session's
        // category; a tap is installed later by the transcriber.
        _ = engine.inputNode

        engine.prepare()
        try engine.start()
    }

    private func rebuildAfterConfigurationChange() {
        guard state == .active else { return }
        engine.stop()
        do {
            try buildGraphAndStart()
            for continuation in restartContinuations.values {
                continuation.yield(())
            }
        } catch {
            print("AudioSession: engine restart after configuration change failed: \(error)")
            setState(.inactive)
        }
    }

    // MARK: - Notifications

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let center = NotificationCenter.default

        // Phone calls, Siri, alarms. Pause cleanly; resume only on .shouldResume.
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { notification in
            // Extract Sendable primitives before hopping isolation domains.
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt
            else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @AudioActor in
                self.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        })

        // AirPods arriving/leaving mid-conversation. The engine posts its own
        // configuration-change below; here we only note reasons that matter.
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @AudioActor in
                self.handleRouteChange(rawReason: rawReason)
            }
        })

        // The engine stopped because the audio hardware configuration changed.
        // Rewire and restart — this is what keeps AirPods switches from
        // killing the conversation.
        observerTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            Task { @AudioActor in
                self.rebuildAfterConfigurationChange()
            }
        })
    }

    private func handleInterruption(rawType: UInt, rawOptions: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            engine.pause()
            setState(.interrupted)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume) else {
                setState(.inactive)
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try buildGraphAndStart()
                setState(.active)
                for continuation in restartContinuations.values {
                    continuation.yield(())
                }
            } catch {
                print("AudioSession: resume after interruption failed: \(error)")
                setState(.inactive)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange:
            // If the engine survived, nothing to do; if it stopped, the
            // configuration-change notification drives the rebuild.
            break
        default:
            break
        }
    }
}
