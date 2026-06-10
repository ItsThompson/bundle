@testable import Bundle
import XCTest

final class PasswordValidationTests: XCTestCase {
    private var authService: AuthService!

    @MainActor
    override func setUp() {
        authService = AuthService()
    }

    @MainActor
    func testAcceptsValidPassword() {
        XCTAssertNil(authService.validatePasswordLocally("Abcdef1x"))
    }

    @MainActor
    func testRejectsTooShort() {
        let result = authService.validatePasswordLocally("Ab1defg")
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("at least 8"))
    }

    @MainActor
    func testRejectsTooLong() {
        let long = String(repeating: "Aa1", count: 25) // 75 chars
        let result = authService.validatePasswordLocally(long)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("at most 72"))
    }

    @MainActor
    func testRejectsMissingUppercase() {
        let result = authService.validatePasswordLocally("abcdefg1")
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("uppercase"))
    }

    @MainActor
    func testRejectsMissingLowercase() {
        let result = authService.validatePasswordLocally("ABCDEFG1")
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("lowercase"))
    }

    @MainActor
    func testRejectsMissingDigit() {
        let result = authService.validatePasswordLocally("Abcdefgh")
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("digit"))
    }

    @MainActor
    func testAcceptsExactlyEightChars() {
        XCTAssertNil(authService.validatePasswordLocally("Abcdef1!"))
    }

    @MainActor
    func testAcceptsExactlySeventyTwoChars() {
        let pw = String(repeating: "a", count: 70) + "A1"
        XCTAssertNil(authService.validatePasswordLocally(pw))
    }
}
