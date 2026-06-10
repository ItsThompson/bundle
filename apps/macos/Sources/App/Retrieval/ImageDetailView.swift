import SwiftUI

/// Full-resolution image viewer with zoom (scroll wheel / pinch) and pan support.
/// Uses NSScrollView + NSImageView under the hood for smooth magnification.
struct ImageDetailView: View {
    let imageURL: URL

    @State private var magnification: CGFloat = 1.0
    @State private var nsImage: NSImage?

    private let minMagnification: CGFloat = 1.0
    private let maxMagnification: CGFloat = 5.0

    var body: some View {
        Group {
            if let image = nsImage {
                ZoomableImageView(
                    image: image,
                    magnification: $magnification,
                    minMagnification: minMagnification,
                    maxMagnification: maxMagnification
                )
            } else {
                loadingPlaceholder
            }
        }
        .onAppear { loadImage() }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading image…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadImage() {
        nsImage = NSImage(contentsOf: imageURL)
    }
}

/// NSViewRepresentable wrapping NSScrollView + NSImageView for native zoom/pan.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    @Binding var magnification: CGFloat
    let minMagnification: CGFloat
    let maxMagnification: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minMagnification
        scrollView.maxMagnification = maxMagnification
        scrollView.magnification = magnification

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setFrameSize(image.size)

        scrollView.documentView = imageView

        // Center the image initially
        DispatchQueue.main.async {
            self.centerImage(in: scrollView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Only update image if it actually changed (avoid resetting user zoom/pan)
        if let imageView = scrollView.documentView as? NSImageView,
           imageView.image !== image {
            imageView.image = image
            imageView.setFrameSize(image.size)
        }
        // Do NOT reset magnification here: the user controls zoom via scroll/pinch.
        // The NSScrollView handles magnification natively.
    }

    private func centerImage(in scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let viewSize = scrollView.contentSize
        let documentSize = documentView.frame.size

        let xOffset = max(0, (documentSize.width - viewSize.width) / 2)
        let yOffset = max(0, (documentSize.height - viewSize.height) / 2)

        documentView.scroll(NSPoint(x: xOffset, y: yOffset))
    }
}
