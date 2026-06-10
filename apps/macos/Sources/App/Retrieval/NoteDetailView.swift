import SwiftUI

/// Read-only markdown-rendered view for note artifacts.
/// Uses AttributedString(markdown:) for built-in Swift markdown rendering.
struct NoteDetailView: View {
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(renderedMarkdown)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var renderedMarkdown: AttributedString {
        do {
            return try AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            // Fall back to plain text if markdown parsing fails
            return AttributedString(content)
        }
    }
}
