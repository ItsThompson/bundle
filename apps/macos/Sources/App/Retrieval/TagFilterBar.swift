import SwiftUI

/// A tag with its display name and artifact count.
struct TagItem: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

/// Horizontal scrollable tag filter bar with pill-shaped buttons.
/// Displays "All" as the first tag, followed by tags ordered by count (most-used first).
/// Shows left/right arrow buttons at edges when content overflows.
struct TagFilterBar: View {
    let tags: [TagItem]
    let totalCount: Int
    let selectedTag: String?
    let onSelectTag: (String?) -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var canScrollLeft: Bool {
        scrollOffset > 0
    }

    private var canScrollRight: Bool {
        contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left arrow
            if canScrollLeft {
                scrollArrowButton(direction: .left)
            }

            // Scrollable tag pills
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // "All" tag is always first
                        FilterTagPill(
                            name: "All",
                            count: totalCount,
                            isSelected: selectedTag == nil
                        )
                        .id("tag-all")
                        .onTapGesture { onSelectTag(nil) }

                        ForEach(tags) { tag in
                            FilterTagPill(
                                name: tag.name,
                                count: tag.count,
                                isSelected: selectedTag == tag.name
                            )
                            .id("tag-\(tag.name)")
                            .onTapGesture { onSelectTag(tag.name) }
                        }
                    }
                    .padding(.horizontal, 4)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ContentWidthPreferenceKey.self,
                                value: geo.size.width
                            )
                        }
                    )
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ContainerWidthPreferenceKey.self,
                            value: geo.size.width
                        )
                    }
                )
                .onPreferenceChange(ContentWidthPreferenceKey.self) { value in
                    contentWidth = value
                }
                .onPreferenceChange(ContainerWidthPreferenceKey.self) { value in
                    containerWidth = value
                }
                .onChange(of: selectedTag) { _, newTag in
                    // Auto-scroll selected tag into view
                    let tagId = newTag.map { "tag-\($0)" } ?? "tag-all"
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(tagId, anchor: .center)
                    }
                }
            }

            // Right arrow
            if canScrollRight {
                scrollArrowButton(direction: .right)
            }
        }
    }

    // MARK: - Arrow Buttons

    private enum ScrollDirection {
        case left, right
    }

    private func scrollArrowButton(direction: ScrollDirection) -> some View {
        Button(action: {}) {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 28)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag Pill

/// A single pill-shaped tag button showing name and count, with selection state.
struct FilterTagPill: View {
    let name: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        )
        .foregroundColor(isSelected ? .white : .primary)
        .overlay(
            Capsule()
                .stroke(
                    isSelected ? Color.clear : Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Preference Keys

private struct ContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ContainerWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
