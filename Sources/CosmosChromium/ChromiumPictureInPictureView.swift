import AppKit

/// A video in Picture in Picture: the page's own frames, cut to the video's rectangle, scaled to fit. The page keeps
/// streaming frames while this is up, even when its tab is not on screen.
final class ChromiumPictureInPictureView: NSView {
    /// The video's rectangle in the frames, in their pixels; nil until the page has said where it is.
    var crop: CGRect? { didSet { if crop != oldValue { redraw() } } }
    private(set) var image: CGImage?

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

    func show(_ frame: CGImage) {
        image = frame
        redraw()
    }

    private func redraw() {
        guard let image, let crop else { return }
        let inside = crop.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return }
        layer?.contents = image.cropping(to: inside)
    }
}
