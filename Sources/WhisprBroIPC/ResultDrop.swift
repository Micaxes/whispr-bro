import Foundation

/// One transcript result, exactly the four fields of the `TranscriptResult`
/// contract. Codable property names ARE the contract's JSON keys (asserted in
/// tests against the `TranscriptResult` key constants).
public struct TranscriptResultRecord: Codable, Equatable {
    public let requestUUID: UUID
    public let keyboardInstanceNonce: UUID
    public let text: String
    public let completedAtMillis: UInt64

    public init(
        requestUUID: UUID,
        keyboardInstanceNonce: UUID,
        text: String,
        completedAtMillis: UInt64
    ) {
        self.requestUUID = requestUUID
        self.keyboardInstanceNonce = keyboardInstanceNonce
        self.text = text
        self.completedAtMillis = completedAtMillis
    }
}

/// The transcript-result file exchange (`TranscriptResult` doc): the app
/// writes `session.results/<requestUUID>.json` and posts the result hint
/// (`DarwinHint.post(KeyboardIPC.resultHintName)`); the keyboard reads by the
/// requestUUID it posted, applies the nonce guard, and removes the file once
/// inserted or dismissed. Reads are forgiving — a missing or unparseable file
/// is nil/skipped, never fatal — because the two sides update independently.
public enum ResultDrop {
    /// `container` is the App Group container root throughout (see
    /// `SharedContainer`); tests pass a temp directory.
    public static func resultsDirectory(in container: URL) -> URL {
        container.appendingPathComponent(KeyboardIPC.resultsDirectoryName, isDirectory: true)
    }

    /// Atomic replace (single-file writes are already all-or-nothing, and a
    /// re-run of the same request must never leave a half-old file), sorted
    /// keys so a hex/text dump of the container is diff-stable.
    @discardableResult
    public static func write(_ record: TranscriptResultRecord, in container: URL) throws -> URL {
        let directory = resultsDirectory(in: container)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = fileURL(for: record.requestUUID, in: container)
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    public static func read(requestUUID: UUID, in container: URL) -> TranscriptResultRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: requestUUID, in: container)) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptResultRecord.self, from: data)
    }

    /// Every readable result still in the drop, oldest first — what a fresh
    /// keyboard instance scans for unclaimed transcripts to offer as the
    /// pending-result key.
    public static func unclaimed(in container: URL) -> [TranscriptResultRecord] {
        let directory = resultsDirectory(in: container)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .compactMap { url -> TranscriptResultRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(TranscriptResultRecord.self, from: data)
            }
            .sorted { $0.completedAtMillis < $1.completedAtMillis }
    }

    /// Keyboard side, after insert or dismiss.
    public static func remove(requestUUID: UUID, in container: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: requestUUID, in: container))
    }

    /// App side: drop unclaimed results past `TranscriptResult
    /// .unclaimedTTLSeconds`, plus any file the drop can't parse (it can
    /// never be claimed, so it would otherwise leak forever).
    public static func collectGarbage(in container: URL, nowMillis: UInt64 = KeyboardIPC.nowMillis()) {
        let directory = resultsDirectory(in: container)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let ttlMillis = UInt64(TranscriptResult.unclaimedTTLSeconds * 1000)
        for url in files {
            let record = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode(TranscriptResultRecord.self, from: $0) }
            guard let record else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if nowMillis > record.completedAtMillis,
               nowMillis - record.completedAtMillis > ttlMillis {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func fileURL(for requestUUID: UUID, in container: URL) -> URL {
        resultsDirectory(in: container)
            .appendingPathComponent(requestUUID.uuidString + ".json")
    }
}
