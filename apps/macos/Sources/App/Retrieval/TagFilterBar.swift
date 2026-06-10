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

    /// Index used to drive arrow-button scrolling via ScrollViewReader.
    @State private var scrollTarget: String?
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private var hasOverflow: Bool {
        contentWidth > containerWidth
    }

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        hasOverflow && scrollOffset < (contentWidth - containerWidth - 1)
    }

    /// All tag IDs in display order for arrow navigation.
    private var tagIds: [String] {
        var ids = ["tag-all"]
        ids.append(contentsOf: tags.map { "tag-\($0.name)" })
        return ids
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left arrow
            if canScrollLeft {
                arrowButton(direction: .left)
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
                            Color.clear
                                .preference(
                                    key: ContentWidthKey.self,
                                    value: geo.size.width
                                )
                                .preference(
                                    key: ScrollOffsetKey.self,
                                    value: -geo.frame(in: .named("tagScroll")).origin.x
                                )
                        }
                    )
                }
                .coordinateSpace(name: "tagScroll")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ContainerWidthKey.self,
                            value: geo.size.width
                        )
                    }
                )
                .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }
                .onPreferenceChange(ContainerWidthKey.self) { containerWidth = $0 }
                .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
                .onChange(of: selectedTag) { _, newTag in
                    let tagId = newTag.map { "tag-\($0)" } ?? "tag-all"
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(tagId, anchor: .center)
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    // Reset so the same target can be triggered again
                    scrollTarget = nil
                }
            }

            // Right arrow
            if canScrollRight {
                arrowButton(direction: .right)
            }
        }
    }

    // MARK: - Arrow Buttons

    private enum ScrollDirection {
        case left, right
    }

    private func arrowButton(direction: ScrollDirection) -> some View {
        Button {
            scrollByDirection(direction)
        } label: {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 28)
        }
        .buttonStyle(.plain)
    }

    /// Scroll approximately 3 tags in the given direction.
    private func scrollByDirection(_ direction: ScrollDirection) {
        let ids = tagIds
        guard !ids.isEmpty else { return }

        // Estimate visible tag count and skip ~3 tags per arrow press
        let step = 3
        let currentIndex = approximateVisibleIndex(ids: ids)

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = max(0, currentIndex - step)
        case .right:
            targetIndex = min(ids.count - 1, currentIndex + step)
        }

        scrollTarget = ids[targetIndex]
    }

    /// Estimate which tag index is currently near the center of the visible area.
    private func approximateVisibleIndex(ids: [String]) -> Int {
        guard contentWidth > 0, !ids.isEmpty else { return 0 }
        let avgTagWidth = contentWidth / CGFloat(ids.count)
        let centerOffset = scrollOffset + containerWidth / 2
        let index = Int(centerOffset / avgTagWidth)
        return min(max(0, index), ids.count - 1)
    }
}

// MARK: - FilterTagPill

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

private struct ContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
