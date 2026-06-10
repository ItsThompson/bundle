import Foundation

/// Response from artifact upload endpoint.
struct ArtifactUploadResponse: Decodable {
    let id: UUID
    let type: String
    let status: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Handles artifact upload to the backend.
/// Upload failures do not block the capture flow: artifacts stay in local SQLite for retry.
final class ArtifactUploadService {
    private let baseURL: String
    private let session: URLSession
    private let tokenStore: TokenStore

    init(
        baseURL: String = APIClient.defaultBaseURL,
        tokenStore: TokenStore = KeychainManager(),
        session: URLSession = .ephemeral
    ) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.session = session
    }

    /// Upload an artifact file to the backend asynchronously.
    /// Returns the response on success, nil on failure (failure is non-blocking).
    func uploadArtifact(
        fileURL: URL,
        type: String,
        createdAt: Date
    ) async -> ArtifactUploadResponse? {
        guard let token = tokenStore.getAccessToken() else {
            print("[Bundle] Upload skipped: not authenticated")
            return nil
        }

        guard let url = URL(string: "\(baseURL)/api/v1/artifacts") else {
            print("[Bundle] Upload failed: invalid URL")
            return nil
        }

        // Build multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let isoFormatter = ISO8601DateFormatter()
        let createdAtStr = isoFormatter.string(from: createdAt)

        guard let fileData = try? Data(contentsOf: fileURL) else {
            print("[Bundle] Upload failed: could not read file")
            return nil
        }

        let body = buildMultipartBody(
            boundary: boundary,
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            type: type,
            createdAt: createdAtStr
        )
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            if httpResponse.statusCode == 201 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(ArtifactUploadResponse.self, from: data)
            }

            print("[Bundle] Upload failed: HTTP \(httpResponse.statusCode)")
            return nil
        } catch {
            print("[Bundle] Upload failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Upload a link artifact to the backend.
    /// Creates a minimal JSON file with the URL and sends content_text.
    /// Returns the response on success, nil on failure (failure is non-blocking).
    func uploadLink(
        url: String,
        createdAt: Date
    ) async -> ArtifactUploadResponse? {
        guard let token = tokenStore.getAccessToken() else {
            print("[Bundle] Upload skipped: not authenticated")
            return nil
        }

        guard let endpoint = URL(string: "\(baseURL)/api/v1/artifacts") else {
            print("[Bundle] Upload failed: invalid URL")
            return nil
        }

        // Build multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let isoFormatter = ISO8601DateFormatter()
        let createdAtStr = isoFormatter.string(from: createdAt)

        // Create a minimal JSON file containing the URL
        let jsonContent = "{\"url\": \"\(url)\"}\n"
        guard let fileData = jsonContent.data(using: .utf8) else {
            print("[Bundle] Upload failed: could not encode URL")
            return nil
        }

        let body = buildLinkMultipartBody(
            boundary: boundary,
            fileData: fileData,
            url: url,
            createdAt: createdAtStr
        )
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            if httpResponse.statusCode == 201 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(ArtifactUploadResponse.self, from: data)
            }

            print("[Bundle] Upload failed: HTTP \(httpResponse.statusCode)")
            return nil
        } catch {
            print("[Bundle] Upload failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Multipart Body Builder

    private func buildMultipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        type: String,
        createdAt: String
    ) -> Data {
        var body = Data()

        // File field
        let mimeType = mimeTypeForArtifact(type: type, fileName: fileName)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        // Type field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"type\"\r\n\r\n")
        body.appendString("\(type)\r\n")

        // Created_at field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"created_at\"\r\n\r\n")
        body.appendString("\(createdAt)\r\n")

        // Closing boundary
        body.appendString("--\(boundary)--\r\n")

        return body
    }
    private func buildLinkMultipartBody(
        boundary: String,
        fileData: Data,
        url: String,
        createdAt: String
    ) -> Data {
        var body = Data()

        // File field (JSON with the URL)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"link.json\"\r\n")
        body.appendString("Content-Type: application/json\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        // Type field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"type\"\r\n\r\n")
        body.appendString("link\r\n")

        // Created_at field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"created_at\"\r\n\r\n")
        body.appendString("\(createdAt)\r\n")

        // Content_text field (URL string for backend DB storage)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"content_text\"\r\n\r\n")
        body.appendString("\(url)\r\n")

        // Closing boundary
        body.appendString("--\(boundary)--\r\n")

        return body
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// MARK: - MIME Type Helper

private func mimeTypeForArtifact(type: String, fileName: String) -> String {
    switch type {
    case "screenshot":
        return "image/png"
    case "note":
        return "text/markdown"
    case "link":
        return "application/json"
    default:
        return "application/octet-stream"
    }
}
