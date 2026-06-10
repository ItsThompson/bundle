import Foundation
import SQLite3

/// Tag query extensions for LocalDatabase.
/// Provides methods for tag filtering in the retrieval panel.
extension LocalDatabase {

    /// A tag with its artifact count.
    struct TagCount {
        let name: String
        let count: Int
    }

    /// Get all tags with artifact counts, ordered by count descending (most-used first).
    func getTagsWithCounts() throws -> [TagCount] {
        let sql = "SELECT name, COUNT(*) as cnt FROM tags GROUP BY name ORDER BY cnt DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [TagCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = columnText(stmt, 0) ?? ""
            let count = Int(sqlite3_column_int(stmt, 1))
            results.append(TagCount(name: name, count: count))
        }
        return results
    }

    /// Get artifact IDs that have a specific tag.
    func getArtifactIdsForTag(name: String) throws -> [String] {
        let sql = "SELECT artifact_id FROM tags WHERE name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = columnText(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Get artifacts filtered by tag, ordered by created_at DESC with pagination.
    func getArtifactsForTag(tagName: String, limit: Int, offset: Int) throws -> [LocalArtifact] {
        let sql = """
            SELECT a.id, a.type, a.content_path, a.content_text, a.status, a.created_at, a.synced_at
            FROM artifacts a
            INNER JOIN tags t ON t.artifact_id = a.id
            WHERE t.name = ?
            ORDER BY a.created_at DESC
            LIMIT ? OFFSET ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tagName as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(offset))

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

    /// Get count of artifacts with a specific tag.
    func getArtifactCountForTag(tagName: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM tags WHERE name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalDatabaseError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tagName as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
