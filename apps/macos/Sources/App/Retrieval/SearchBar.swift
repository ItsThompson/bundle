import SwiftUI

/// Search bar with debounced input for hybrid search.
struct SearchBar: View {
    @Binding var searchText: String
    let onClear: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            TextField("Search artifacts...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onExitCommand {
                    // Escape key: clear search and dismiss focus
                    searchText = ""
                    isFocused = false
                    onClear()
                }

            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
