import AppKit

/// Owns the full capture pipeline: persist locally → show feedback → upload to backend.
/// Replaces the 3 repeated patterns in AppDelegate with a single entry point.
@MainActor
final class CaptureCoordinator {
    private let localDatabase: LocalDatabase
    private let uploadService: ArtifactUploadService
    private let postCaptureThumbnail: PostCaptureThumbnail

    /// Single source of truth for the artifacts directory path.
    static let artifactsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Bundle/artifacts")
    }()

    init(
        localDatabase: LocalDatabase,
        uploadService: ArtifactUploadService,
        postCaptureThumbnail: PostCaptureThumbnail
    ) {
        self.localDatabase = localDatabase
        self.uploadService = uploadService
        self.postCaptureThumbnail = postCaptureThumbnail
    }

    /// Handle any capture result: persist, show thumbnail, upload.
    func handle(_ result: CaptureResult) async {
        guard localDatabase.isOpen else {
            showDatabaseUnavailableAlert()
            return
        }

        let artifactId = UUID().uuidString

        do {
            try insertLocally(result, artifactId: artifactId)
        } catch {
            showCaptureError(error)
            return
        }

        showThumbnail(for: result, artifactId: artifactId)
        await upload(result, artifactId: artifactId)
    }

    // MARK: - Private: Local Insert

    private func insertLocally(_ result: CaptureResult, artifactId: String) throws {
        switch result {
        case .screenshot(let fullPath, _, let createdAt):
            let relativePath = Self.relativePath(for: fullPath)
            try localDatabase.insertArtifact(
                id: artifactId,
                type: "screenshot",
                contentPath: relativePath,
                contentText: nil,
                status: "pending",
                createdAt: createdAt,
                uploadState: "uploading"
            )
        case .note(let filePath, let content, let createdAt):
            let relativePath = Self.relativePath(for: filePath)
            try localDatabase.insertArtifact(
                id: artifactId,
                type: "note",
                contentPath: relativePath,
                contentText: content,
                status: "pending",
                createdAt: createdAt,
                uploadState: "uploading"
            )
        case .link(let url, let createdAt):
            try localDatabase.insertArtifact(
                id: artifactId,
                type: "link",
                contentPath: nil,
                contentText: url,
                status: "pending",
                createdAt: createdAt,
                uploadState: "uploading"
            )
        }
    }

    // MARK: - Private: Thumbnail

    private func showThumbnail(for result: CaptureResult, artifactId: String) {
        let content: ThumbnailContent
        switch result {
        case .screenshot(let fullPath, let thumbnailPath, _):
            content = .screenshot(fullPath: fullPath, thumbnailPath: thumbnailPath)
        case .note(_, let text, _):
            content = .note(text: text)
        case .link(let url, _):
            content = .link(url: url)
        }
        postCaptureThumbnail.show(content: content, artifactId: artifactId)
    }

    // MARK: - Private: Upload

    private func upload(_ result: CaptureResult, artifactId: String) async {
        let response: ArtifactUploadResponse?

        switch result {
        case .screenshot(let fullPath, _, let createdAt):
            response = await uploadService.uploadArtifact(
                fileURL: fullPath, type: "screenshot", createdAt: createdAt
            )
        case .note(let filePath, _, let createdAt):
            response = await uploadService.uploadArtifact(
                fileURL: filePath, type: "note", createdAt: createdAt
            )
        case .link(let url, let createdAt):
            response = await uploadService.uploadLink(url: url, createdAt: createdAt)
        }

        if let response {
            do {
                try localDatabase.replaceArtifactId(
                    oldId: artifactId,
                    newId: response.id.uuidString,
                    status: response.status
                )
            } catch {
                print("[Bundle] ID replacement failed: \(error)")
            }
        } else {
            // Upload failed: reset upload_state so sync/retry can pick it up
            try? localDatabase.setUploadState(artifactId: artifactId, state: "idle")
        }
    }

    // MARK: - Helpers

    /// Compute relative path from the artifacts base directory.
    static func relativePath(for fileURL: URL) -> String {
        let base = artifactsDirectory.path + "/"
        let full = fileURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count))
        }
        return fileURL.lastPathComponent
    }

    private func showDatabaseUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Cannot Capture"
        alert.informativeText = "Local database is not available. Please restart Bundle."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
