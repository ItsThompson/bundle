import AppKit
import SwiftUI

/// Shared navigation state between RetrievalPanel and RetrievalContentView.
/// Allows the panel's Escape key handler to know whether detail view is active.
@MainActor
final class RetrievalNavigationState: ObservableObject {
    @Published var isShowingDetail = false
    var onBack: (() -> Void)?
}

/// Root content view for the retrieval panel. Manages navigation between
/// the artifact grid and the artifact detail view.
/// Preserves grid scroll position when navigating to/from detail.
struct RetrievalContentView: View {
    let localDatabase: LocalDatabase
    @ObservedObject var syncService: SyncService
    @ObservedObject var navigationState: RetrievalNavigationState

    @State private var selectedArtifact: Artifact?

    var body: some View {
        Group {
            if let artifact = selectedArtifact {
                ArtifactDetailView(artifact: artifact, onBack: navigateBack)
                    .transition(.move(edge: .trailing))
            } else {
                ArtifactGridContainer(
                    localDatabase: localDatabase,
                    syncService: syncService,
                    onArtifactTap: { artifact in
                        handleArtifactTap(artifact)
                    }
                )
                .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedArtifact?.id)
    }

    // MARK: - Navigation

    private func handleArtifactTap(_ artifact: Artifact) {
        // Link tiles open in the default browser instead of showing detail view
        if artifact.type == .link, let urlString = artifact.contentText,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            return
        }

        selectedArtifact = artifact
        navigationState.isShowingDetail = true
        navigationState.onBack = { navigateBack() }
    }

    private func navigateBack() {
        selectedArtifact = nil
        navigationState.isShowingDetail = false
        navigationState.onBack = nil
    }
}
