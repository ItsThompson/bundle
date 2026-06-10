@testable import Bundle
import Foundation
import XCTest

final class AuthModelTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testDecodeAuthResponse() throws {
        let json = """
        {
            "user": {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "email": "test@example.com",
                "created_at": "2026-06-10T12:00:00Z",
                "updated_at": "2026-06-10T12:00:00Z"
            },
            "access_token": "eyJ.access.token",
            "refresh_token": "eyJ.refresh.token"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(AuthResponse.self, from: json)

        XCTAssertEqual(response.user.email, "test@example.com")
        XCTAssertEqual(response.user.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(response.accessToken, "eyJ.access.token")
        XCTAssertEqual(response.refreshToken, "eyJ.refresh.token")
    }

    func testDecodeTokenResponse() throws {
        let json = """
        {
            "access_token": "new_access",
            "refresh_token": "new_refresh"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(TokenResponse.self, from: json)

        XCTAssertEqual(response.accessToken, "new_access")
        XCTAssertEqual(response.refreshToken, "new_refresh")
    }

    func testDecodeUserResponse() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "email": "user@example.com",
            "created_at": "2026-06-10T08:30:00Z",
            "updated_at": "2026-06-10T09:00:00Z"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(UserResponse.self, from: json)

        XCTAssertEqual(response.email, "user@example.com")
        XCTAssertEqual(response.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
    }

    func testDecodeErrorResponse() throws {
        let json = """
        {"detail": "Invalid credentials"}
        """.data(using: .utf8)!

        let response = try decoder.decode(APIErrorResponse.self, from: json)

        XCTAssertEqual(response.detail, "Invalid credentials")
    }

    func testEncodeRegisterRequest() throws {
        let request = RegisterRequest(email: "test@example.com", password: "Secret123")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: String]

        XCTAssertEqual(dict["email"], "test@example.com")
        XCTAssertEqual(dict["password"], "Secret123")
    }

    func testEncodeRefreshRequestUsesSnakeCase() throws {
        let request = RefreshRequest(refreshToken: "my_token")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: String]

        XCTAssertEqual(dict["refresh_token"], "my_token")
        XCTAssertNil(dict["refreshToken"])
    }
}
