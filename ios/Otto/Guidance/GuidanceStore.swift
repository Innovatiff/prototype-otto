import Foundation

/// Disk persistence for the guided session — one JSON file, written
/// atomically on every transition. IO failures are swallowed: guidance must
/// never crash over a lost write; the only cost is resume fidelity.
final class GuidanceStore: Sendable {

    /// A snapshot older than this is a dead session, not a resumable one —
    /// nobody resumes yesterday's workout at step 5.
    static let maxResumeAge: TimeInterval = 12 * 3600

    private let fileURL: URL

    /// Default directory is Application Support/Otto (created on demand);
    /// tests inject a temp directory.
    init(directory: URL? = nil) {
        let base =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appending(path: "Otto", directoryHint: .isDirectory)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appending(path: "guidance-session.json")
    }

    func save(_ snapshot: GuidanceSnapshot) {
        guard let data = try? OttoCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> GuidanceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? OttoCoding.decoder.decode(GuidanceSnapshot.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The resume check for app launch: a fresh in-progress snapshot, or
    /// nil — clearing anything stale so it is never offered twice.
    func pendingResume(now: Date = Date()) -> GuidanceSnapshot? {
        guard let snapshot = load() else { return nil }
        guard now.timeIntervalSince(snapshot.updatedAt) <= Self.maxResumeAge else {
            clear()
            return nil
        }
        return snapshot
    }
}
