import Foundation

/// Errors that can occur during API requests.
enum APIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case conflict(String)
    case validationError(String)
    case rateLimited
    case serverError(Int, String)
    case networkError(Error)
    case decodingError(Error)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .unauthorized:
            return "Invalid credentials"
        case .conflict(let detail):
            return detail
        case .validationError(let detail):
            return detail
        case .rateLimited:
            return "Too many attempts. Please try again later."
        case .serverError(let code, let detail):
            return "Server error (\(code)): \(detail)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError:
            return "Failed to parse server response"
        case .sessionExpired:
            return "Session expired. Please log in again."
        }
    }
}

/// HTTP method for API requests.
enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// URLSession-based API client with automatic Bearer token injection and 401 refresh retry.
final class APIClient {
    private let baseURL: String
    private let session: URLSession
    private let tokenStore: TokenStore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: String = APIClient.defaultBaseURL,
        tokenStore: TokenStore = KeychainManager(),
        session: URLSession = .ephemeral
    ) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.session = session

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// Default backend URL: production hardcoded, overridable via BUNDLE_API_URL env.
    static var defaultBaseURL: String {
        ProcessInfo.processInfo.environment["BUNDLE_API_URL"] ?? "https://bundle-api.thompsnt.dev"
    }

    // MARK: - Public Request Method

    /// Make an authenticated API request with automatic token refresh on 401.
    func request<T: Decodable>(
        method: HTTPMethod,
        path: String,
        body: (some Encodable)? = nil as Empty?,
        authenticated: Bool = true
    ) async throws -> T {
        let response: T = try await performRequest(
            method: method,
            path: path,
            body: body,
            authenticated: authenticated
        )
        return response
    }

    /// Make an API request that returns no meaningful body (e.g., logout).
    func requestVoid(
        method: HTTPMethod,
        path: String,
        body: (some Encodable)? = nil as Empty?,
        authenticated: Bool = true
    ) async throws {
        let _: MessageResponse = try await performRequest(
            method: method,
            path: path,
            body: body,
            authenticated: authenticated
        )
    }

    /// Make an authenticated API request that returns raw Data (e.g., file downloads).
    /// Handles token injection and 401 refresh retry like other request methods.
    func requestData(
        method: HTTPMethod,
        path: String,
        authenticated: Bool = true
    ) async throws -> Data {
        return try await performRawRequest(
            method: method,
            path: path,
            authenticated: authenticated
        )
    }

    // MARK: - Private Implementation

    private func performRequest<T: Decodable>(
        method: HTTPMethod,
        path: String,
        body: (some Encodable)?,
        authenticated: Bool,
        isRetry: Bool = false
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if authenticated, let token = tokenStore.getAccessToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            urlRequest.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        // Handle 401: attempt token refresh and retry once
        if httpResponse.statusCode == 401 && authenticated && !isRetry {
            let refreshed = await attemptTokenRefresh()
            if refreshed {
                return try await performRequest(
                    method: method,
                    path: path,
                    body: body,
                    authenticated: authenticated,
                    isRetry: true
                )
            }
            throw APIError.sessionExpired
        }

        return try handleResponse(data: data, statusCode: httpResponse.statusCode)
    }

    private func handleResponse<T: Decodable>(data: Data, statusCode: Int) throws -> T {
        switch statusCode {
        case 200...299:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decodingError(error)
            }

        case 401:
            throw APIError.unauthorized

        case 409:
            let detail = parseErrorDetail(from: data)
            throw APIError.conflict(detail)

        case 422:
            let detail = parseErrorDetail(from: data)
            throw APIError.validationError(detail)

        case 429:
            throw APIError.rateLimited

        default:
            let detail = parseErrorDetail(from: data)
            throw APIError.serverError(statusCode, detail)
        }
    }

    private func parseErrorDetail(from data: Data) -> String {
        if let errorResponse = try? decoder.decode(APIErrorResponse.self, from: data) {
            return errorResponse.detail
        }
        return "Unknown error"
    }

    /// Perform a raw data request (no JSON decoding) with auth and 401 refresh retry.
    private func performRawRequest(
        method: HTTPMethod,
        path: String,
        authenticated: Bool,
        isRetry: Bool = false
    ) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue

        if authenticated, let token = tokenStore.getAccessToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 401 && authenticated && !isRetry {
            let refreshed = await attemptTokenRefresh()
            if refreshed {
                return try await performRawRequest(
                    method: method,
                    path: path,
                    authenticated: authenticated,
                    isRetry: true
                )
            }
            throw APIError.sessionExpired
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = parseErrorDetail(from: data)
            throw APIError.serverError(httpResponse.statusCode, detail)
        }

        return data
    }

    /// Attempt to refresh the access token using the stored refresh token.
    /// Returns true if refresh succeeded, false if session is fully expired.
    private func attemptTokenRefresh() async -> Bool {
        guard let refreshToken = tokenStore.getRefreshToken() else {
            return false
        }

        guard let url = URL(string: baseURL + "/api/auth/refresh") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RefreshRequest(refreshToken: refreshToken)
        guard let bodyData = try? encoder.encode(body) else {
            return false
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                // Refresh failed: clear tokens, session is expired
                tokenStore.deleteTokens()
                return false
            }

            let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
            try tokenStore.saveTokens(
                access: tokenResponse.accessToken,
                refresh: tokenResponse.refreshToken
            )
            return true
        } catch {
            tokenStore.deleteTokens()
            return false
        }
    }
}

// MARK: - URLSession Extension

extension URLSession {
    /// Ephemeral session: no cookies, no cache, no credential storage.
    static var ephemeral: URLSession {
        URLSession(configuration: .ephemeral)
    }
}

// MARK: - Empty Body Helper

/// Used as default generic parameter when no request body is needed.
struct Empty: Encodable {}
