import AppKit

/// The window a video plays in while it is in Picture in Picture: small, over every other window and on every Space,
/// keeping the video's shape as it is resized. Closing it puts the video back in its page; the button in its corner
/// goes back to the tab.
@MainActor
final class PictureInPicturePanel: NSPanel, NSWindowDelegate {
    private(set) weak var runtime: TabRuntime?
    var onBackToTab: (() -> Void)?
    /// The window is going: whoever keeps it lets go first, so the end it reports does not close it a second time.
    var onClose: (() -> Void)?
    /// The page ended it first: closing the window has nothing to give back.
    private var endedByPage = false

    init(showing video: NSView, for tab: TabRuntime) {
        runtime = tab
        let size = NSSize(width: 400, height: 225)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        title = tab.title.isEmpty ? "Picture in Picture" : tab.title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentAspectRatio = size
        minSize = NSSize(width: 200, height: 112)
        delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        video.frame = content.bounds
        video.autoresizingMask = [.width, .height]
        content.addSubview(video)
        let back = NSButton(image: NSImage(systemSymbolName: "arrow.up.backward.square", accessibilityDescription: "Back to tab") ?? NSImage(),
                            target: self, action: #selector(backToTab))
        back.isBordered = false
        back.contentTintColor = .white
        back.toolTip = "Back to tab"
        back.frame = NSRect(x: size.width - 34, y: size.height - 34, width: 24, height: 24)
        back.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(back)
        contentView = content

        // The lower right of the screen, as macOS puts its own.
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20))
        }
    }

    @objc private func backToTab() {
        onBackToTab?()
        close()
    }

    /// The page (or its video) ended Picture in Picture.
    func closeBecausePageEnded() {
        endedByPage = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        if !endedByPage { runtime?.exitPictureInPicture() }
    }
}
