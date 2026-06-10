import Foundation

/// Processing status of an artifact.
enum ArtifactStatus: String, CaseIterable, Equatable {
    case pending
    case processing
    case completed
    case failed

    /// Whether this status indicates the artifact is still being processed.
    var isProcessing: Bool {
        self == .pending || self == .processing
    }

    /// Whether this status indicates a terminal failure.
    var isFailed: Bool {
        self == .failed
    }

    /// Whether a status badge should be shown.
    var showsBadge: Bool {
        isProcessing || isFailed
    }
}

/// Domain model representing a captured artifact.
struct Artifact: Identifiable, Equatable {
    let id: String
    let type: ArtifactType
    let contentPath: String?
    let contentText: String?
    let status: ArtifactStatus
    let createdAt: Date
    let syncedAt: Date?
    var tags: [String]

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

    /// Create a copy with a different status. Avoids manually copying all fields.
    func withStatus(_ newStatus: ArtifactStatus) -> Artifact {
        Artifact(
            id: id,
            type: type,
            contentPath: contentPath,
            contentText: contentText,
            status: newStatus,
            createdAt: createdAt,
            syncedAt: syncedAt,
            tags: tags
        )
    }
}

/// The three artifact capture types.
enum ArtifactType: String, CaseIterable {
    case screenshot
    case note
    case link

    var icon: String {
        switch self {
        case .screenshot: return "📷"
        case .note: return "📝"
        case .link: return "🔗"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot: return "camera.fill"
        case .note: return "note.text"
        case .link: return "link"
        }
    }
}

/// Formats dates as human-readable relative timestamps.
enum RelativeTimestampFormatter {
    static func format(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) min ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else if interval < 172800 {
            return "yesterday"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days) days ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}
