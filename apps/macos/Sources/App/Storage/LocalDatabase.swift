import Foundation
import SQLite3

/// Local SQLite database for caching artifact metadata.
/// Uses raw SQLite3 C API for minimal dependencies.
@MainActor
final class LocalDatabase {
    private var db: OpaquePointer?

    /// Path to the SQLite database file.
    private let dbPath: URL

    init(dbPath: URL? = nil) {
        let path = dbPath ?? Self.defaultDatabasePath
        self.dbPath = path
    }

    static var defaultDatabasePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleDir = appSupport.appendingPathComponent("Bundle")
        try? FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        return bundleDir.appendingPathComponent("bundle.db")
    }

    // MARK: - Connection Management

    /// Open the database and create tables if needed.
    func open() throws {
        let result = sqlite3_open(dbPath.path, &db)
        guard result == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw LocalDatabaseError.openFailed(message)
        }

        // Enable WAL mode for better concurrency
        try execute("PRAGMA journal_mode=WAL")
        try createTables()
    }

    /// Close the database connection.
    func close() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Schema

    private func createTables() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS artifacts (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                content_path TEXT,
                content_text TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at TEXT NOT NULL,
                synced_at TEXT
            )
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS tags (
                id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL REFERENCES artifacts(id),
                name TEXT NOT NULL
            )
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_artifacts_created_at ON artifacts(created_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_artifacts_status ON artifacts(status)")
        try execute("CREATE INDEX IF NOT EXISTS idx_tags_artifact_id ON tags(artifact_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(name)")
    }

    // MARK: - Artifact Operations

    /// Insert a new artifact with status "pending".
    func insertArtifact(
        id: String,
        type: String,
        contentPath: String?,
        contentText: String?,
        status: String = "pending",
        createdAt: Date
    ) throws {
        let sql = """
            INSERT INTO artifacts (id, type, content_path, content_text, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        let dateStr = ISO8601DateFormatter().string(from: createdAt)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (type as NSString).utf8String, -1, nil)

        if let path = contentPath {
            sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let text = contentText {
            sqlite3_bind_text(stmt, 4, (text as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_bind_text(stmt, 5, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (dateStr as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalDatabaseError.insertFailed(lastError)
        }
    }

    /// Update artifact status after upload.
    func updateArtifactStatus(id: String, status: String) throws {
        let sql = "UPDATE artifacts SET status = ?, synced_at = ? WHERE id = ?"
        let syncedAt = ISO8601DateFormatter().string(from: Date())

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (syncedAt as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalDatabaseError.updateFailed(lastError)
        }
    }

    /// Get all pending artifacts (for retry upload).
    func getPendingArtifacts() throws -> [LocalArtifact] {
        let sql = "SELECT id, type, content_path, content_text, status, created_at, synced_at FROM artifacts WHERE status = 'pending' ORDER BY created_at ASC"
        return try queryArtifacts(sql: sql)
    }

    /// Get total artifact count.
    func getArtifactCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM artifacts"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Private Helpers

    private func execute(_ sql: String) throws {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if result != SQLITE_OK {
            let message = errorMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMsg)
            throw LocalDatabaseError.execFailed(message)
        }
    }

    private func queryArtifacts(sql: String) throws -> [LocalArtifact] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        var artifacts: [LocalArtifact] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let artifact = LocalArtifact(
                id: columnText(stmt, 0) ?? "",
                type: columnText(stmt, 1) ?? "",
                contentPath: columnText(stmt, 2),
                contentText: columnText(stmt, 3),
                status: columnText(stmt, 4) ?? "pending",
                createdAt: columnText(stmt, 5) ?? "",
                syncedAt: columnText(stmt, 6)
            )
            artifacts.append(artifact)
        }
        return artifacts
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cString)
    }

    private var lastError: String {
        guard let db = db else { return "Database not open" }
        return String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - Models

struct LocalArtifact {
    let id: String
    let type: String
    let contentPath: String?
    let contentText: String?
    let status: String
    let createdAt: String
    let syncedAt: String?
}

// MARK: - Errors

enum LocalDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case insertFailed(String)
    case updateFailed(String)
    case execFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Database open failed: \(msg)"
        case .prepareFailed(let msg): return "SQL prepare failed: \(msg)"
        case .insertFailed(let msg): return "Insert failed: \(msg)"
        case .updateFailed(let msg): return "Update failed: \(msg)"
        case .execFailed(let msg): return "SQL exec failed: \(msg)"
        }
    }
}
