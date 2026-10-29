import AppKit

/// A video in Picture in Picture: the page's own frames, cut to the video's rectangle, scaled to fit. The page keeps
/// streaming frames while this is up, even when its tab is not on screen.
final class ChromiumPictureInPictureView: NSView {
    /// Where the video is in the page's view, in its points; nil until the page has said where it is.
    var videoRect: CGRect? { didSet { if videoRect != oldValue { redraw() } } }
    private(set) var image: CGImage?
    /// The frames' pixels per point of the page's view.
    private var pixelsPerPoint: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func show(_ frame: CGImage, pixelsPerPoint: CGFloat) {
        image = frame
        self.pixelsPerPoint = pixelsPerPoint
        redraw()
    }

    /// The video's rectangle in the frames, in their pixels.
    var crop: CGRect? {
        videoRect.map { CGRect(x: $0.minX * pixelsPerPoint, y: $0.minY * pixelsPerPoint, width: $0.width * pixelsPerPoint, height: $0.height * pixelsPerPoint) }
    }

    private func redraw() {
        guard let image, let crop else { return }
        let inside = crop.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return }
        layer?.contents = image.cropping(to: inside)
    }
}
