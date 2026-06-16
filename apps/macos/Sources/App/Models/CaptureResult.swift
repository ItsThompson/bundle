import Foundation

/// Discriminated union representing the outcome of any capture type.
/// The coordinator dispatches on this to perform the insert → thumbnail → upload pipeline.
enum CaptureResult {
    case screenshot(
        fullPath: URL,
        thumbnailPath: URL,
        createdAt: Date
    )
    case note(
        filePath: URL,
        content: String,
        createdAt: Date
    )
    case link(
        url: String,
        createdAt: Date
    )
}
