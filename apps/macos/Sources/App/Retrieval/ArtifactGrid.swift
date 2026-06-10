import SwiftUI

/// Container view that manages artifact loading and displays the grid.
/// Handles infinite scroll pagination and empty state.
struct ArtifactGridContainer: View {
    let localDatabase: LocalDatabase

    @State private var artifacts: [Artifact] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var totalCount = 0

    private let initialLoadCount = 40
    private let pageSize = 20

    var body: some View {
        VStack(spacing: 0) {
            if artifacts.isEmpty && !isLoading {
                emptyState
            } else {
                artifactScrollView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { loadInitialArtifacts() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
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

    // MARK: - Scroll View with Grid

    private var artifactScrollView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150))],
                spacing: 12
            ) {
                ForEach(artifacts) { artifact in
                    ArtifactTile(artifact: artifact)
                        .onAppear {
                            checkLoadMore(artifact: artifact)
                        }
                }
            }
            .padding(16)

            if isLoading {
                ProgressView()
                    .padding()
            }
        }
    }

    // MARK: - Data Loading

    private func loadInitialArtifacts() {
        guard !isLoading else { return }
        isLoading = true
        artifacts = []

        do {
            totalCount = try localDatabase.getArtifactCount()
            let localArtifacts = try localDatabase.getArtifacts(limit: initialLoadCount, offset: 0)
            let ids = localArtifacts.map { $0.id }
            let tagsByArtifact = try localDatabase.getTagsForArtifacts(ids: ids)

            artifacts = localArtifacts.map { local in
                mapToArtifact(local: local, tags: tagsByArtifact[local.id] ?? [])
            }
            hasMore = artifacts.count < totalCount
        } catch {
            print("[Bundle] Failed to load artifacts: \(error)")
        }

        isLoading = false
    }

    private func loadMoreArtifacts() {
        guard !isLoading, hasMore else { return }
        isLoading = true

        do {
            let localArtifacts = try localDatabase.getArtifacts(limit: pageSize, offset: artifacts.count)
            let ids = localArtifacts.map { $0.id }
            let tagsByArtifact = try localDatabase.getTagsForArtifacts(ids: ids)

            let newArtifacts = localArtifacts.map { local in
                mapToArtifact(local: local, tags: tagsByArtifact[local.id] ?? [])
            }
            artifacts.append(contentsOf: newArtifacts)
            hasMore = artifacts.count < totalCount
        } catch {
            print("[Bundle] Failed to load more artifacts: \(error)")
        }

        isLoading = false
    }

    /// Trigger load-more when scrolling past 80% of current items.
    private func checkLoadMore(artifact: Artifact) {
        guard hasMore else { return }
        let threshold = Int(Double(artifacts.count) * 0.8)
        guard let index = artifacts.firstIndex(where: { $0.id == artifact.id }) else { return }
        if index >= threshold {
            loadMoreArtifacts()
        }
    }

    // MARK: - Mapping

    private static let isoFormatter = ISO8601DateFormatter()

    private func mapToArtifact(local: LocalArtifact, tags: [String]) -> Artifact {
        let type = ArtifactType(rawValue: local.type) ?? .screenshot
        let date = Self.isoFormatter.date(from: local.createdAt) ?? Date()
        let syncedDate: Date? = local.syncedAt.flatMap { Self.isoFormatter.date(from: $0) }

        return Artifact(
            id: local.id,
            type: type,
            contentPath: local.contentPath,
            contentText: local.contentText,
            status: local.status,
            createdAt: date,
            syncedAt: syncedDate,
            tags: tags
        )
    }
}
