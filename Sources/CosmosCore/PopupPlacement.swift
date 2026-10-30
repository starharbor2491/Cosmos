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

    /// With no button to hang from (a shortcut opened it): in the top-right corner of `page`, inside it and the screen.
    public static func frame(inTopRightOf page: CGRect, size: CGSize, visible: CGRect?) -> CGRect {
        let area = visible.map { $0.intersection(page) }.flatMap { $0.isNull ? nil : $0 } ?? page
        let corner = CGRect(x: area.maxX - margin - size.width / 2, y: area.maxY - margin + gap, width: 0, height: 0)
        return frame(under: corner, size: size, visible: area)
    }
}
