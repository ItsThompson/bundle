import Foundation

/// Actor that serializes all token operations.
/// Ensures only one refresh is in-flight at a time: concurrent callers await the same result.
/// Uses the existing `TokenStore` protocol (defined in KeychainManager.swift) for storage.
actor TokenManager {
    private let tokenStore: TokenStore
    private let baseURL: String
    private let session: URLSession

    /// In-flight refresh task: subsequent callers await this instead of starting their own.
    private var refreshTask: Task<Bool, Never>?

    init(
        tokenStore: TokenStore = KeychainManager(),
        baseURL: String = APIClient.defaultBaseURL,
        session: URLSession = .ephemeral
    ) {
        self.tokenStore = tokenStore
        self.baseURL = baseURL
        self.session = session
    }

    /// Get the current access token, or nil if not authenticated.
    func getAccessToken() -> String? {
        tokenStore.getAccessToken()
    }

    /// Get the current refresh token, or nil if not authenticated.
    func getRefreshToken() -> String? {
        tokenStore.getRefreshToken()
    }

    /// Attempt to refresh tokens. Coalesces concurrent calls into a single network request.
    /// Returns true if refresh succeeded, false if session is expired.
    func refreshIfNeeded() async -> Bool {
        if let existingTask = refreshTask {
            return await existingTask.value
        }

        let task = Task<Bool, Never> {
            await performRefresh()
        }

        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Store new tokens (called after login/register).
    func storeTokens(access: String, refresh: String) throws {
        try tokenStore.saveTokens(access: access, refresh: refresh)
    }

    /// Clear all tokens (called only by AuthService.logout).
    func clearTokens() {
        tokenStore.deleteTokens()
    }

    // MARK: - Private

    private func performRefresh() async -> Bool {
        guard let refreshToken = tokenStore.getRefreshToken() else {
            return false
        }

        guard let url = URL(string: "\(baseURL)/api/auth/refresh") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["refresh_token": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                // Refresh failed: do NOT delete tokens here.
                // AuthService owns the logout decision.
                return false
            }

            let decoder = JSONDecoder()
            let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
            try tokenStore.saveTokens(
                access: tokenResponse.accessToken,
                refresh: tokenResponse.refreshToken
            )
            return true
        } catch {
            return false
        }
    }
}
