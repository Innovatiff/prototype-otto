import Foundation

/// A finished session's record, waiting to reach the server.
struct PendingRecord: Codable, Equatable, Sendable {
    let planId: String
    let upload: SessionRecordUpload
}

/// Store-and-forward for session records. A basement session with no
/// signal must lose NOTHING: records append to disk first, then flush —
/// on session end and on the next session start — removing only what the
/// server confirmed. Single-caller (the runtime), sequential by design.
final class RecordOutbox: Sendable {

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appending(path: "Otto", directoryHint: .isDirectory)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appending(path: "record-outbox.json")
    }

    func append(_ pending: PendingRecord) {
        var all = load()
        all.append(pending)
        save(all)
    }

    func load() -> [PendingRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? OttoCoding.decoder.decode([PendingRecord].self, from: data)) ?? []
    }

    /// Attempts each pending record in order; keeps what failed (order
    /// preserved) for the next flush. Returns how many remain.
    @discardableResult
    func flush(send: (PendingRecord) async -> Bool) async -> Int {
        let all = load()
        guard !all.isEmpty else { return 0 }
        var remaining: [PendingRecord] = []
        for pending in all {
            if await send(pending) {
                continue
            }
            remaining.append(pending)
        }
        save(remaining)
        return remaining.count
    }

    private func save(_ records: [PendingRecord]) {
        if records.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? OttoCoding.encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
