@testable import Bundle
import Foundation
import XCTest

final class TagFilterTests: XCTestCase {
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

    // MARK: - Helpers

    @MainActor
    private func insertArtifact(id: String, type: String = "screenshot", tags: [String] = []) throws {
        try localDatabase.insertArtifact(
            id: id,
            type: type,
            contentPath: nil,
            contentText: nil,
            status: "completed",
            createdAt: Date()
        )
        if !tags.isEmpty {
            try localDatabase.upsertTags(artifactId: id, tags: tags)
        }
    }

    // MARK: - getTagsWithCounts Tests

    @MainActor
    func testGetTagsWithCountsReturnsEmptyWhenNoTags() throws {
        let tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 0)
    }

    @MainActor
    func testGetTagsWithCountsReturnsSingleTag() throws {
        try insertArtifact(id: "a1", tags: ["design"])
        try insertArtifact(id: "a2", tags: ["design"])

        let tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].name, "design")
        XCTAssertEqual(tags[0].count, 2)
    }

    @MainActor
    func testGetTagsWithCountsOrderedByCountDescending() throws {
        try insertArtifact(id: "a1", tags: ["design", "ui"])
        try insertArtifact(id: "a2", tags: ["design", "code"])
        try insertArtifact(id: "a3", tags: ["design"])
        try insertArtifact(id: "a4", tags: ["code"])

        let tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 3)

        // design: 3, code: 2, ui: 1
        XCTAssertEqual(tags[0].name, "design")
        XCTAssertEqual(tags[0].count, 3)
        XCTAssertEqual(tags[1].name, "code")
        XCTAssertEqual(tags[1].count, 2)
        XCTAssertEqual(tags[2].name, "ui")
        XCTAssertEqual(tags[2].count, 1)
    }

    @MainActor
    func testGetTagsWithCountsHandlesMultipleTagsPerArtifact() throws {
        try insertArtifact(id: "a1", tags: ["design", "typography", "ui"])

        let tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 3)
        // All have count 1
        for tag in tags {
            XCTAssertEqual(tag.count, 1)
        }
    }

    // MARK: - getArtifactIdsForTag Tests

    @MainActor
    func testGetArtifactIdsForTagReturnsMatchingIds() throws {
        try insertArtifact(id: "a1", tags: ["design"])
        try insertArtifact(id: "a2", tags: ["design", "code"])
        try insertArtifact(id: "a3", tags: ["code"])

        let designIds = try localDatabase.getArtifactIdsForTag(name: "design")
        XCTAssertEqual(Set(designIds), Set(["a1", "a2"]))
    }

    @MainActor
    func testGetArtifactIdsForTagReturnsEmptyForNonexistentTag() throws {
        try insertArtifact(id: "a1", tags: ["design"])

        let ids = try localDatabase.getArtifactIdsForTag(name: "nonexistent")
        XCTAssertEqual(ids.count, 0)
    }

    // MARK: - getArtifactsForTag Tests

    @MainActor
    func testGetArtifactsForTagReturnsFilteredArtifacts() throws {
        try insertArtifact(id: "a1", tags: ["design"])
        try insertArtifact(id: "a2", tags: ["design", "code"])
        try insertArtifact(id: "a3", tags: ["code"])
        try insertArtifact(id: "a4", tags: [])

        let designArtifacts = try localDatabase.getArtifactsForTag(
            tagName: "design", limit: 10, offset: 0
        )
        XCTAssertEqual(designArtifacts.count, 2)
        let ids = Set(designArtifacts.map { $0.id })
        XCTAssertEqual(ids, Set(["a1", "a2"]))
    }

    @MainActor
    func testGetArtifactsForTagRespectsPagination() throws {
        // Insert 5 artifacts with "design" tag
        for i in 1...5 {
            try insertArtifact(id: "a\(i)", tags: ["design"])
        }

        let firstPage = try localDatabase.getArtifactsForTag(
            tagName: "design", limit: 2, offset: 0
        )
        XCTAssertEqual(firstPage.count, 2)

        let secondPage = try localDatabase.getArtifactsForTag(
            tagName: "design", limit: 2, offset: 2
        )
        XCTAssertEqual(secondPage.count, 2)

        let thirdPage = try localDatabase.getArtifactsForTag(
            tagName: "design", limit: 2, offset: 4
        )
        XCTAssertEqual(thirdPage.count, 1)
    }

    @MainActor
    func testGetArtifactsForTagReturnsEmptyForNonexistentTag() throws {
        try insertArtifact(id: "a1", tags: ["design"])

        let results = try localDatabase.getArtifactsForTag(
            tagName: "nonexistent", limit: 10, offset: 0
        )
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - getArtifactCountForTag Tests

    @MainActor
    func testGetArtifactCountForTagReturnsCorrectCount() throws {
        try insertArtifact(id: "a1", tags: ["design"])
        try insertArtifact(id: "a2", tags: ["design", "code"])
        try insertArtifact(id: "a3", tags: ["code"])

        let designCount = try localDatabase.getArtifactCountForTag(tagName: "design")
        XCTAssertEqual(designCount, 2)

        let codeCount = try localDatabase.getArtifactCountForTag(tagName: "code")
        XCTAssertEqual(codeCount, 2)
    }

    @MainActor
    func testGetArtifactCountForTagReturnsZeroForNonexistent() throws {
        let count = try localDatabase.getArtifactCountForTag(tagName: "nonexistent")
        XCTAssertEqual(count, 0)
    }

    // MARK: - Tag Update After Sync Tests

    @MainActor
    func testTagCountsUpdateAfterUpsert() throws {
        try insertArtifact(id: "a1", tags: ["design"])

        var tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].count, 1)

        // Add more artifacts with the same tag
        try insertArtifact(id: "a2", tags: ["design"])

        tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags[0].count, 2)
    }

    @MainActor
    func testTagCountsUpdateWhenTagsRemoved() throws {
        try insertArtifact(id: "a1", tags: ["design", "code"])

        var tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 2)

        // Replace tags: remove "code", keep "design"
        try localDatabase.upsertTags(artifactId: "a1", tags: ["design"])

        tags = try localDatabase.getTagsWithCounts()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].name, "design")
    }

    // MARK: - TagItem Model Tests

    func testTagItemIdentity() {
        let tag = TagItem(name: "design", count: 5)
        XCTAssertEqual(tag.id, "design")
    }

    func testTagItemEquality() {
        let tag1 = TagItem(name: "design", count: 5)
        let tag2 = TagItem(name: "design", count: 5)
        let tag3 = TagItem(name: "code", count: 3)
        XCTAssertEqual(tag1, tag2)
        XCTAssertNotEqual(tag1, tag3)
    }
}
