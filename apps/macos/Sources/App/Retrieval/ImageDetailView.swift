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
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = maxMagnification

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.setFrameSize(image.size)

        scrollView.documentView = imageView

        // Fit image to scroll view on first layout
        DispatchQueue.main.async {
            self.fitImageToView(in: scrollView)
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

    private func fitImageToView(in scrollView: NSScrollView) {
        let viewSize = scrollView.contentSize
        let imageSize = image.size

        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        let fitScale = min(scaleX, scaleY, 1.0) // Don't upscale small images

        scrollView.minMagnification = fitScale
        scrollView.magnification = fitScale
    }
}
