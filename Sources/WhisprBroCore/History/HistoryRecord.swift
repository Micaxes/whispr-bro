import Foundation
import GRDB

/// One dictation, persisted to the local history (spec §4 HistoryStore). Holds
/// the raw + formatted text, the app it landed in, and every per-stage latency
/// so a regression after a model swap is visible in the history UI.
public struct HistoryRecord: Codable, Sendable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public var id: Int64?          // nil before insert; filled by didInsert
    public var createdAt: Date
    public var appBundleId: String?
    public var appName: String?
    public var rawText: String
    public var formattedText: String?
    public var audioMs: Int?
    public var asrMs: Int?
    public var formatMs: Int?
    public var insertMs: Int?
    public var totalMs: Int?
    /// Utterance length in ms (captured audio duration), for an honest WPM.
    /// nil for pre-migration rows and Command-Mode edits (not spoken dictations).
    public var durationMs: Int?
    /// Dictation language code (en/it/es), populated going forward (migration v2).
    public var language: String?

    public static let databaseTableName = "record"

    public init(
        createdAt: Date, appBundleId: String?, appName: String?,
        rawText: String, formattedText: String?,
        audioMs: Int?, asrMs: Int?, formatMs: Int?, insertMs: Int?, totalMs: Int?,
        durationMs: Int? = nil, language: String? = nil
    ) {
        self.createdAt = createdAt
        self.appBundleId = appBundleId
        self.appName = appName
        self.rawText = rawText
        self.formattedText = formattedText
        self.audioMs = audioMs
        self.asrMs = asrMs
        self.formatMs = formatMs
        self.insertMs = insertMs
        self.totalMs = totalMs
        self.durationMs = durationMs
        self.language = language
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The text a user would re-insert (formatted if present, else raw).
    public var displayText: String { formattedText ?? rawText }
}
