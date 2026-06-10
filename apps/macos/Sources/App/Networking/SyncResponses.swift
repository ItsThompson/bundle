import Foundation

/// Response model for a single artifact from the backend sync endpoint.
struct SyncArtifactResponse: Decodable {
    let id: UUID
    let type: String
    let contentText: String?
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, type, status, tags
        case contentText = "content_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Response model for the paginated artifact list.
struct SyncListResponse: Decodable {
    let items: [SyncArtifactResponse]
    let total: Int
    let limit: Int
    let offset: Int
}
