import SwiftUI

/// A single tile in the artifact grid. Renders differently based on type:
/// - Screenshot: thumbnail image (aspect-fill, rounded corners)
/// - Note: first 2-3 lines of text (monospace, truncated)
/// - Link: favicon + domain name
///
/// On hover: dims with an overlay bar showing type icon, relative timestamp, and tags.
struct ArtifactTile: View {
    let artifact: Artifact

    @State private var isHovered = false

    private let tileHeight: CGFloat = 160

    var body: some View {
        ZStack(alignment: .bottom) {
            tileContent
                .frame(maxWidth: .infinity)
                .frame(height: tileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if isHovered {
                hoverOverlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Type-Specific Content

    @ViewBuilder
    private var tileContent: some View {
        switch artifact.type {
        case .screenshot:
            screenshotTile
        case .note:
            noteTile
        case .link:
            linkTile
        }
    }

    private var screenshotTile: some View {
        Group {
            if let imagePath = thumbnailPath, let nsImage = NSImage(contentsOfFile: imagePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: tileHeight)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundColor(.secondary)
                    }
            }
        }
    }

    private var noteTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notePreview)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var linkTile: some View {
        VStack(spacing: 8) {
            AsyncImage(url: faviconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                case .failure:
                    Image(systemName: "globe")
                        .font(.title)
                        .foregroundColor(.secondary)
                default:
                    ProgressView()
                        .frame(width: 48, height: 48)
                }
            }

            Text(artifact.domain ?? "link")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Hover Overlay

    private var hoverOverlay: some View {
        ZStack(alignment: .bottom) {
            // Dim the entire tile
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .frame(height: tileHeight)

            // Bottom bar with info
            HStack(spacing: 6) {
                Text(artifact.type.icon)
                    .font(.caption)

                Text(artifact.relativeTimestamp)
                    .font(.caption2)
                    .foregroundColor(.white)

                if !artifact.tags.isEmpty {
                    Text("·")
                        .foregroundColor(.white.opacity(0.7))
                    Text(artifact.tags.prefix(3).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))
        }
    }

    // MARK: - Helpers

    /// Path to the thumbnail for screenshot artifacts.
    private var thumbnailPath: String? {
        guard let contentPath = artifact.contentPath else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let artifactsDir = appSupport.appendingPathComponent("Bundle/artifacts")

        // Try thumbnail first (name_thumb.png), fall back to original
        let baseName = (contentPath as NSString).deletingPathExtension
        let ext = (contentPath as NSString).pathExtension
        let thumbName = "\(baseName)_thumb.\(ext)"
        let thumbPath = artifactsDir.appendingPathComponent(thumbName).path

        if FileManager.default.fileExists(atPath: thumbPath) {
            return thumbPath
        }

        // Fall back to original image
        let fullPath = artifactsDir.appendingPathComponent(contentPath).path
        if FileManager.default.fileExists(atPath: fullPath) {
            return fullPath
        }

        return nil
    }

    /// Google Favicon API URL for link artifacts.
    private var faviconURL: URL? {
        guard let domain = artifact.domain else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")
    }

    /// Preview of note content (first 2-3 lines).
    private var notePreview: String {
        guard let text = artifact.contentText else { return "" }
        let lines = text.components(separatedBy: .newlines)
        return lines.prefix(3).joined(separator: "\n")
    }
}
