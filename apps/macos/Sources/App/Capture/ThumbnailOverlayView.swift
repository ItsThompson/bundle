import SwiftUI

/// SwiftUI view for the post-capture thumbnail overlay.
/// Shows content preview with hover-revealed action buttons.
struct ThumbnailOverlayView: View {
    let content: ThumbnailContent
    let onCopy: () -> Void
    let onAddNote: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Action buttons overlay (visible on hover)
            if isHovered {
                actionButtons
                    .transition(.opacity)
            }
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .screenshot(let thumbnailPath):
            screenshotView(path: thumbnailPath)
        case .note(let text):
            noteView(text: text)
        case .link(let url):
            linkView(url: url)
        }
    }

    private func screenshotView(path: URL) -> some View {
        Group {
            if let nsImage = NSImage(contentsOf: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 200, maxHeight: 150)
            } else {
                // Fallback if thumbnail file can't be loaded
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .frame(height: 100)
            }
        }
        .padding(8)
    }

    private func noteView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "note.text")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(truncatedNoteText(text))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func linkView(url: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "link")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text(extractDomain(from: url))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            thumbnailButton(icon: "doc.on.doc", label: "Copy", action: onCopy)
            thumbnailButton(icon: "note.text.badge.plus", label: "Add Note", action: onAddNote)
            thumbnailButton(icon: "xmark", label: "Close", action: onDismiss)
        }
        .padding(6)
    }

    private func thumbnailButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Helpers

    /// Truncate note text to first 2-3 lines for preview.
    private func truncatedNoteText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let previewLines = Array(lines.prefix(3))
        return previewLines.joined(separator: "\n")
    }
}
