import Foundation

/// Manages loading full-resolution artifact content from local cache,
/// falling back to backend fetch when not available locally.
@MainActor
final class ArtifactContentService {
    private let apiClient: APIClient
    private let artifactsDirectory: URL

    init(apiClient: APIClient = APIClient(), artifactsDirectory: URL? = nil) {
        self.apiClient = apiClient
        self.artifactsDirectory = artifactsDirectory ?? Self.defaultArtifactsDirectory
    }

    static var defaultArtifactsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Bundle/artifacts")
    }

    /// Load the full-resolution image for a screenshot artifact.
    /// Returns the local file URL: checks cache first, fetches from backend if missing.
    func loadFullResolutionImage(for artifact: Artifact) async throws -> URL {
        // Try local cache first
        if let localURL = localFileURL(for: artifact) {
            return localURL
        }

        // Fetch from backend and cache locally
        return try await fetchAndCache(artifact: artifact)
    }

    /// Check if the full-resolution file exists locally.
    func localFileURL(for artifact: Artifact) -> URL? {
        guard let contentPath = artifact.contentPath else { return nil }

        let fullPath = artifactsDirectory.appendingPathComponent(contentPath)
        if FileManager.default.fileExists(atPath: fullPath.path) {
            return fullPath
        }

        return nil
    }

    // MARK: - Private

    /// Fetch artifact content from backend and save to local cache.
    private func fetchAndCache(artifact: Artifact) async throws -> URL {
        let path = "/api/v1/artifacts/\(artifact.id)/content"
        let data: Data = try await fetchRawData(path: path)

        // Determine local save path
        let fileName = artifact.contentPath ?? "\(artifact.id).png"
        let localURL = artifactsDirectory.appendingPathComponent(fileName)

        // Ensure parent directory exists
        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Write to disk
        try data.write(to: localURL)

        return localURL
    }

    /// Fetch raw data from the backend (bypasses JSON decoding).
    private func fetchRawData(path: String) async throws -> Data {
        guard let url = URL(string: APIClient.defaultBaseURL + path) else {
            throw ArtifactContentError.invalidURL
        }

        let tokenStore: TokenStore = KeychainManager()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let token = tokenStore.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.ephemeral.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArtifactContentError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            throw ArtifactContentError.fetchFailed(httpResponse.statusCode)
        }

        return data
    }
}

// MARK: - Errors

enum ArtifactContentError: Error, LocalizedError {
    case invalidURL
    case networkError
    case fetchFailed(Int)
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid content URL"
        case .networkError:
            return "Network error while fetching content"
        case .fetchFailed(let code):
            return "Failed to fetch content (HTTP \(code))"
        case .fileNotFound:
            return "Artifact file not found"
        }
    }
}
