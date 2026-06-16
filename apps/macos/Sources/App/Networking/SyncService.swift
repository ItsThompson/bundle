import Combine
import Foundation

/// Manages bidirectional sync between the macOS app and backend.
///
/// Responsibilities:
/// - Polls for updated artifacts every 30 seconds while active
/// - Performs immediate sync when started (panel opened)
/// - Handles initial full sync when local cache is empty
/// - Uses exponential backoff on repeated failures (30s → 60s → 120s → cap 5min)
/// - Updates local SQLite with new/changed artifacts and tags
@MainActor
final class SyncService: ObservableObject {
    /// Whether a sync is currently in progress.
    @Published private(set) var isSyncing = false

    /// Progress for initial sync (0.0 to 1.0), nil when not doing initial sync.
    @Published private(set) var initialSyncProgress: Double?

    private let apiClient: APIClient
    private let localDatabase: LocalDatabase
    private let uploadService: ArtifactUploadService
    private var pollingTask: Task<Void, Never>?
    private var isActive = false

    /// Base polling interval in seconds.
    private let baseInterval: TimeInterval = 5

    /// Maximum backoff interval (5 minutes).
    private let maxInterval: TimeInterval = 300

    /// Current consecutive failure count for backoff calculation.
    private var consecutiveFailures = 0

    init(apiClient: APIClient = APIClient(), localDatabase: LocalDatabase, uploadService: ArtifactUploadService = ArtifactUploadService()) {
        self.apiClient = apiClient
        self.localDatabase = localDatabase
        self.uploadService = uploadService
    }

    // MARK: - Public API

    /// Start the sync service: performs immediate sync, then polls at intervals.
    /// Called when the retrieval panel opens.
    func start() {
        guard !isActive else { return }
        isActive = true
        consecutiveFailures = 0

        pollingTask = Task { [weak self] in
            // Immediate sync on start
            await self?.performSync()

            // Polling loop
            while !Task.isCancelled {
                guard let self = self else { return }
                let interval = self.currentInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.performSync()
            }
        }
    }

    /// Stop the sync service. Called when the retrieval panel closes.
    func stop() {
        isActive = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Perform a one-shot sync (e.g., triggered by pull-to-refresh).
    func syncNow() async {
        await performSync()
    }

    // MARK: - Sync Logic

    private func performSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let hasEverSynced = try localDatabase.getLastSyncTimestamp() != nil
            if !hasEverSynced {
                try await performInitialSync()
            } else {
                try await performDeltaSync()
            }
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            print("[Bundle] Sync failed (attempt \(consecutiveFailures)): \(error.localizedDescription)")
        }

