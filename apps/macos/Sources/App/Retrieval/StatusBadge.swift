import SwiftUI

/// A small status badge overlay displayed in the top-right corner of an artifact tile.
/// Shows processing state (spinner for pending/processing, error icon for failed).
struct StatusBadge: View {
    let status: String
    let onRetry: () -> Void

    @State private var isRetrying = false

    var body: some View {
        switch status {
        case "pending", "processing":
            loadingBadge
        case "failed":
            failedBadge
        default:
            EmptyView()
        }
    }

    // MARK: - Loading Badge

    private var loadingBadge: some View {
        Circle()
            .fill(Color.black.opacity(0.5))
            .frame(width: 24, height: 24)
            .overlay {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
    }

    // MARK: - Failed Badge

    private var failedBadge: some View {
        Button(action: handleRetry) {
            Circle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 28, height: 28)
                .overlay {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isRetrying)
    }

    private func handleRetry() {
        isRetrying = true
        onRetry()
    }
}
