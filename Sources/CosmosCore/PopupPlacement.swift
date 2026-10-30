import CoreGraphics

/// Where an extension's popup goes, in screen coordinates (y up): hanging centred under its button, pushed back inside
/// the screen at either side, above the button when there is more room there, and made shorter when there is room for
/// it neither way. `visible` is the screen without the menu bar and Dock; with none, the popup is under the button as is.
public enum PopupPlacement {
    /// Between the button and the popup.
    public static let gap: CGFloat = 4
    /// The least the popup keeps clear of the screen's edges.
    public static let margin: CGFloat = 8

    public static func frame(under button: CGRect, size: CGSize, visible: CGRect?) -> CGRect {
        guard let visible else {
            return CGRect(x: button.midX - size.width / 2, y: button.minY - gap - size.height, width: size.width, height: size.height)
        }
        let width = max(0, min(size.width, visible.width - 2 * margin))
        let low = visible.minX + margin, high = visible.maxX - margin - width
        let x = min(max(button.midX - width / 2, low), max(low, high))
        let below = button.minY - gap - (visible.minY + margin)
        let above = visible.maxY - margin - (button.maxY + gap)
        if size.height <= below || below >= above {
            let height = max(0, min(size.height, below))
            return CGRect(x: x, y: button.minY - gap - height, width: width, height: height)
        }
        return CGRect(x: x, y: button.maxY + gap, width: width, height: max(0, min(size.height, above)))
    }

    /// The least of a dragged popup's bar that stays across on a screen: enough to take hold of it again.
    public static let grip: CGFloat = 40

    /// Where a popup dragged to `frame` may go: its bar (`bar` high, along its top) stays below the menu bar and above the
    /// bottom of `visible`, with at least `grip` of it across on it, so that it can always be dragged back and closed.
    public static func dragged(_ frame: CGRect, bar: CGFloat, visible: CGRect?) -> CGRect {
        guard let visible else { return frame }
        var moved = frame
        moved.origin.y = min(max(frame.maxY, visible.minY + bar), visible.maxY) - frame.height
        moved.origin.x = min(max(frame.minX, visible.minX + grip - frame.width), visible.maxX - grip)
        return moved
    }

    /// The part of the screen at `point` that a dragged popup keeps its bar in: the screen under it, edges included (a
    /// pointer pushed against the top of a screen is on its very edge), or with none there the nearest. Nil only with no
    /// screens.
    public static func visibleFrame(at point: CGPoint, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect? {
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return screens.min { distance($0.frame) < distance($1.frame) }?.visible
    }

    /// With no button to hang from (a shortcut opened it): in the top-right corner of `page`, inside it and the screen.
    public static func frame(inTopRightOf page: CGRect, size: CGSize, visible: CGRect?) -> CGRect {
        let area = visible.map { $0.intersection(page) }.flatMap { $0.isNull ? nil : $0 } ?? page
        let corner = CGRect(x: area.maxX - margin - size.width / 2, y: area.maxY - margin + gap, width: 0, height: 0)
        return frame(under: corner, size: size, visible: area)
    }
}
