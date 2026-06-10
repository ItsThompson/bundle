import Foundation

/// Response from artifact retry endpoint.
struct ArtifactRetryResponse: Decodable {
    let id: UUID
    let type: String
    let status: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Handles artifact-related API calls (retry, etc.).
final class ArtifactAPIService {
    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Retry processing for a failed artifact.
    /// Returns the updated artifact response on success.
    func retryArtifact(id: String) async throws -> ArtifactRetryResponse {
        let response: ArtifactRetryResponse = try await apiClient.request(
            method: .post,
            path: "/api/v1/artifacts/\(id)/retry"
        )
        return response
    }
}
