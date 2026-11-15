import Foundation
import SQLite3

public final class CompatibilityDatabase {
    private var db: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SeqomaError.command("Cannot open compatibility database") }
        let schema = "CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, bundle_id TEXT, version TEXT, app_name TEXT, original_minimum TEXT, target_version TEXT, architecture TEXT, strategy TEXT, status TEXT, created_at TEXT NOT NULL, json TEXT NOT NULL); CREATE INDEX IF NOT EXISTS records_bundle ON records(bundle_id, version);"
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw SeqomaError.command("Cannot initialize compatibility database") }
    }
    deinit { sqlite3_close(db) }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Seqoma/compatibility.sqlite3")
    }
    public func save(_ report: AnalysisReport) throws {
        try insert(id: report.id.uuidString, kind: "analysis", bundleID: report.bundleID, version: report.version, appName: report.appName, originalMinimum: report.declaredMinimum, target: report.profile.targetVersion, architecture: report.profile.architecture, strategy: "", status: report.classification.rawValue, created: report.date, object: report)
    }
    public func save(_ result: RebuildResult, report: AnalysisReport) throws {
        try insert(id: result.id.uuidString, kind: "rebuild", bundleID: report.bundleID, version: report.version, appName: report.appName, originalMinimum: report.declaredMinimum, target: report.profile.targetVersion, architecture: report.profile.architecture, strategy: result.strategy.rawValue, status: result.status.rawValue, created: result.date, object: result)
    }
    public func save(_ result: TestResult, report: AnalysisReport) throws {
        try insert(id: UUID().uuidString, kind: "test", bundleID: report.bundleID, version: report.version, appName: report.appName, originalMinimum: report.declaredMinimum, target: report.profile.targetVersion, architecture: report.profile.architecture, strategy: "", status: result.status.rawValue, created: result.date, object: result)
    }
    public func list(limit: Int = 100) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT kind, app_name, bundle_id, version, status, created_at, json FROM records ORDER BY created_at DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw SeqomaError.command("Database query failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for (i, key) in ["kind", "appName", "bundleID", "version", "status", "date", "json"].enumerated() {
                row[key] = sqlite3_column_text(statement, Int32(i)).map { String(cString: $0) } ?? ""
            }
            rows.append(row)
        }
        return rows
    }
    private func insert<T: Encodable>(id: String, kind: String, bundleID: String, version: String, appName: String, originalMinimum: String, target: String, architecture: String, strategy: String, status: String, created: Date, object: T) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(object), as: UTF8.self)
        let values = [id, kind, bundleID, version, appName, originalMinimum, target, architecture, strategy, status, ISO8601DateFormatter().string(from: created), json]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO records VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw SeqomaError.command("Database insert failed") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SeqomaError.command("Database write failed") }
    }
}
