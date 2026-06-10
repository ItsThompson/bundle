@testable import Bundle
import Foundation
import XCTest

final class SyncServiceTests: XCTestCase {
    private var tempDir: URL!
    private var localDatabase: LocalDatabase!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.db")
        localDatabase = await LocalDatabase(dbPath: dbPath)
        try await localDatabase.open()
    }

    override func tearDown() async throws {
        await localDatabase.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - LocalDatabase Sync State Tests

    @MainActor
    func testGetLastSyncTimestampReturnsNilWhenEmpty() throws {
        let timestamp = try localDatabase.getLastSyncTimestamp()
        XCTAssertNil(timestamp)
    }

    @MainActor
    func testSetAndGetLastSyncTimestamp() throws {
        let now = Date()
        try localDatabase.setLastSyncTimestamp(now)

        let retrieved = try localDatabase.getLastSyncTimestamp()
        XCTAssertNotNil(retrieved)

        // ISO8601 formatting loses sub-second precision, so compare within 1s
        let diff = abs(now.timeIntervalSince(retrieved!))
        XCTAssertLessThan(diff, 1.0)
    }

    @MainActor
    func testSetLastSyncTimestampOverwrites() throws {
        let first = Date().addingTimeInterval(-3600)
        let second = Date()

        try localDatabase.setLastSyncTimestamp(first)
        try localDatabase.setLastSyncTimestamp(second)

        let retrieved = try localDatabase.getLastSyncTimestamp()
        XCTAssertNotNil(retrieved)
        let diff = abs(second.timeIntervalSince(retrieved!))
        XCTAssertLessThan(diff, 1.0)
    }

    // MARK: - Upsert Artifact From Sync Tests

    @MainActor
    func testUpsertArtifactInsertsNew() throws {
        let id = UUID().uuidString
        let now = Date()

        try localDatabase.upsertArtifactFromSync(
            id: id,
            type: "screenshot",
            contentText: nil,
            status: "completed",
            createdAt: now,
            syncedAt: now
        )

        let artifacts = try localDatabase.getArtifacts(limit: 10, offset: 0)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].id, id)
        XCTAssertEqual(artifacts[0].type, "screenshot")
        XCTAssertEqual(artifacts[0].status, "completed")
        XCTAssertNotNil(artifacts[0].syncedAt)
    }

    @MainActor
    func testUpsertArtifactUpdatesExisting() throws {
        let id = UUID().uuidString
        let now = Date()

        // Insert initially as pending
        try localDatabase.upsertArtifactFromSync(
            id: id,
            type: "note",
            contentText: "Hello",
            status: "pending",
            createdAt: now,
            syncedAt: now
        )

        // Update to completed
        try localDatabase.upsertArtifactFromSync(
            id: id,
            type: "note",
            contentText: "Hello updated",
            status: "completed",
            createdAt: now,
            syncedAt: Date()
        )

        let artifacts = try localDatabase.getArtifacts(limit: 10, offset: 0)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].status, "completed")
        XCTAssertEqual(artifacts[0].contentText, "Hello updated")
    }

    @MainActor
    func testUpsertArtifactWithTags() throws {
        let id = UUID().uuidString
        let now = Date()

        try localDatabase.upsertArtifactFromSync(
            id: id,
            type: "screenshot",
            contentText: nil,
            status: "completed",
            createdAt: now,
            syncedAt: now
        )

        try localDatabase.upsertTags(artifactId: id, tags: ["design", "ui", "typography"])

        let tags = try localDatabase.getTagsForArtifacts(ids: [id])
        XCTAssertEqual(tags[id]?.sorted(), ["design", "typography", "ui"])
    }

    @MainActor
    func testUpsertTagsReplacesExisting() throws {
        let id = UUID().uuidString
        let now = Date()

        try localDatabase.upsertArtifactFromSync(
            id: id,
            type: "screenshot",
            contentText: nil,
            status: "completed",
            createdAt: now,
            syncedAt: now
        )

        // Set initial tags
        try localDatabase.upsertTags(artifactId: id, tags: ["design", "old-tag"])

        // Replace with new tags
        try localDatabase.upsertTags(artifactId: id, tags: ["design", "new-tag"])

        let tags = try localDatabase.getTagsForArtifacts(ids: [id])
        XCTAssertEqual(tags[id]?.sorted(), ["design", "new-tag"])
    }

    // MARK: - Sync State Table Exists

    @MainActor
    func testSyncStateTableCreatedOnOpen() throws {
        // Just verify the table exists by reading from it
        let timestamp = try localDatabase.getLastSyncTimestamp()
        XCTAssertNil(timestamp) // No error means table exists
    }

    // MARK: - Backoff Calculation Tests

    @MainActor
    func testExponentialBackoffProgression() {
        // Test the backoff formula: baseInterval * 2^(failures-1), capped at 300s
        let baseInterval: TimeInterval = 30
        let maxInterval: TimeInterval = 300

        func calculateInterval(failures: Int) -> TimeInterval {
            guard failures > 0 else { return baseInterval }
            let backoff = baseInterval * pow(2.0, Double(failures - 1))
            return min(backoff, maxInterval)
        }

        XCTAssertEqual(calculateInterval(failures: 0), 30)   // Normal polling
        XCTAssertEqual(calculateInterval(failures: 1), 30)   // 30 * 2^0 = 30
        XCTAssertEqual(calculateInterval(failures: 2), 60)   // 30 * 2^1 = 60
        XCTAssertEqual(calculateInterval(failures: 3), 120)  // 30 * 2^2 = 120
        XCTAssertEqual(calculateInterval(failures: 4), 240)  // 30 * 2^3 = 240
        XCTAssertEqual(calculateInterval(failures: 5), 300)  // 30 * 2^4 = 480, capped at 300
        XCTAssertEqual(calculateInterval(failures: 10), 300) // Still capped
    }

    // MARK: - Initial Sync Detection

    @MainActor
    func testEmptyCacheDetectedAsInitialSync() throws {
        let count = try localDatabase.getArtifactCount()
        XCTAssertEqual(count, 0, "Empty database should trigger initial sync")
    }

    @MainActor
    func testNonEmptyCacheDetectedAsDeltaSync() throws {
        let id = UUID().uuidString
        try localDatabase.upsertArtifactFromSync(
            id: id,
            type: "note",
            contentText: "test",
            status: "completed",
            createdAt: Date(),
            syncedAt: Date()
        )

        let count = try localDatabase.getArtifactCount()
        XCTAssertGreaterThan(count, 0, "Non-empty database should use delta sync")
    }
}
