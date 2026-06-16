import Foundation

/// View-layer model for artifacts displayed in the grid.
/// Decouples the view from the raw SQLite row representation (LocalArtifact).
struct ArtifactDisplayModel: Identifiable, Equatable {
    let id: String
    let type: ArtifactType
    var status: ArtifactStatus  // Mutable for optimistic retry updates
    let contentPath: String?
    let contentText: String?
    let createdAt: Date
    let syncedAt: Date?
    let tags: [String]

    /// The domain extracted from a link artifact's contentText (URL).
    var domain: String? {
        guard type == .link, let urlString = contentText,
              let url = URL(string: urlString),
              let host = url.host else {
            return nil
        }
        return host
    }

    /// Relative timestamp string (e.g. "2 min ago", "3 hours ago", "yesterday").
    var relativeTimestamp: String {
        RelativeTimestampFormatter.format(createdAt)
    }

    /// Convert to the existing Artifact domain model (for views that still use it).
    func toArtifact() -> Artifact {
        Artifact(
            id: id,
            type: type,
            contentPath: contentPath,
            contentText: contentText,
            status: status,
            createdAt: createdAt,
            syncedAt: syncedAt,
            tags: tags
        )
    }
}
