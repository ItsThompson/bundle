@testable import Bundle
import XCTest

final class PostCaptureThumbnailTests: XCTestCase {

    // MARK: - Domain Extraction

    func testExtractDomainFromHTTPS() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "https://www.example.com/path"), "example.com")
    }

    func testExtractDomainFromHTTP() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "http://github.com/user/repo"), "github.com")
    }

    func testExtractDomainStripsWWWPrefix() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "https://www.apple.com"), "apple.com")
    }

    func testExtractDomainPreservesSubdomain() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "https://docs.swift.org/swift-book"), "docs.swift.org")
    }

    func testExtractDomainPreservesDeepSubdomain() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "https://developer.mozilla.org/en-US/docs"), "developer.mozilla.org")
    }

    func testExtractDomainFromBareURLFallback() {
        let result = ThumbnailTextUtils.extractDomain(from: "example.com/path/to/page")
        XCTAssertEqual(result, "example.com")
    }

    func testExtractDomainFromEmptyString() {
        let result = ThumbnailTextUtils.extractDomain(from: "")
        XCTAssertEqual(result, "")
    }

    func testExtractDomainWithPort() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "https://localhost:3000/api"), "localhost")
    }

    func testExtractDomainWithQueryString() {
        XCTAssertEqual(ThumbnailTextUtils.extractDomain(from: "https://search.brave.com/search?q=swift"), "search.brave.com")
    }

    // MARK: - Text Truncation

    func testTruncateShortTextUnchanged() {
        let text = "Line one\nLine two"
        XCTAssertEqual(ThumbnailTextUtils.truncateForPreview(text), "Line one\nLine two")
    }

    func testTruncateToThreeLines() {
        let text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        XCTAssertEqual(ThumbnailTextUtils.truncateForPreview(text), "Line 1\nLine 2\nLine 3")
    }

    func testTruncateCustomMaxLines() {
        let text = "A\nB\nC\nD"
        XCTAssertEqual(ThumbnailTextUtils.truncateForPreview(text, maxLines: 2), "A\nB")
    }

    func testTruncateSingleLine() {
        let text = "Just one line"
        XCTAssertEqual(ThumbnailTextUtils.truncateForPreview(text), "Just one line")
    }

    func testTruncateEmptyString() {
        XCTAssertEqual(ThumbnailTextUtils.truncateForPreview(""), "")
    }

    func testTruncatePreservesWhitespace() {
        let text = "  indented\n    more indented\nnormal"
        XCTAssertEqual(ThumbnailTextUtils.truncateForPreview(text), "  indented\n    more indented\nnormal")
    }

    // MARK: - CopyableContent Derivation

    func testScreenshotCopyableContentIsImageFile() {
        let full = URL(fileURLWithPath: "/tmp/abc.png")
        let thumb = URL(fileURLWithPath: "/tmp/abc_thumb.png")
        let content = ThumbnailContent.screenshot(fullPath: full, thumbnailPath: thumb)

        if case .imageFile(let primary, let fallback) = content.copyableValue {
            XCTAssertEqual(primary, full)
            XCTAssertEqual(fallback, thumb)
        } else {
            XCTFail("Expected .imageFile case")
        }
    }

    func testNoteCopyableContentIsText() {
        let content = ThumbnailContent.note(text: "Hello world")

        if case .text(let value) = content.copyableValue {
            XCTAssertEqual(value, "Hello world")
        } else {
            XCTFail("Expected .text case")
        }
    }

    func testLinkCopyableContentIsURL() {
        let content = ThumbnailContent.link(url: "https://swift.org")

        if case .text(let value) = content.copyableValue {
            XCTAssertEqual(value, "https://swift.org")
        } else {
            XCTFail("Expected .text case")
        }
    }
}
