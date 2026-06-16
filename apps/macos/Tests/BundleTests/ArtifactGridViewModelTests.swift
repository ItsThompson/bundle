@testable import Bundle
import Foundation
import XCTest

// MARK: - Mock Services

/// Mock implementation of ArtifactAPIServiceProtocol for testing.
final class MockArtifactAPIService: ArtifactAPIServiceProtocol {
    var retryCallCount = 0
    var retryCalledWithId: String?
    var retryResult: Result<ArtifactRetryResponse, Error> = .success(
        ArtifactRetryResponse(
            id: UUID(),
            type: "screenshot",
            status: "pending",
            createdAt: Date(),
            updatedAt: Date()
        )
    )

    func retryArtifact(id: String) async throws -> ArtifactRetryResponse {
        retryCallCount += 1
        retryCalledWithId = id
        switch retryResult {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// Mock implementation of SearchServiceProtocol for testing.
final class MockSearchService: SearchServiceProtocol {
    var searchCallCount = 0
    var searchCalledWithQuery: String?
    var searchResult: Result<SearchResponse, Error> = .success(
        SearchResponse(items: [], query: "", total: 0)
    )

    func search(query: String) async throws -> SearchResponse {
        searchCallCount += 1
        searchCalledWithQuery = query
        switch searchResult {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

// MARK: - Tests

final class ArtifactGridViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var localDatabase: LocalDatabase!
    private var mockAPIService: MockArtifactAPIService!
    private var mockSearchService: MockSearchService!
    private var viewModel: ArtifactGridViewModel!

    @MainActor
    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.db")
        localDatabase = LocalDatabase(dbPath: dbPath)
        try localDatabase.open()

        mockAPIService = MockArtifactAPIService()
        mockSearchService = MockSearchService()
        viewModel = ArtifactGridViewModel(
            apiService: mockAPIService,
            searchService: mockSearchService,
            localDatabase: localDatabase,
            pageSize: 5
        )
    }

    override func tearDown() async throws {
        await MainActor.run { localDatabase.close() }
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    @MainActor
    private func insertArtifact(
        id: String,
        type: String = "screenshot",
        status: String = "completed",
        tags: [String] = []
    ) throws {
        try localDatabase.insertArtifact(
            id: id,
            type: type,
            contentPath: nil,
            contentText: type == "note" ? "Test note" : nil,
            status: status,
            createdAt: Date()
        )
        if !tags.isEmpty {
            try localDatabase.upsertTags(artifactId: id, tags: tags)
        }
    }

    // MARK: - loadPage Tests

    @MainActor
    func testLoadPageLoadsArtifactsFromDatabase() async throws {
        try insertArtifact(id: "a1")
        try insertArtifact(id: "a2")
        try insertArtifact(id: "a3")

        await viewModel.loadPage()

        XCTAssertEqual(viewModel.artifacts.count, 3)
        XCTAssertEqual(viewModel.totalCount, 3)
        XCTAssertEqual(viewModel.currentPage, 1)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testLoadPageRespectsPageSize() async throws {
        for i in 1...10 {
            try insertArtifact(id: "a\(i)")
        }

        await viewModel.loadPage()

        // pageSize is 5 in test setup
        XCTAssertEqual(viewModel.artifacts.count, 5)
        XCTAssertEqual(viewModel.totalCount, 10)
        XCTAssertTrue(viewModel.hasMore)
    }

    @MainActor
    func testLoadPageSetsErrorOnDatabaseFailure() async throws {
        // Close DB to trigger an error on query
        localDatabase.close()

        await viewModel.loadPage()

        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual(viewModel.artifacts.count, 0)
    }

    @MainActor
    func testLoadPageClearsError() async throws {
        // First, cause an error
        localDatabase.close()
        await viewModel.loadPage()
        XCTAssertNotNil(viewModel.error)

        // Reopen and load again
        let dbPath = tempDir.appendingPathComponent("test.db")
        localDatabase = LocalDatabase(dbPath: dbPath)
        try localDatabase.open()

        // Recreate viewModel with fresh DB
        viewModel = ArtifactGridViewModel(
            apiService: mockAPIService,
            searchService: mockSearchService,
            localDatabase: localDatabase,
            pageSize: 5
        )

        try insertArtifact(id: "a1")
        await viewModel.loadPage()

        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.artifacts.count, 1)
    }

    // MARK: - loadMore Tests

    @MainActor
    func testLoadMoreAppendsNextPage() async throws {
        for i in 1...10 {
            try insertArtifact(id: "a\(i)")
        }

        await viewModel.loadPage()
        XCTAssertEqual(viewModel.artifacts.count, 5)
        XCTAssertEqual(viewModel.currentPage, 1)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.artifacts.count, 10)
        XCTAssertEqual(viewModel.currentPage, 2)
        XCTAssertFalse(viewModel.hasMore)
    }

    @MainActor
    func testLoadMoreDoesNothingWhenNoMore() async throws {
        try insertArtifact(id: "a1")
        try insertArtifact(id: "a2")

        await viewModel.loadPage()
        XCTAssertFalse(viewModel.hasMore)

        await viewModel.loadMore()
        // Should not change
        XCTAssertEqual(viewModel.artifacts.count, 2)
        XCTAssertEqual(viewModel.currentPage, 1)
    }

    @MainActor
    func testHasMoreComputedProperty() async throws {
        for i in 1...7 {
            try insertArtifact(id: "a\(i)")
        }

        await viewModel.loadPage()
        // 5 loaded out of 7 total
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()
        // 7 loaded out of 7 total
        XCTAssertFalse(viewModel.hasMore)
    }

    // MARK: - search Tests

    @MainActor
    func testSearchCallsSearchServiceWithQuery() async throws {
        let items = [
            SearchResultItem(
                id: "s1",
                type: "note",
                contentText: "Test result",
                status: "completed",
                createdAt: Date(),
                updatedAt: Date(),
                tags: ["design"],
                textRank: 0.9,
                vectorSimilarity: 0.8
            )
        ]
        mockSearchService.searchResult = .success(
            SearchResponse(items: items, query: "test", total: 1)
        )

        await viewModel.search(query: "test")

        XCTAssertEqual(mockSearchService.searchCallCount, 1)
        XCTAssertEqual(mockSearchService.searchCalledWithQuery, "test")
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults[0].id, "s1")
        XCTAssertEqual(viewModel.searchResults[0].type, .note)
        XCTAssertEqual(viewModel.searchResults[0].tags, ["design"])
        XCTAssertFalse(viewModel.isSearching)
    }

    @MainActor
    func testSearchSetsErrorOnFailure() async throws {
        mockSearchService.searchResult = .failure(
            NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Server error"])
        )

        await viewModel.search(query: "test")

        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual(viewModel.searchResults.count, 0)
        XCTAssertFalse(viewModel.isSearching)
    }

    // MARK: - clearSearch Tests

    @MainActor
    func testClearSearchRemovesResults() async throws {
        let items = [
            SearchResultItem(
                id: "s1", type: "screenshot", contentText: nil, status: "completed",
                createdAt: Date(), updatedAt: Date(), tags: [], textRank: 0.9, vectorSimilarity: 0.8
            )
        ]
        mockSearchService.searchResult = .success(
            SearchResponse(items: items, query: "test", total: 1)
        )

        await viewModel.search(query: "test")
        XCTAssertEqual(viewModel.searchResults.count, 1)

        viewModel.clearSearch()
        XCTAssertEqual(viewModel.searchResults.count, 0)
    }

    // MARK: - filterByTag Tests

    @MainActor
    func testFilterByTagFiltersArtifacts() async throws {
        try insertArtifact(id: "a1", tags: ["design"])
        try insertArtifact(id: "a2", tags: ["design", "code"])
        try insertArtifact(id: "a3", tags: ["code"])
        try insertArtifact(id: "a4", tags: [])

        await viewModel.filterByTag("design")

        XCTAssertEqual(viewModel.tagFilter, "design")
        XCTAssertEqual(viewModel.artifacts.count, 2)
        let ids = Set(viewModel.artifacts.map { $0.id })
        XCTAssertEqual(ids, Set(["a1", "a2"]))
    }

    @MainActor
    func testFilterByTagNilClearsFilter() async throws {
        try insertArtifact(id: "a1", tags: ["design"])
        try insertArtifact(id: "a2", tags: ["code"])

        // First filter to one tag
        await viewModel.filterByTag("design")
        XCTAssertEqual(viewModel.artifacts.count, 1)

        // Clear filter
        await viewModel.filterByTag(nil)
        XCTAssertNil(viewModel.tagFilter)
        XCTAssertEqual(viewModel.artifacts.count, 2)
    }

    @MainActor
    func testFilterByTagResetsToPageOne() async throws {
        for i in 1...10 {
            try insertArtifact(id: "a\(i)", tags: ["all"])
        }

        await viewModel.loadPage()
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.currentPage, 2)

        await viewModel.filterByTag("all")
        XCTAssertEqual(viewModel.currentPage, 1)
    }

    // MARK: - retryArtifact Tests

    @MainActor
    func testRetryArtifactOptimisticallyUpdatesToPending() async throws {
        try insertArtifact(id: "a1", status: "failed")
        await viewModel.loadPage()
        XCTAssertEqual(viewModel.artifacts[0].status, .failed)

        await viewModel.retryArtifact(id: "a1")

        XCTAssertEqual(viewModel.artifacts[0].status, .pending)
        XCTAssertEqual(mockAPIService.retryCallCount, 1)
        XCTAssertEqual(mockAPIService.retryCalledWithId, "a1")
    }

    @MainActor
    func testRetryArtifactRevertsOnFailure() async throws {
        try insertArtifact(id: "a1", status: "failed")
        await viewModel.loadPage()

        mockAPIService.retryResult = .failure(
            NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Network error"])
        )

        await viewModel.retryArtifact(id: "a1")

        XCTAssertEqual(viewModel.artifacts[0].status, .failed)
        XCTAssertNotNil(viewModel.error)
    }

    @MainActor
    func testRetryArtifactUpdatesSearchResultsToo() async throws {
        // Set up search results containing the same artifact
        let items = [
            SearchResultItem(
                id: "a1", type: "screenshot", contentText: nil, status: "failed",
                createdAt: Date(), updatedAt: Date(), tags: [], textRank: 0.9, vectorSimilarity: 0.8
            )
        ]
        mockSearchService.searchResult = .success(
            SearchResponse(items: items, query: "test", total: 1)
        )
        await viewModel.search(query: "test")
        XCTAssertEqual(viewModel.searchResults[0].status, .failed)

        // Also have it in main artifacts list
        try insertArtifact(id: "a1", status: "failed")
        await viewModel.loadPage()

        await viewModel.retryArtifact(id: "a1")

        XCTAssertEqual(viewModel.searchResults[0].status, .pending)
        XCTAssertEqual(viewModel.artifacts[0].status, .pending)
    }

    // MARK: - loadTags Tests

    @MainActor
    func testLoadTagsPopulatesAllTags() throws {
        try insertArtifact(id: "a1", tags: ["design", "ui"])
        try insertArtifact(id: "a2", tags: ["design"])
        try insertArtifact(id: "a3", tags: ["code"])

        viewModel.loadTags()

        XCTAssertEqual(viewModel.allTags.count, 3)
        // Ordered by count descending
        XCTAssertEqual(viewModel.allTags[0].name, "design")
        XCTAssertEqual(viewModel.allTags[0].count, 2)
    }

    @MainActor
    func testLoadTagsReturnsEmptyWhenNoTags() {
        viewModel.loadTags()
        XCTAssertEqual(viewModel.allTags.count, 0)
    }

    // MARK: - ISO8601 Formatter Tests

    @MainActor
    func testStaticISOFormatterIsShared() {
        let formatter1 = ArtifactGridViewModel.isoFormatter
        let formatter2 = ArtifactGridViewModel.isoFormatter
        XCTAssertTrue(formatter1 === formatter2)
    }

    // MARK: - ArtifactDisplayModel Tests

    func testArtifactDisplayModelToArtifact() {
        let model = ArtifactDisplayModel(
            id: "test-id",
            type: .note,
            status: .completed,
            contentPath: "/path/to/note.md",
            contentText: "Hello world",
            createdAt: Date(),
            syncedAt: Date(),
            tags: ["design", "ui"]
        )

        let artifact = model.toArtifact()
        XCTAssertEqual(artifact.id, "test-id")
        XCTAssertEqual(artifact.type, .note)
        XCTAssertEqual(artifact.status, .completed)
        XCTAssertEqual(artifact.contentPath, "/path/to/note.md")
        XCTAssertEqual(artifact.contentText, "Hello world")
        XCTAssertEqual(artifact.tags, ["design", "ui"])
    }

    func testArtifactDisplayModelDomain() {
        let linkModel = ArtifactDisplayModel(
            id: "link-1",
            type: .link,
            status: .completed,
            contentPath: nil,
            contentText: "https://www.example.com/page",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )
        XCTAssertEqual(linkModel.domain, "www.example.com")

        let noteModel = ArtifactDisplayModel(
            id: "note-1",
            type: .note,
            status: .completed,
            contentPath: nil,
            contentText: "https://www.example.com",
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )
        XCTAssertNil(noteModel.domain) // Only links have domain
    }

    func testArtifactDisplayModelMutableStatus() {
        var model = ArtifactDisplayModel(
            id: "test",
            type: .screenshot,
            status: .failed,
            contentPath: nil,
            contentText: nil,
            createdAt: Date(),
            syncedAt: nil,
            tags: []
        )

        model.status = .pending
        XCTAssertEqual(model.status, .pending)
    }
}
