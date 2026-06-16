@testable import Bundle
import XCTest

@MainActor
final class AccountServiceTests: XCTestCase {
    private func makeAuthService(tokenStore: MockTokenStore = MockTokenStore()) -> AuthService {
        let tokenManager = TokenManager(tokenStore: tokenStore)
        return AuthService(tokenManager: tokenManager)
    }

    func testChangePasswordReturnsErrorWhenPasswordsMismatch() async {
        let authService = makeAuthService()

        let error = await authService.changePassword(
            current: "OldPass1",
            new: "NewPass1x",
            confirmation: "DifferentPass1x"
        )

        XCTAssertEqual(error, "Passwords do not match")
    }

    func testChangePasswordValidatesMinLength() async {
        let authService = makeAuthService()

        let error = await authService.changePassword(
            current: "OldPass1",
            new: "Short1",
            confirmation: "Short1"
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("8 characters"))
    }

    func testChangePasswordValidatesUppercase() async {
        let authService = makeAuthService()

        let error = await authService.changePassword(
            current: "OldPass1",
            new: "alllowercase1",
            confirmation: "alllowercase1"
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("uppercase"))
    }

    func testChangePasswordValidatesLowercase() async {
        let authService = makeAuthService()

        let error = await authService.changePassword(
            current: "OldPass1",
            new: "ALLUPPERCASE1",
            confirmation: "ALLUPPERCASE1"
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("lowercase"))
    }

    func testChangePasswordValidatesDigit() async {
        let authService = makeAuthService()

        let error = await authService.changePassword(
            current: "OldPass1",
            new: "NoDigitHere",
            confirmation: "NoDigitHere"
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("digit"))
    }

    func testChangePasswordValidatesMaxLength() async {
        let authService = makeAuthService()

        let longPassword = String(repeating: "A", count: 73)
        let error = await authService.changePassword(
            current: "OldPass1",
            new: longPassword,
            confirmation: longPassword
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("72"))
    }

    func testUpdateEmailValidatesFormat() async {
        let authService = makeAuthService()

        let error = await authService.updateEmail("not-an-email")

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("valid email"))
    }

    func testUpdateEmailRejectsEmpty() async {
        let authService = makeAuthService()

        let error = await authService.updateEmail("")

        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("valid email"))
    }
}
