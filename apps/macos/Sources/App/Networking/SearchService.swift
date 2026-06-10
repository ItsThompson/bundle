import Foundation

/// Response from the hybrid search endpoint.
struct SearchResponse: Decodable {
    let items: [SearchResultItem]
    let query: String
    let total: Int
}

/// A single search result from hybrid search.
struct SearchResultItem: Decodable, Identifiable {
    let id: String
    let type: String
    let contentText: String?
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let tags: [String]
    let textRank: Double
    let vectorSimilarity: Double

    enum CodingKeys: String, CodingKey {
        case id, type, status, tags
        case contentText = "content_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case textRank = "text_rank"
        case vectorSimilarity = "vector_similarity"
    }
}

/// Handles search requests to the backend hybrid search endpoint.
final class SearchService {
    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Perform hybrid search with the given query text.
    /// Returns search results ranked by combined BM25 + vector similarity.
    func search(query: String) async throws -> SearchResponse {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let response: SearchResponse = try await apiClient.request(
            method: .get,
            path: "/api/v1/artifacts/search?q=\(encodedQuery)"
        )
        return response
    }
}
