import SwiftUI

/// Empty state shown when no artifacts have been captured yet.
struct ArtifactGridEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No artifacts yet")
                .font(.title2)
                .fontWeight(.medium)

            Text("Capture screenshots, notes, or links\nusing the global hotkey (⌘⇧B)")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// No matches state shown when a search returns zero results.
struct ArtifactGridNoMatches: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No matches found")
                .font(.title2)
                .fontWeight(.medium)

            Text("Try a different search term")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Progress view shown during initial sync.
struct ArtifactGridSyncProgress: View {
    let isSyncing: Bool
    let progress: Double?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isSyncing ? 360 : 0))
                .animation(
                    .linear(duration: 2).repeatForever(autoreverses: false),
                    value: isSyncing
                )

            Text("Syncing artifacts...")
                .font(.title2)
                .fontWeight(.medium)

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Search loading skeleton view.
struct ArtifactGridSearchLoading: View {
    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150))],
                spacing: 12
            ) {
                ForEach(0..<8, id: \.self) { _ in
                    SkeletonTile()
                }
            }
            .padding(16)
        }
    }
}
