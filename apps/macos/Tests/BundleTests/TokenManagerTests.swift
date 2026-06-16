@testable import Bundle
import Foundation
import XCTest

// MARK: - Mock URLProtocol for intercepting network requests

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.lock.unlock()

        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requestCount = 0
        requestHandler = nil
        lock.unlock()
    }
}

// MARK: - Tests

final class TokenManagerTests: XCTestCase {
    private var tokenStore: MockTokenStore!
    private var session: URLSession!
    private var tokenManager: TokenManager!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        tokenStore = MockTokenStore()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        tokenManager = TokenManager(
            tokenStore: tokenStore,
            baseURL: "http://localhost:8018",
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Basic Token Operations

    func testGetAccessTokenReturnsStoredToken() async throws {
        try tokenStore.saveTokens(access: "access_123", refresh: "refresh_456")

        let token = await tokenManager.getAccessToken()
        XCTAssertEqual(token, "access_123")
    }

    func testGetAccessTokenReturnsNilWhenEmpty() async {
        let token = await tokenManager.getAccessToken()
        XCTAssertNil(token)
    }

    func testGetRefreshTokenReturnsStoredToken() async throws {
        try tokenStore.saveTokens(access: "access_123", refresh: "refresh_456")

        let token = await tokenManager.getRefreshToken()
        XCTAssertEqual(token, "refresh_456")
    }

    func testStoreTokensSavesToStore() async throws {
        try await tokenManager.storeTokens(access: "new_access", refresh: "new_refresh")

        XCTAssertEqual(tokenStore.getAccessToken(), "new_access")
        XCTAssertEqual(tokenStore.getRefreshToken(), "new_refresh")
    }

    func testClearTokensRemovesAll() async throws {
        try tokenStore.saveTokens(access: "a", refresh: "r")

        await tokenManager.clearTokens()

        XCTAssertNil(tokenStore.getAccessToken())
        XCTAssertNil(tokenStore.getRefreshToken())
    }

    // MARK: - Refresh Success

    func testRefreshIfNeededStoresNewTokensOnSuccess() async throws {
        try tokenStore.saveTokens(access: "old_access", refresh: "old_refresh")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/refresh")
            XCTAssertEqual(request.httpMethod, "POST")

            let responseBody = """
            {"access_token": "new_access", "refresh_token": "new_refresh"}
            """.data(using: .utf8)!

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseBody)
        }

        let result = await tokenManager.refreshIfNeeded()

        XCTAssertTrue(result)
        XCTAssertEqual(tokenStore.getAccessToken(), "new_access")
        XCTAssertEqual(tokenStore.getRefreshToken(), "new_refresh")
    }

    // MARK: - Refresh Failure Does NOT Delete Tokens

    func testRefreshFailureDoesNotDeleteTokens() async throws {
        try tokenStore.saveTokens(access: "existing_access", refresh: "existing_refresh")

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let result = await tokenManager.refreshIfNeeded()

        XCTAssertFalse(result)
        // Critical: tokens must NOT be deleted on refresh failure
        XCTAssertEqual(tokenStore.getAccessToken(), "existing_access")
        XCTAssertEqual(tokenStore.getRefreshToken(), "existing_refresh")
        XCTAssertEqual(tokenStore.deleteCallCount, 0)
    }

    // MARK: - Refresh Without Refresh Token

    func testRefreshIfNeededReturnsFalseWhenNoRefreshToken() async {
        // No tokens stored
        let result = await tokenManager.refreshIfNeeded()
        XCTAssertFalse(result)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: - Concurrent Refresh Coalescing

    func testFiveConcurrentRefreshCallsResultInExactlyOneNetworkRequest() async throws {
        try tokenStore.saveTokens(access: "old_access", refresh: "old_refresh")

        // Add a small delay to the handler to ensure concurrent requests overlap
        MockURLProtocol.requestHandler = { request in
            // Simulate network latency
            Thread.sleep(forTimeInterval: 0.1)

            let responseBody = """
            {"access_token": "refreshed_access", "refresh_token": "refreshed_refresh"}
            """.data(using: .utf8)!

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseBody)
        }

        // Launch 5 concurrent refresh calls
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await self.tokenManager.refreshIfNeeded()
                }
            }

            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // All 5 should succeed
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0 == true })

        // Exactly 1 network request should have been made
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    // MARK: - Refresh Failure Propagates to All Waiters

    func testRefreshFailurePropagesToAllConcurrentWaiters() async throws {
        try tokenStore.saveTokens(access: "old_access", refresh: "old_refresh")

        MockURLProtocol.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.1)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        // Launch 5 concurrent refresh calls
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await self.tokenManager.refreshIfNeeded()
                }
            }

            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // All 5 should get false (failure)
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0 == false })

        // Only 1 network request
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // Tokens NOT deleted
        XCTAssertEqual(tokenStore.deleteCallCount, 0)
    }

    // MARK: - Sequential Refreshes After Completion

    func testSequentialRefreshesAfterCompletionMakeNewRequests() async throws {
        try tokenStore.saveTokens(access: "old_access", refresh: "old_refresh")

        var callIndex = 0
        MockURLProtocol.requestHandler = { request in
            callIndex += 1
            let responseBody = """
            {"access_token": "access_\(callIndex)", "refresh_token": "refresh_\(callIndex)"}
            """.data(using: .utf8)!

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseBody)
        }

        let result1 = await tokenManager.refreshIfNeeded()
        XCTAssertTrue(result1)

        let result2 = await tokenManager.refreshIfNeeded()
        XCTAssertTrue(result2)

        // Two sequential calls should make two separate requests
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }
}
