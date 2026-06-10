import SwiftUI

/// Container view that manages artifact loading and displays the grid.
/// Handles infinite scroll pagination, search, and empty state.
struct ArtifactGridContainer: View {
    let localDatabase: LocalDatabase
    @ObservedObject var syncService: SyncService
    var onArtifactTap: ((Artifact) -> Void)? = nil

    @State private var artifacts: [Artifact] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var totalCount = 0

    // Search state
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [Artifact] = []
    @State private var searchDebounceTask: Task<Void, Never>?

    private let initialLoadCount = 40
    private let pageSize = 20
    private let debounceInterval: Duration = .milliseconds(300)
    private let searchService = SearchService()
    private let artifactAPIService = ArtifactAPIService()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar at top
            SearchBar(
                searchText: $searchText,
                onClear: clearSearch
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .onChange(of: searchText) { _, newValue in
                handleSearchTextChange(newValue)
            }

            // Content area
            if syncService.initialSyncProgress != nil {
                initialSyncProgressView
            } else if isSearching {
                searchLoadingView
            } else if !searchText.isEmpty && searchResults.isEmpty && !isLoading {
                noMatchesView
            } else if !searchText.isEmpty {
                searchResultsGrid
            } else if artifacts.isEmpty && !isLoading {
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
        .onChange(of: syncService.isSyncing) { wasSyncing, isSyncing in
            // Reload chronological data after sync completes
            if wasSyncing && !isSyncing && searchText.isEmpty {
                loadInitialArtifacts()
            }
        }
    }

    // MARK: - Initial Sync Progress

    private var initialSyncProgressView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(syncService.isSyncing ? 360 : 0))
                .animation(
                    .linear(duration: 2).repeatForever(autoreverses: false),
                    value: syncService.isSyncing
                )

            Text("Syncing artifacts...")
                .font(.title2)
                .fontWeight(.medium)

            if let progress = syncService.initialSyncProgress {
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

    // MARK: - No Matches View

    private var noMatchesView: some View {
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

    // MARK: - Search Loading (Skeleton Tiles)

    private var searchLoadingView: some View {
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

    // MARK: - Search Results Grid

    private var searchResultsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150))],
                spacing: 12
            ) {
                ForEach(searchResults) { artifact in
                    ArtifactTile(
                        artifact: artifact,
                        onTap: { onArtifactTap?(artifact) },
                        onRetry: { id in retryArtifact(id: id) }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Scroll View with Grid (Chronological)

    private var artifactScrollView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150))],
                spacing: 12
            ) {
                ForEach(artifacts) { artifact in
                    ArtifactTile(
                        artifact: artifact,
                        onTap: { onArtifactTap?(artifact) },
                        onRetry: { id in retryArtifact(id: id) }
                    )
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

    // MARK: - Retry

    /// Trigger retry for a failed artifact via the backend.
    /// Updates the local tile status immediately for instant feedback.
    private func retryArtifact(id: String) {
        // Optimistically update local status to pending
        if let index = artifacts.firstIndex(where: { $0.id == id }) {
            artifacts[index] = artifacts[index].withStatus(.pending)
        }
        if let index = searchResults.firstIndex(where: { $0.id == id }) {
            searchResults[index] = searchResults[index].withStatus(.pending)
        }

        try? localDatabase.updateArtifactStatus(id: id, status: "pending")

        Task {
            do {
                _ = try await artifactAPIService.retryArtifact(id: id)
                print("[Bundle] Retry requested for artifact \(id)")
            } catch {
                print("[Bundle] Retry failed for artifact \(id): \(error)")
                // Revert optimistic update on failure
                if let index = artifacts.firstIndex(where: { $0.id == id }) {
                    artifacts[index] = artifacts[index].withStatus(.failed)
                }
                if let index = searchResults.firstIndex(where: { $0.id == id }) {
                    searchResults[index] = searchResults[index].withStatus(.failed)
                }
                try? localDatabase.updateArtifactStatus(id: id, status: "failed")
            }
        }
    }

    // MARK: - Search Logic

    private func handleSearchTextChange(_ newValue: String) {
        // Cancel previous debounce task
        searchDebounceTask?.cancel()

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            clearSearch()
            return
        }

        // Debounce: wait 300ms before firing search
        searchDebounceTask = Task {
            try? await Task.sleep(for: debounceInterval)

            // Check if task was cancelled during sleep
            guard !Task.isCancelled else { return }

            await performSearch(query: trimmed)
        }
    }

    private func clearSearch() {
        searchDebounceTask?.cancel()
        searchResults = []
        isSearching = false
    }

    @MainActor
    private func performSearch(query: String) async {
        isSearching = true

        do {
            let response = try await searchService.search(query: query)

            // Only update if search text hasn't changed during the request
            let currentTrimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentTrimmed == query else { return }

            searchResults = response.items.map { item in
                let type = ArtifactType(rawValue: item.type) ?? .screenshot
                let status = ArtifactStatus(rawValue: item.status) ?? .pending
                return Artifact(
                    id: item.id,
                    type: type,
                    contentPath: nil,
                    contentText: item.contentText,
                    status: status,
                    createdAt: item.createdAt,
                    syncedAt: nil,
                    tags: item.tags
                )
            }
        } catch {
            // Only clear results if the query is still current
            let currentTrimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentTrimmed == query else { return }
            print("[Bundle] Search failed: \(error.localizedDescription)")
            searchResults = []
        }

        isSearching = false
    }

    // MARK: - Data Loading (Chronological)

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
        let status = ArtifactStatus(rawValue: local.status) ?? .pending
        let date = Self.isoFormatter.date(from: local.createdAt) ?? Date()
        let syncedDate: Date? = local.syncedAt.flatMap { Self.isoFormatter.date(from: $0) }

        return Artifact(
            id: local.id,
            type: type,
            contentPath: local.contentPath,
            contentText: local.contentText,
            status: status,
            createdAt: date,
            syncedAt: syncedDate,
            tags: tags
        )
    }
}

// MARK: - Skeleton Tile

/// Placeholder tile shown during search loading.
struct SkeletonTile: View {
    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlBackgroundColor),
                        Color(nsColor: .controlBackgroundColor).opacity(0.5),
                        Color(nsColor: .controlBackgroundColor),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 150)
            .opacity(isAnimating ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear { isAnimating = true }
    }
}
