import Foundation

/// Handles authentication operations: register, login, refresh, logout, and session validation.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var currentUser: UserResponse?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let apiClient: APIClient
    private let tokenStore: TokenStore

    init(apiClient: APIClient = APIClient(), tokenStore: TokenStore = KeychainManager()) {
        self.apiClient = apiClient
        self.tokenStore = tokenStore
    }

    // MARK: - Session Restoration

    /// Attempt to restore a session from stored tokens by validating with /me.
    func restoreSession() async {
        guard tokenStore.getAccessToken() != nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let user: UserResponse = try await apiClient.request(
                method: .get,
                path: "/api/auth/me"
            )
            currentUser = user
            isAuthenticated = true
        } catch {
            // Tokens invalid or expired beyond refresh: clear state
            tokenStore.deleteTokens()
            currentUser = nil
            isAuthenticated = false
        }
    }

    // MARK: - Register

    func register(email: String, password: String) async {
        errorMessage = nil

        if let validationError = validateEmail(email) {
            errorMessage = validationError
            return
        }

        if let validationError = validatePasswordLocally(password) {
            errorMessage = validationError
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response: AuthResponse = try await apiClient.request(
                method: .post,
                path: "/api/auth/register",
                body: RegisterRequest(email: email, password: password),
                authenticated: false
            )
            try tokenStore.saveTokens(access: response.accessToken, refresh: response.refreshToken)
            currentUser = response.user
            isAuthenticated = true
        } catch let error as APIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "An unexpected error occurred"
        }
    }

    // MARK: - Login

    func login(email: String, password: String) async {
        errorMessage = nil

        if let validationError = validateEmail(email) {
            errorMessage = validationError
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response: AuthResponse = try await apiClient.request(
                method: .post,
                path: "/api/auth/login",
                body: LoginRequest(email: email, password: password),
                authenticated: false
            )
            try tokenStore.saveTokens(access: response.accessToken, refresh: response.refreshToken)
            currentUser = response.user
            isAuthenticated = true
        } catch let error as APIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "An unexpected error occurred"
        }
    }

    // MARK: - Logout

    func logout() async {
        isLoading = true
        defer { isLoading = false }

        // Best-effort: notify backend, but always clear local state
        if let refreshToken = tokenStore.getRefreshToken() {
            do {
                try await apiClient.requestVoid(
                    method: .post,
                    path: "/api/auth/logout",
                    body: RefreshRequest(refreshToken: refreshToken)
                )
            } catch {
                print("[Bundle] Logout request failed (clearing locally): \(error.localizedDescription)")
            }
        }

        tokenStore.deleteTokens()
        currentUser = nil
        isAuthenticated = false
        errorMessage = nil
    }

    // MARK: - Update Email

    /// Update the current user's email address. Returns nil on success, error message on failure.
    func updateEmail(_ newEmail: String) async -> String? {
        if let validationError = validateEmail(newEmail) {
            return validationError
        }

        do {
            let user: UserResponse = try await apiClient.request(
                method: .put,
                path: "/api/auth/me",
                body: UpdateEmailRequest(email: newEmail)
            )
            currentUser = user
            return nil
        } catch let error as APIError {
            return error.localizedDescription
        } catch {
            return "An unexpected error occurred"
        }
    }

    // MARK: - Change Password

    /// Change password. On success: saves new tokens, other sessions invalidated.
    /// Returns nil on success, error message on failure.
    func changePassword(current: String, new newPassword: String, confirmation: String) async -> String? {
        if newPassword != confirmation {
            return "Passwords do not match"
        }

        if let validationError = validatePasswordLocally(newPassword) {
            return validationError
        }

        do {
            let response: AuthResponse = try await apiClient.request(
                method: .post,
                path: "/api/auth/me/password",
                body: ChangePasswordRequest(currentPassword: current, newPassword: newPassword)
            )
            // Save new tokens (old ones are now revoked server-side)
            try tokenStore.saveTokens(access: response.accessToken, refresh: response.refreshToken)
            currentUser = response.user
            return nil
        } catch let error as APIError {
            return error.localizedDescription
        } catch {
            return "An unexpected error occurred"
        }
    }

    // MARK: - Password Validation

    /// Client-side email format validation.
    func validateEmail(_ email: String) -> String? {
        let pattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
        guard email.range(of: pattern, options: .regularExpression) != nil else {
            return "Please enter a valid email address"
        }
        return nil
    }

    /// Client-side password validation: 8-72 chars, 1 upper, 1 lower, 1 digit.
    func validatePasswordLocally(_ password: String) -> String? {
        if password.count < 8 {
            return "Password must be at least 8 characters"
        }
        if password.count > 72 {
            return "Password must be at most 72 characters"
        }
        if !password.contains(where: { $0.isUppercase }) {
            return "Password must contain at least one uppercase letter"
        }
        if !password.contains(where: { $0.isLowercase }) {
            return "Password must contain at least one lowercase letter"
        }
        if !password.contains(where: { $0.isNumber }) {
            return "Password must contain at least one digit"
        }
        return nil
    }
}
