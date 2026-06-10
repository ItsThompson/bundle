import SwiftUI

/// Detail view for a single artifact. Displays the full content (image/note)
/// along with metadata (tags, timestamp, processing status).
/// Provides a back button and Escape key to return to the grid.
struct ArtifactDetailView: View {
    let artifact: Artifact
    let onBack: () -> Void

    @State private var imageURL: URL?
    @State private var isLoadingImage = false
    @State private var loadError: String?

    private let contentService = ArtifactContentService()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            metadataBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadContent() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            // Type indicator
            HStack(spacing: 4) {
                Text(artifact.type.icon)
                Text(artifact.type.rawValue.capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch artifact.type {
        case .screenshot:
            screenshotContent
        case .note:
            noteContent
        case .link:
            // Links open in browser (handled before showing detail view)
            EmptyView()
        }
    }

    private var screenshotContent: some View {
        Group {
            if let url = imageURL {
                ImageDetailView(imageURL: url)
            } else if isLoadingImage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading full resolution…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
    }

    private var noteContent: some View {
        NoteDetailView(content: artifact.contentText ?? "")
    }

    // MARK: - Metadata Bar

    private var metadataBar: some View {
        HStack(spacing: 16) {
            // Tags as pills
            if !artifact.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(artifact.tags, id: \.self) { tag in
                            TagPill(name: tag)
                        }
                    }
                }
            }

            Spacer()

            // Processing status
            DetailStatusIndicator(status: artifact.status)

            // Creation timestamp
            Text(artifact.relativeTimestamp)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Content Loading

    private func loadContent() {
        guard artifact.type == .screenshot else { return }

        isLoadingImage = true
        loadError = nil

        Task {
            do {
                let url = try await contentService.loadFullResolutionImage(for: artifact)
                imageURL = url
            } catch {
                loadError = error.localizedDescription
            }
            isLoadingImage = false
        }
    }
}

// MARK: - Tag Pill

/// A small rounded pill displaying a tag name.
struct TagPill: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .clipShape(Capsule())
    }
}

// MARK: - Detail Status Indicator

/// Displays the processing status with a colored dot and label in the detail metadata bar.
struct DetailStatusIndicator: View {
    let status: ArtifactStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case .completed:
            return .green
        case .processing:
            return .orange
        case .failed:
            return .red
        case .pending:
            return .gray
        }
    }
}
