@testable import Bundle
import XCTest

final class LinkInputTests: XCTestCase {

    // MARK: - Valid URLs

    @MainActor
    func testAcceptsValidHttpsURL() {
        XCTAssertTrue(LinkInput.isValidURL("https://example.com"))
    }

    @MainActor
    func testAcceptsValidHttpURL() {
        XCTAssertTrue(LinkInput.isValidURL("http://example.com"))
    }

    @MainActor
    func testAcceptsURLWithPath() {
        XCTAssertTrue(LinkInput.isValidURL("https://example.com/path/to/page"))
    }

    @MainActor
    func testAcceptsURLWithQueryParams() {
        XCTAssertTrue(LinkInput.isValidURL("https://example.com/search?q=swift&page=1"))
    }

    @MainActor
    func testAcceptsURLWithPort() {
        XCTAssertTrue(LinkInput.isValidURL("http://localhost:8080/api"))
    }

    @MainActor
    func testAcceptsURLWithFragment() {
        XCTAssertTrue(LinkInput.isValidURL("https://docs.swift.org/guide#section"))
    }

    @MainActor
    func testAcceptsMixedCaseScheme() {
        XCTAssertTrue(LinkInput.isValidURL("HTTPS://Example.com"))
    }

    @MainActor
    func testAcceptsURLWithWhitespacePadding() {
        XCTAssertTrue(LinkInput.isValidURL("  https://example.com  "))
    }

    // MARK: - Invalid URLs

    @MainActor
    func testRejectsEmptyString() {
        XCTAssertFalse(LinkInput.isValidURL(""))
    }

    @MainActor
    func testRejectsWhitespaceOnly() {
        XCTAssertFalse(LinkInput.isValidURL("   "))
    }

    @MainActor
    func testRejectsMissingScheme() {
        XCTAssertFalse(LinkInput.isValidURL("example.com"))
    }

    @MainActor
    func testRejectsFTPScheme() {
        XCTAssertFalse(LinkInput.isValidURL("ftp://files.example.com"))
    }

    @MainActor
    func testRejectsFileScheme() {
        XCTAssertFalse(LinkInput.isValidURL("file:///Users/test/doc.txt"))
    }

    @MainActor
    func testRejectsSchemeOnly() {
        XCTAssertFalse(LinkInput.isValidURL("https://"))
    }

    @MainActor
    func testRejectsRandomText() {
        XCTAssertFalse(LinkInput.isValidURL("not a url at all"))
    }

    @MainActor
    func testRejectsJavascriptScheme() {
        XCTAssertFalse(LinkInput.isValidURL("javascript:alert(1)"))
    }

    // MARK: - Max Length

    @MainActor
    func testAcceptsURLAtMaxLength() {
        let baseURL = "https://example.com/"
        let padding = String(repeating: "a", count: LinkInput.maxURLLength - baseURL.count)
        let url = baseURL + padding
        XCTAssertEqual(url.count, LinkInput.maxURLLength)
        XCTAssertTrue(LinkInput.isValidURL(url))
    }

    @MainActor
    func testRejectsURLExceedingMaxLength() {
        let baseURL = "https://example.com/"
        let padding = String(repeating: "a", count: LinkInput.maxURLLength - baseURL.count + 1)
        let url = baseURL + padding
        XCTAssertEqual(url.count, LinkInput.maxURLLength + 1)
        XCTAssertFalse(LinkInput.isValidURL(url))
    }

    // MARK: - Max Length Constant

    @MainActor
    func testMaxURLLengthIs2048() {
        XCTAssertEqual(LinkInput.maxURLLength, 2048)
    }
}
