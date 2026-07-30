import AVFoundation
import Foundation

/// The short phrases Otto says thousands of times. Synthesized once, replayed
/// at zero cost and near-zero latency.
///
/// Scaffolded with the starter set; expands to ~200 later. Raw values are the
/// spoken text.
enum CachedClip: String, CaseIterable, Sendable {
    case acknowledged = "Understood."
    case working = "One moment."
    case listening = "Go ahead."
    case gotIt = "Got that."
    case tenSeconds = "Ten seconds."
    case timeUp = "Time."
    case nextStep = "Next step."
    case notSure = "I didn't catch that."
    case cantHelp = "I can't do that yet."
}

/// Pre-rendered clip storage and playback.
///
/// First launch renders every clip to a .caf in Application Support (via the
/// same AVSpeechSynthesizer buffer path the speaker uses); every launch after
/// that loads the files straight into memory — ~1MB total for the starter
/// set. A cache hit is then just scheduleBuffer + play on the shared playback
/// node: no synthesis, no disk, single-digit milliseconds to first audio.
///
/// The manifest pins cache version, voice, and phrase text; any change wipes
/// and re-renders, so edited phrases or a new system voice never play stale
/// audio.
@AudioActor
final class ClipCache {

    private struct Manifest: Codable, Equatable {
        var version: Int
        var voiceIdentifier: String
        var phrases: [String: String]
    }

    /// Bump when rendering parameters change (rate, voice selection logic…).
    private static let cacheVersion = 1

    private let audioSession: AudioSessionController
    private let synthesizer = AVSpeechSynthesizer()
    private var buffers: [CachedClip: AVAudioPCMBuffer] = [:]
    private(set) var isReady = false

    /// Milliseconds from play(_:) entry to the playback node starting, for
    /// the most recent call — the debug overlay's cache-hit latency readout.
    private(set) var lastPlayLatencyMs: Double?

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
    }

    // MARK: - Preparation

    /// Loads the cache, rendering first if the manifest is stale or absent.
    /// Idempotent; call once at app start (off the main thread by
    /// construction — this whole type lives on AudioActor).
    func prepare() async {
        guard !isReady else { return }
        do {
            let directory = try Self.cacheDirectory()
            let manifestURL = directory.appending(path: "manifest.json")
            let current = Self.currentManifest()
            let stored = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }

            if stored != current {
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for clip in CachedClip.allCases {
                    try await render(clip, into: directory)
                }
                try JSONEncoder().encode(current).write(to: manifestURL)
            }

            for clip in CachedClip.allCases {
                let url = directory.appending(path: Self.fileName(for: clip))
                if let buffer = Self.loadBuffer(from: url) {
                    buffers[clip] = buffer
                } else {
                    // A missing or corrupt file: render just this one.
                    try await render(clip, into: directory)
                    if let buffer = Self.loadBuffer(from: url) {
                        buffers[clip] = buffer
                    }
                }
            }
            isReady = buffers.count == CachedClip.allCases.count
            print("ClipCache: ready with \(buffers.count)/\(CachedClip.allCases.count) clips")
        } catch {
            // Not fatal: speak(clip:) falls back to live synthesis. Silence
            // is the worst failure; a slow clip is not.
            print("ClipCache: prepare failed: \(error)")
        }
    }

    /// The in-memory buffer for a clip, if the cache has it. The speaker uses
    /// this so cached clips flow through its normal session machinery.
    func buffer(for clip: CachedClip) -> AVAudioPCMBuffer? {
        buffers[clip]
    }

    // MARK: - Standalone playback

    /// Plays a clip directly on the shared playback node — for timer cues and
    /// prompts outside a speech session. Checks the cache before any
    /// synthesis; a miss renders once (slow), caches, then plays.
    func play(_ clip: CachedClip) async {
        let startedAt = Date()

        if buffers[clip] == nil {
            if let directory = try? Self.cacheDirectory() {
                try? await render(clip, into: directory)
                let url = directory.appending(path: Self.fileName(for: clip))
                buffers[clip] = Self.loadBuffer(from: url)
            }
        }
        guard let buffer = buffers[clip] else {
            print("ClipCache: no audio for \(clip.rawValue.debugDescription)")
            return
        }

        if audioSession.state != .active {
            try? audioSession.start()
        }
        guard audioSession.state == .active else { return }

        audioSession.connectPlayback(format: buffer.format)
        let node = audioSession.playbackNode
        lastPlayLatencyMs = Date().timeIntervalSince(startedAt) * 1000
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
                continuation.resume()
            }
            node.play()
        }
    }

    // MARK: - Rendering

    /// Synthesizes one clip into a .caf file using the same buffer-callback
    /// path as live speech, so cached and live audio share format and voice.
    private func render(_ clip: CachedClip, into directory: URL) async throws {
        let url = directory.appending(path: Self.fileName(for: clip))
        try? FileManager.default.removeItem(at: url)

        let (stream, continuation) = AsyncStream.makeStream(of: SynthesizedBuffer.self)
        let utterance = AVSpeechUtterance(string: clip.rawValue)
        synthesizer.write(utterance) { @Sendable rawBuffer in
            // A zero-frame buffer is the end-of-utterance marker.
            if let pcm = rawBuffer as? AVAudioPCMBuffer, pcm.frameLength == 0 {
                continuation.finish()
            } else {
                continuation.yield(SynthesizedBuffer(buffer: rawBuffer))
            }
        }

        var file: AVAudioFile?
        for await boxed in stream {
            guard let pcm = boxed.buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                continue
            }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
            }
            try file?.write(from: pcm)
        }
        // The file finishes writing when the AVAudioFile deallocates here.
    }

    // MARK: - Storage

    private static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "OttoClips", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileName(for clip: CachedClip) -> String {
        "\(String(describing: clip)).caf"
    }

    private static func currentManifest() -> Manifest {
        let voice = AVSpeechSynthesisVoice(language: nil)?.identifier ?? "system-default"
        var phrases: [String: String] = [:]
        for clip in CachedClip.allCases {
            phrases[String(describing: clip)] = clip.rawValue
        }
        return Manifest(version: cacheVersion, voiceIdentifier: voice, phrases: phrases)
    }

    private static func loadBuffer(from url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return buffer.frameLength > 0 ? buffer : nil
    }
}
