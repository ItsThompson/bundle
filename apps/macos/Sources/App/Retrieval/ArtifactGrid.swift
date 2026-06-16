import SwiftUI

/// Container view for the artifact grid. All state/logic lives in `ArtifactGridViewModel`.
struct ArtifactGridContainer: View {
    @State private var viewModel: ArtifactGridViewModel
    @ObservedObject var syncService: SyncService
    var onArtifactTap: ((Artifact) -> Void)?
    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    init(localDatabase: LocalDatabase, syncService: SyncService, onArtifactTap: ((Artifact) -> Void)? = nil) {
        _viewModel = State(initialValue: ArtifactGridViewModel(
            apiService: ArtifactAPIService(),
            searchService: SearchService(),
            localDatabase: localDatabase
        ))
        self.syncService = syncService
        self.onArtifactTap = onArtifactTap
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(searchText: $searchText, onClear: handleClearSearch)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }

            if searchText.isEmpty && !viewModel.allTags.isEmpty {
                TagFilterBar(
                    tags: viewModel.allTags, totalCount: viewModel.totalCount,
                    selectedTag: viewModel.tagFilter,
                    onSelectTag: { tag in Task { await viewModel.filterByTag(tag) } }
                ).padding(.horizontal, 16).padding(.bottom, 8)
            }

            gridContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await viewModel.loadPage(); viewModel.loadTags() }
        .onChange(of: syncService.isSyncing) { wasSyncing, isSyncing in
            if wasSyncing && !isSyncing && searchText.isEmpty {
                Task { await viewModel.loadPage() }; viewModel.loadTags()
            }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if syncService.initialSyncProgress != nil {
            ArtifactGridSyncProgress(isSyncing: syncService.isSyncing, progress: syncService.initialSyncProgress)
        } else if viewModel.isSearching {
            ArtifactGridSearchLoading()
        } else if !searchText.isEmpty && viewModel.searchResults.isEmpty && !viewModel.isLoading {
            ArtifactGridNoMatches()
        } else if !searchText.isEmpty {
            artifactGrid(items: viewModel.searchResults, paginated: false)
        } else if viewModel.artifacts.isEmpty && !viewModel.isLoading {
            ArtifactGridEmptyState()
        } else {
            artifactGrid(items: viewModel.artifacts, paginated: true)
        }
    }

    private func artifactGrid(items: [ArtifactDisplayModel], paginated: Bool) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                ForEach(items) { displayModel in
                    let artifact = displayModel.toArtifact()
                    ArtifactTile(
                        artifact: artifact,
                        onTap: { onArtifactTap?(artifact) },
                        onRetry: { id in Task { await viewModel.retryArtifact(id: id) } }
                    )
                    .onAppear {
                        if paginated { checkLoadMore(displayModel: displayModel) }
                    }
                }
            }.padding(16)
            if paginated && viewModel.isLoading { ProgressView().padding() }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        searchDebounceTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { handleClearSearch(); return }
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await viewModel.search(query: trimmed)
        }
    }

    private func handleClearSearch() {
        searchDebounceTask?.cancel()
        viewModel.clearSearch()
    }

    private func checkLoadMore(displayModel: ArtifactDisplayModel) {
        guard viewModel.hasMore else { return }
        let threshold = Int(Double(viewModel.artifacts.count) * 0.8)
        guard let index = viewModel.artifacts.firstIndex(where: { $0.id == displayModel.id }),
              index >= threshold else { return }
        Task { await viewModel.loadMore() }
    }
}
