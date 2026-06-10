@testable import Bundle
import Foundation
import XCTest

final class ArtifactModelTests: XCTestCase {
    // MARK: - RelativeTimestampFormatter Tests

    func testJustNow() {
        let date = Date()
        let result = RelativeTimestampFormatter.format(date)
        XCTAssertEqual(result, "just now")
    }

    func testMinutesAgo() {
        let date = Date().addingTimeInterval(-120) // 2 min ago
        let result = RelativeTimestampFormatter.format(date)
        XCTAssertEqual(result, "2 min ago")
    }

    func testOneHourAgo() {
        let date = Date().addingTimeInterval(-3600) // 1 hour ago
        let result = RelativeTimestampFormatter.format(date)
        XCTAssertEqual(result, "1 hour ago")
    }

    func testMultipleHoursAgo() {
        let date = Date().addingTimeInterval(-10800) // 3 hours ago
        let result = RelativeTimestampFormatter.format(date)
        XCTAssertEqual(result, "3 hours ago")
    }

    func testYesterday() {
        let date = Date().addingTimeInterval(-86400) // 24 hours ago
        let result = RelativeTimestampFormatter.format(date)
        XCTAssertEqual(result, "yesterday")
    }

    func testDaysAgo() {
        let date = Date().addingTimeInterval(-259200) // 3 days ago
        let result = RelativeTimestampFormatter.format(date)
        XCTAssertEqual(result, "3 days ago")
    }

    func testOlderThanOneWeek() {
        let date = Date().addingTimeInterval(-864000) // 10 days ago
        let result = RelativeTimestampFormatter.format(date)
        // Falls back to DateFormatter medium style (e.g. "May 31, 2026")
        XCTAssertFalse(result.contains("ago"))
        XCTAssertFalse(result.contains("yesterday"))
        // Should be a formatted date string, not empty
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Artifact Domain Extraction Tests

    func testDomainExtractionFromLink() {
        let artifact = Artifact(
            id: "test-1",
            type: .link,
            contentPath: nil,
            contentText: "https://www.example.com/some/path",
            status: "completed",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )
        XCTAssertEqual(artifact.domain, "www.example.com")
    }

    func testDomainNilForScreenshot() {
        let artifact = Artifact(
            id: "test-2",
            type: .screenshot,
            contentPath: "2026/06/10/abc.png",
            contentText: nil,
            status: "pending",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )
        XCTAssertNil(artifact.domain)
    }

    func testDomainNilForNote() {
        let artifact = Artifact(
            id: "test-3",
            type: .note,
            contentPath: "2026/06/10/abc.md",
            contentText: "Some note content",
            status: "pending",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )
        XCTAssertNil(artifact.domain)
    }

    func testDomainNilForInvalidURL() {
        let artifact = Artifact(
            id: "test-4",
            type: .link,
            contentPath: nil,
            contentText: "not a valid url",
            status: "pending",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )
        XCTAssertNil(artifact.domain)
    }

    // MARK: - ArtifactType Tests

    func testArtifactTypeIcons() {
        XCTAssertEqual(ArtifactType.screenshot.icon, "📷")
        XCTAssertEqual(ArtifactType.note.icon, "📝")
        XCTAssertEqual(ArtifactType.link.icon, "🔗")
    }

    func testArtifactTypeRawValues() {
        XCTAssertEqual(ArtifactType(rawValue: "screenshot"), .screenshot)
        XCTAssertEqual(ArtifactType(rawValue: "note"), .note)
        XCTAssertEqual(ArtifactType(rawValue: "link"), .link)
        XCTAssertNil(ArtifactType(rawValue: "invalid"))
    }
}
