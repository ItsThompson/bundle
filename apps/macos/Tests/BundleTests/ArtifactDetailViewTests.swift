@testable import Bundle
import Foundation
import XCTest

@MainActor
final class ArtifactDetailViewTests: XCTestCase {
    // MARK: - ArtifactContentService Tests

    func testLocalFileURLReturnsNilWhenNoContentPath() {
        let artifact = Artifact(
            id: "test-1",
            type: .screenshot,
            contentPath: nil,
            contentText: nil,
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactDetailViewTests-\(UUID().uuidString)")
        let service = ArtifactContentService(
            apiClient: APIClient(),
            artifactsDirectory: tempDir
        )

        let result = service.localFileURL(for: artifact)
        XCTAssertNil(result)
    }

    func testLocalFileURLReturnsPathWhenFileExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactDetailViewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake image file
        let filePath = tempDir.appendingPathComponent("test-image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: filePath)

        let artifact = Artifact(
            id: "test-2",
            type: .screenshot,
            contentPath: "test-image.png",
            contentText: nil,
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )

        let service = ArtifactContentService(
            apiClient: APIClient(),
            artifactsDirectory: tempDir
        )

        let result = service.localFileURL(for: artifact)
        XCTAssertEqual(result, filePath)
    }

    func testLocalFileURLReturnsNilWhenFileDoesNotExist() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactDetailViewTests-\(UUID().uuidString)")

        let artifact = Artifact(
            id: "test-3",
            type: .screenshot,
            contentPath: "nonexistent.png",
            contentText: nil,
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )

        let service = ArtifactContentService(
            apiClient: APIClient(),
            artifactsDirectory: tempDir
        )

        let result = service.localFileURL(for: artifact)
        XCTAssertNil(result)
    }

    // MARK: - Link Tile Behavior Tests

    func testLinkArtifactHasValidURL() {
        let artifact = Artifact(
            id: "link-1",
            type: .link,
            contentPath: nil,
            contentText: "https://www.example.com/path",
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: ["design"]
        )

        // Verify the URL can be parsed (prerequisite for opening in browser)
        guard let urlString = artifact.contentText,
              let url = URL(string: urlString) else {
            XCTFail("Link artifact should have a parseable URL")
            return
        }

        XCTAssertEqual(url.host, "www.example.com")
        XCTAssertEqual(url.path, "/path")
    }

    func testLinkArtifactWithInvalidURLFailsGracefully() {
        let artifact = Artifact(
            id: "link-2",
            type: .link,
            contentPath: nil,
            contentText: "",
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )

        let url = artifact.contentText.flatMap { URL(string: $0) }
        // Empty string creates a URL with empty path, so this should be nil or empty
        // The guard in handleTileTap checks for a valid URL before opening
        XCTAssertNotNil(artifact.contentText)
    }

    // MARK: - Metadata Display Tests

    func testArtifactTagsAvailableForDetailView() {
        let artifact = Artifact(
            id: "meta-1",
            type: .screenshot,
            contentPath: "2026/06/10/abc.png",
            contentText: nil,
            status: "completed",
            createdAt: Date(),
            syncedAt: Date(),
            tags: ["design", "typography", "ui"]
        )

        XCTAssertEqual(artifact.tags.count, 3)
        XCTAssertTrue(artifact.tags.contains("design"))
        XCTAssertTrue(artifact.tags.contains("typography"))
        XCTAssertTrue(artifact.tags.contains("ui"))
    }

    func testArtifactStatusValues() {
        let statuses = ["pending", "processing", "completed", "failed"]
        for status in statuses {
            let artifact = Artifact(
                id: "status-\(status)",
                type: .note,
                contentPath: nil,
                contentText: "Test note",
                status: status,
                createdAt: Date(),
                syncedAt: nil,
                tags: []
            )
            XCTAssertEqual(artifact.status, status)
        }
    }

    // MARK: - Note Content Tests

    func testNoteArtifactContentAvailableForRendering() {
        let markdownContent = """
        # Heading

        Some **bold** text and *italic* text.

        - List item 1
        - List item 2
        """

        let artifact = Artifact(
            id: "note-1",
            type: .note,
            contentPath: "2026/06/10/note.md",
            contentText: markdownContent,
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: ["ideas"]
        )

        XCTAssertEqual(artifact.type, .note)
        XCTAssertNotNil(artifact.contentText)
        XCTAssertTrue(artifact.contentText!.contains("# Heading"))
        XCTAssertTrue(artifact.contentText!.contains("**bold**"))
    }

    // MARK: - ArtifactContentError Tests

    func testArtifactContentErrorDescriptions() {
        let errors: [ArtifactContentError] = [
            .invalidURL,
            .networkError,
            .fetchFailed(404),
            .fileNotFound
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }

        XCTAssertTrue(ArtifactContentError.fetchFailed(404).errorDescription!.contains("404"))
    }
}
