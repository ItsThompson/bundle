@testable import Bundle
import XCTest

final class MockTokenStore: TokenStore {
    private var accessToken: String?
    private var refreshToken: String?
    var saveCallCount = 0
    var deleteCallCount = 0

    func saveTokens(access: String, refresh: String) throws {
        accessToken = access
        refreshToken = refresh
        saveCallCount += 1
    }

    func getAccessToken() -> String? {
        accessToken
    }

    func getRefreshToken() -> String? {
        refreshToken
    }

    func deleteTokens() {
        accessToken = nil
        refreshToken = nil
        deleteCallCount += 1
    }
}

final class TokenStoreTests: XCTestCase {
    func testSaveAndRetrieve() throws {
        let store = MockTokenStore()
        try store.saveTokens(access: "access_abc", refresh: "refresh_xyz")

        XCTAssertEqual(store.getAccessToken(), "access_abc")
        XCTAssertEqual(store.getRefreshToken(), "refresh_xyz")
    }

    func testDeleteClearsBoth() throws {
        let store = MockTokenStore()
        try store.saveTokens(access: "a", refresh: "r")

        store.deleteTokens()

        XCTAssertNil(store.getAccessToken())
        XCTAssertNil(store.getRefreshToken())
    }

    func testOverwriteReplacesPrevious() throws {
        let store = MockTokenStore()
        try store.saveTokens(access: "old_a", refresh: "old_r")
        try store.saveTokens(access: "new_a", refresh: "new_r")

        XCTAssertEqual(store.getAccessToken(), "new_a")
        XCTAssertEqual(store.getRefreshToken(), "new_r")
    }

    func testEmptyByDefault() {
        let store = MockTokenStore()
        XCTAssertNil(store.getAccessToken())
        XCTAssertNil(store.getRefreshToken())
    }
}
