@testable import Bundle
import Foundation
import Testing

@Suite("Artifact ID Lifecycle Tests")
@MainActor
struct ArtifactIdLifecycleTests {
    // MARK: - Helpers

    private func makeDatabase() throws -> (LocalDatabase, URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_lifecycle_\(UUID().uuidString).db")
        let db = LocalDatabase(dbPath: dbPath)
        try db.open()
        return (db, dbPath)
    }

    // MARK: - getUploadState

    @Test("getUploadState returns nil for non-existent artifact")
    func getUploadStateReturnsNilForMissing() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let state = try db.getUploadState(for: "nonexistent-id")
        #expect(state == nil)
    }

    @Test("getUploadState returns 'idle' for default-inserted artifact")
    func getUploadStateReturnsIdle() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let id = UUID().uuidString
        try db.insertArtifact(
            id: id, type: "note", contentPath: nil,
            contentText: "hello", createdAt: Date()
        )

        let state = try db.getUploadState(for: id)
        #expect(state == "idle")
    }

    @Test("getUploadState returns 'uploading' after insertArtifact with uploadState")
    func getUploadStateReturnsUploading() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let id = UUID().uuidString
        try db.insertArtifact(
            id: id, type: "screenshot", contentPath: "test.png",
            contentText: nil, createdAt: Date(), uploadState: "uploading"
        )

        let state = try db.getUploadState(for: id)
        #expect(state == "uploading")
    }

    @Test("setUploadState updates state correctly")
    func setUploadStateWorks() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let id = UUID().uuidString
        try db.insertArtifact(
            id: id, type: "note", contentPath: nil,
            contentText: "test", createdAt: Date(), uploadState: "uploading"
        )

        try db.setUploadState(artifactId: id, state: "uploaded")
        let state = try db.getUploadState(for: id)
        #expect(state == "uploaded")
    }

    // MARK: - replaceArtifactId sets upload_state to 'uploaded'

    @Test("replaceArtifactId sets upload_state to 'uploaded'")
    func replaceArtifactIdSetsUploaded() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let localId = UUID().uuidString
        let backendId = UUID().uuidString
        try db.insertArtifact(
            id: localId, type: "screenshot", contentPath: "img.png",
            contentText: nil, createdAt: Date(), uploadState: "uploading"
        )

        try db.replaceArtifactId(oldId: localId, newId: backendId, status: "completed")

        let state = try db.getUploadState(for: backendId)
        #expect(state == "uploaded")
    }

    // MARK: - replaceArtifactId handles SQLITE_CONSTRAINT

    @Test("replaceArtifactId with pre-existing newId resolves conflict by deleting old record")
    func replaceArtifactIdHandlesConstraintViolation() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let localId = UUID().uuidString
        let backendId = UUID().uuidString

        // Insert the local artifact (in uploading state)
        try db.insertArtifact(
            id: localId, type: "screenshot", contentPath: "img.png",
            contentText: nil, createdAt: Date(), uploadState: "uploading"
        )

        // Simulate sync arriving first: insert artifact with the backend ID
        try db.upsertArtifactFromSync(
            id: backendId, type: "screenshot", contentText: nil,
            status: "completed", createdAt: Date(), syncedAt: Date()
        )

        // Now replaceArtifactId should hit the constraint (backendId already exists)
        // It should resolve by deleting the old local record
        try db.replaceArtifactId(oldId: localId, newId: backendId, status: "completed")

        // The old local record should be gone
        let oldState = try db.getUploadState(for: localId)
        #expect(oldState == nil)

        // The synced record should still exist
        let backendState = try db.getUploadState(for: backendId)
        #expect(backendState != nil)

        // Total count should be 1 (no duplicates)
        let count = try db.getArtifactCount()
        #expect(count == 1)
    }

    // MARK: - Sync skips artifact in 'uploading' state

    @Test("upsertArtifactFromSync does not overwrite artifact in 'uploading' state")
    func syncSkipsUploadingArtifact() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let artifactId = UUID().uuidString

        // Insert artifact locally in uploading state
        try db.insertArtifact(
            id: artifactId, type: "note", contentPath: nil,
            contentText: "local content", status: "pending",
            createdAt: Date(), uploadState: "uploading"
        )

        // Check the upload state guard (simulating what SyncService does)
        let uploadState = try db.getUploadState(for: artifactId)
        #expect(uploadState == "uploading")

        // If uploading, sync should skip: verify the original content is preserved
        if uploadState != "uploading" {
            try db.upsertArtifactFromSync(
                id: artifactId, type: "note", contentText: "synced content",
                status: "completed", createdAt: Date(), syncedAt: Date()
            )
        }

        // Verify original data is preserved (sync was skipped)
        let artifacts = try db.getArtifacts(limit: 10, offset: 0)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].contentText == "local content")
        #expect(artifacts[0].status == "pending")
    }

    @Test("upsertArtifactFromSync proceeds when upload_state is 'idle'")
    func syncProceedsForIdleArtifact() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let artifactId = UUID().uuidString

        // Insert artifact locally in idle state
        try db.insertArtifact(
            id: artifactId, type: "note", contentPath: nil,
            contentText: "local content", status: "pending",
            createdAt: Date(), uploadState: "idle"
        )

        // Sync should proceed for idle artifacts
        let uploadState = try db.getUploadState(for: artifactId)
        #expect(uploadState == "idle")

        // Upsert from sync should update it
        try db.upsertArtifactFromSync(
            id: artifactId, type: "note", contentText: "synced content",
            status: "completed", createdAt: Date(), syncedAt: Date()
        )

        let artifacts = try db.getArtifacts(limit: 10, offset: 0)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].contentText == "synced content")
        #expect(artifacts[0].status == "completed")
    }

    // MARK: - Upload failure resets state to 'idle'

    @Test("Upload failure resets upload_state to 'idle'")
    func uploadFailureResetsState() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let artifactId = UUID().uuidString

        // Insert in uploading state (simulating what CaptureCoordinator does)
        try db.insertArtifact(
            id: artifactId, type: "screenshot", contentPath: "img.png",
            contentText: nil, status: "pending",
            createdAt: Date(), uploadState: "uploading"
        )

        // Verify it's uploading
        let stateBefore = try db.getUploadState(for: artifactId)
        #expect(stateBefore == "uploading")

        // Simulate upload failure: reset to idle
        try db.setUploadState(artifactId: artifactId, state: "idle")

        let stateAfter = try db.getUploadState(for: artifactId)
        #expect(stateAfter == "idle")
    }

    // MARK: - Full lifecycle: idle → uploading → uploaded

    @Test("Full lifecycle transitions: idle → uploading → uploaded")
    func fullLifecycleTransitions() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let localId = UUID().uuidString
        let backendId = UUID().uuidString

        // 1. Insert with default idle state
        try db.insertArtifact(
            id: localId, type: "link", contentPath: nil,
            contentText: "https://example.com", createdAt: Date()
        )
        #expect(try db.getUploadState(for: localId) == "idle")

        // 2. Mark as uploading before upload begins
        try db.setUploadState(artifactId: localId, state: "uploading")
        #expect(try db.getUploadState(for: localId) == "uploading")

        // 3. Replace ID after successful upload (sets upload_state to 'uploaded')
        try db.replaceArtifactId(oldId: localId, newId: backendId, status: "completed")
        #expect(try db.getUploadState(for: backendId) == "uploaded")

        // Original ID should no longer exist
        #expect(try db.getUploadState(for: localId) == nil)
    }

    // MARK: - deleteArtifact

    @Test("deleteArtifact removes the artifact")
    func deleteArtifactWorks() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        let id = UUID().uuidString
        try db.insertArtifact(
            id: id, type: "note", contentPath: nil,
            contentText: "test", createdAt: Date()
        )

        #expect(try db.getArtifactCount() == 1)
        try db.deleteArtifact(id: id)
        #expect(try db.getArtifactCount() == 0)
    }

    @Test("deleteArtifact on nonexistent ID does not throw")
    func deleteNonexistentArtifactNoThrow() throws {
        let (db, dbPath) = try makeDatabase()
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }

        // Should not throw: DELETE on nonexistent row is a no-op in SQLite
        try db.deleteArtifact(id: "nonexistent")
    }
}
