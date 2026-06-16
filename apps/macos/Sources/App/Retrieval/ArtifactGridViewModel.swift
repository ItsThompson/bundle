import Foundation

/// Protocol for artifact API operations (enables testing with mocks).
protocol ArtifactAPIServiceProtocol {
    func retryArtifact(id: String) async throws -> ArtifactRetryResponse
}

/// Protocol for search operations (enables testing with mocks).
protocol SearchServiceProtocol {
    func search(query: String) async throws -> SearchResponse
}

/// Owns all state and logic for the artifact grid.
/// The view reads observable properties and calls methods: no logic in the view.
@Observable
@MainActor
final class ArtifactGridViewModel {
    // MARK: - Published State

    private(set) var artifacts: [ArtifactDisplayModel] = []
    private(set) var searchResults: [ArtifactDisplayModel] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var currentPage = 0
    private(set) var totalCount = 0
    private(set) var tagFilter: String?
    private(set) var allTags: [TagItem] = []
    private(set) var error: Error?

    /// Whether there are more pages to load.
    var hasMore: Bool { artifacts.count < totalCount }

    // MARK: - Dependencies

    private let apiService: ArtifactAPIServiceProtocol
    private let searchService: SearchServiceProtocol
    private let localDatabase: LocalDatabase
    private let pageSize: Int

    /// Shared date formatter (eliminates per-call allocation).
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        apiService: ArtifactAPIServiceProtocol,
        searchService: SearchServiceProtocol,
        localDatabase: LocalDatabase,
        pageSize: Int = 40
    ) {
        self.apiService = apiService
        self.searchService = searchService
        self.localDatabase = localDatabase
        self.pageSize = pageSize
    }

    // MARK: - Actions

    /// Load the first page of artifacts from local database.
    func loadPage() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let (items, total) = try fetchArtifactPage(limit: pageSize, offset: 0)
            artifacts = items
            totalCount = total
            currentPage = 1
        } catch {
            self.error = error
        }
    }

    /// Load the next page (append to existing artifacts).
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let offset = currentPage * pageSize
            let (items, _) = try fetchArtifactPage(limit: pageSize, offset: offset)
            artifacts.append(contentsOf: items)
            currentPage += 1
        } catch {
            self.error = error
        }
    }

    /// Perform a search query via the backend search service.
    func search(query: String) async {
        isSearching = true
        error = nil
        defer { isSearching = false }

        do {
            let response = try await searchService.search(query: query)
            searchResults = response.items.map { item in
                let type = ArtifactType(rawValue: item.type) ?? .screenshot
                let status = ArtifactStatus(rawValue: item.status) ?? .pending
                return ArtifactDisplayModel(
                    id: item.id,
                    type: type,
                    status: status,
                    contentPath: nil,
                    contentText: item.contentText,
                    createdAt: item.createdAt,
                    syncedAt: nil,
                    tags: item.tags
                )
            }
        } catch {
            self.error = error
        }
    }

    /// Clear search results and return to chronological view.
    func clearSearch() {
        searchResults = []
    }

    /// Filter artifacts by a specific tag (nil clears the filter).
    func filterByTag(_ tag: String?) async {
        tagFilter = tag
        await loadPage()
    }

    /// Load all tags with counts from local SQLite.
    func loadTags() {
        do {
            let tagCounts = try localDatabase.getTagsWithCounts()
            allTags = tagCounts.map { TagItem(name: $0.name, count: $0.count) }
        } catch {
            allTags = []
        }
    }

    /// Retry processing for a failed artifact.
    /// Optimistically updates local state to "pending" before the API call.
    func retryArtifact(id: String) async {
        // Optimistically update local state
        if let index = artifacts.firstIndex(where: { $0.id == id }) {
            artifacts[index].status = .pending
        }
        if let index = searchResults.firstIndex(where: { $0.id == id }) {
            searchResults[index].status = .pending
        }

        try? localDatabase.updateArtifactStatus(id: id, status: "pending")

        do {
            _ = try await apiService.retryArtifact(id: id)
        } catch {
            // Revert optimistic update on failure
            if let index = artifacts.firstIndex(where: { $0.id == id }) {
                artifacts[index].status = .failed
            }
            if let index = searchResults.firstIndex(where: { $0.id == id }) {
                searchResults[index].status = .failed
            }
            try? localDatabase.updateArtifactStatus(id: id, status: "failed")
            self.error = error
        }
    }

    // MARK: - Private Helpers

    /// Fetch a page of artifacts, respecting the active tag filter.
    /// Returns the mapped display models and the total count for that filter.
    private func fetchArtifactPage(limit: Int, offset: Int) throws -> ([ArtifactDisplayModel], Int) {
        let localArtifacts: [LocalArtifact]
        let total: Int

        if let tagName = tagFilter {
            localArtifacts = try localDatabase.getArtifactsForTag(
                tagName: tagName, limit: limit, offset: offset
            )
            total = try localDatabase.getArtifactCountForTag(tagName: tagName)
        } else {
            localArtifacts = try localDatabase.getArtifacts(limit: limit, offset: offset)
            total = try localDatabase.getArtifactCount()
        }

        let ids = localArtifacts.map { $0.id }
        let tagsByArtifact = try localDatabase.getTagsForArtifacts(ids: ids)

        let mapped = localArtifacts.map { local in
            mapToDisplayModel(local: local, tags: tagsByArtifact[local.id] ?? [])
        }
        return (mapped, total)
    }

    /// Map a raw SQLite row to a typed display model.
    private func mapToDisplayModel(local: LocalArtifact, tags: [String]) -> ArtifactDisplayModel {
        let type = ArtifactType(rawValue: local.type) ?? .screenshot
        let status = ArtifactStatus(rawValue: local.status) ?? .pending
        let date = Self.isoFormatter.date(from: local.createdAt) ?? Date()
        let syncedDate: Date? = local.syncedAt.flatMap { Self.isoFormatter.date(from: $0) }

        return ArtifactDisplayModel(
            id: local.id,
            type: type,
            status: status,
            contentPath: local.contentPath,
            contentText: local.contentText,
            createdAt: date,
            syncedAt: syncedDate,
            tags: tags
        )
    }
}

// MARK: - Protocol Conformances

extension ArtifactAPIService: ArtifactAPIServiceProtocol {}
extension SearchService: SearchServiceProtocol {}