        // Retry uploading any pending local artifacts
        await retryPendingUploads()
    }

    /// Full sync: download all artifact metadata with progress indicator.
    private func performInitialSync() async throws {
        initialSyncProgress = 0.0
        defer { initialSyncProgress = nil }

        var offset = 0
        let limit = 100
        var totalFetched = 0
        var totalAvailable = 0

        repeat {
            let response: SyncListResponse = try await apiClient.request(
                method: .get,
                path: "/api/v1/artifacts?limit=\(limit)&offset=\(offset)"
            )
            totalAvailable = response.total

            for item in response.items {
                try upsertArtifact(item)
            }

            totalFetched += response.items.count
            offset += limit

            if totalAvailable > 0 {
                initialSyncProgress = Double(totalFetched) / Double(totalAvailable)
            }
        } while totalFetched < totalAvailable

        initialSyncProgress = 1.0

        // Save the sync timestamp
        try localDatabase.setLastSyncTimestamp(Date())
    }

    /// Delta sync: fetch only artifacts modified since last sync.
    private func performDeltaSync() async throws {
        let lastSync = try localDatabase.getLastSyncTimestamp()
        let sinceParam: String

        if let lastSync = lastSync {
            sinceParam = ISO8601DateFormatter().string(from: lastSync)
        } else {
            // Fallback: if no last sync timestamp but have artifacts, sync from epoch
            sinceParam = "1970-01-01T00:00:00Z"
        }

        var offset = 0
        let limit = 100

        while true {
            let response: SyncListResponse = try await apiClient.request(
                method: .get,
                path: "/api/v1/artifacts?updated_since=\(sinceParam)&limit=\(limit)&offset=\(offset)"
            )

            for item in response.items {
                try upsertArtifact(item)
            }

            if response.items.count < limit {
                break
            }
            offset += limit
        }

        // Update the sync timestamp to now
        try localDatabase.setLastSyncTimestamp(Date())
    }

    // MARK: - Local Database Operations

    /// Insert or update an artifact in local SQLite from a sync response.
    /// Skips artifacts currently being uploaded to prevent the upload/sync race.
    private func upsertArtifact(_ item: SyncArtifactResponse) throws {
        let artifactId = item.id.uuidString

        // Check if this artifact is currently being uploaded: skip to prevent race
        let uploadState = try localDatabase.getUploadState(for: artifactId)
        if uploadState == "uploading" {
            print("[Bundle] Sync skip: artifact \(artifactId) is currently uploading")
            return
        }

        try localDatabase.upsertArtifactFromSync(
            id: artifactId,
            type: item.type,
            contentText: item.contentText,
            status: item.status,
            createdAt: item.createdAt,
            syncedAt: Date()
        )

        // Update tags for this artifact
        if !item.tags.isEmpty {
            try localDatabase.upsertTags(artifactId: artifactId, tags: item.tags)
        }
    }

    // MARK: - Retry Pending Uploads

    /// Upload any local artifacts still in "pending" status (failed initial upload).
    /// On success, updates local status to match the backend response.
    private func retryPendingUploads() async {
        let pendingArtifacts: [LocalArtifact]
        do {
            pendingArtifacts = try localDatabase.getPendingArtifacts()
        } catch {
            print("[Bundle] Failed to query pending artifacts: \(error)")
            return
        }

        guard !pendingArtifacts.isEmpty else { return }
        print("[Bundle] Retrying upload for \(pendingArtifacts.count) pending artifact(s)")

        let artifactsDir = ArtifactContentService.defaultArtifactsDirectory

        for artifact in pendingArtifacts {
            guard !Task.isCancelled else { return }

            let response: ArtifactUploadResponse?

            switch artifact.type {
            case "link":
                guard let urlString = artifact.contentText else { continue }
                response = await uploadService.uploadLink(
                    url: urlString,
                    createdAt: parseDate(artifact.createdAt)
                )

            case "screenshot", "note":
                guard let contentPath = artifact.contentPath else { continue }
                let fileURL = artifactsDir.appendingPathComponent(contentPath)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    print("[Bundle] Retry skip: file missing for \(artifact.id)")
                    continue
                }
                response = await uploadService.uploadArtifact(
                    fileURL: fileURL,
                    type: artifact.type,
                    createdAt: parseDate(artifact.createdAt)
                )

            default:
                continue
            }

            if let response = response {
                // Replace local ID with backend ID so sync won't create a duplicate
                let backendId = response.id.uuidString
                do {
                    try localDatabase.replaceArtifactId(
                        oldId: artifact.id,
                        newId: backendId,
                        status: response.status
                    )
                    print("[Bundle] Retry upload succeeded: \(artifact.id) → \(backendId) (\(response.status))")
                } catch {
                    print("[Bundle] Retry ID replacement failed for \(artifact.id): \(error.localizedDescription)")
                }
            }
        }
    }

    private func parseDate(_ isoString: String) -> Date {
        ISO8601DateFormatter().date(from: isoString) ?? Date()
    }

    // MARK: - Backoff Calculation

    /// Current polling interval based on consecutive failures.
    /// 30s → 60s → 120s → 240s → 300s (capped)
    private var currentInterval: TimeInterval {
        guard consecutiveFailures > 0 else { return baseInterval }
        let backoff = baseInterval * pow(2.0, Double(consecutiveFailures - 1))
        return min(backoff, maxInterval)
    }
}
