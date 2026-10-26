import AppKit

/// Trackpad feedback. Force Touch trackpads tick under the finger; on anything else these calls do nothing.
/// Used sparingly: a tick means "something snapped, switched or landed", never decoration.
@MainActor
enum Haptics {
    /// Settings ▸ General ▸ Trackpad haptics.
    static var isEnabled = true

    /// A drag lifted, or a button that has weight (closing a tab, pinning).
    static func generic() { perform(.generic) }
    /// Something snapped into place: a drop marker moved to a new gap, a swipe crossed its threshold.
    static func alignment() { perform(.alignment) }
    /// A step up or down: a drop landed, a space changed, a tab was pinned.
    static func levelChange() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
