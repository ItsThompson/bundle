@testable import Bundle
import XCTest

final class PostCaptureThumbnailTests: XCTestCase {

    // MARK: - Domain Extraction

    func testExtractDomainFromHTTPS() {
        XCTAssertEqual(extractDomain(from: "https://www.example.com/path"), "example.com")
    }

    func testExtractDomainFromHTTP() {
        XCTAssertEqual(extractDomain(from: "http://github.com/user/repo"), "github.com")
    }

    func testExtractDomainWithWWWPrefix() {
        XCTAssertEqual(extractDomain(from: "https://www.apple.com"), "apple.com")
    }

    func testExtractDomainWithoutWWW() {
        XCTAssertEqual(extractDomain(from: "https://docs.swift.org/swift-book"), "docs.swift.org")
    }

    func testExtractDomainWithSubdomain() {
        XCTAssertEqual(extractDomain(from: "https://developer.mozilla.org/en-US/docs"), "developer.mozilla.org")
    }

    func testExtractDomainFromBareURL() {
        // No scheme: fallback parser
        let result = extractDomain(from: "example.com/path/to/page")
        XCTAssertEqual(result, "example.com")
    }

    func testExtractDomainFromEmptyString() {
        let result = extractDomain(from: "")
        XCTAssertEqual(result, "")
    }

    func testExtractDomainWithPort() {
        XCTAssertEqual(extractDomain(from: "https://localhost:3000/api"), "localhost")
    }

    // MARK: - ThumbnailContent Type Coverage

    func testThumbnailContentScreenshot() {
        let url = URL(fileURLWithPath: "/tmp/test_thumb.png")
        let content = ThumbnailContent.screenshot(thumbnailPath: url)

        if case .screenshot(let path) = content {
            XCTAssertEqual(path, url)
        } else {
            XCTFail("Expected .screenshot case")
        }
    }

    func testThumbnailContentNote() {
        let content = ThumbnailContent.note(text: "Line 1\nLine 2\nLine 3\nLine 4")

        if case .note(let text) = content {
            XCTAssertTrue(text.hasPrefix("Line 1"))
            XCTAssertTrue(text.contains("Line 4"))
        } else {
            XCTFail("Expected .note case")
        }
    }

    func testThumbnailContentLink() {
        let content = ThumbnailContent.link(url: "https://swift.org")

        if case .link(let url) = content {
            XCTAssertEqual(url, "https://swift.org")
        } else {
            XCTFail("Expected .link case")
        }
    }
}
