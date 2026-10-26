import AppKit

/// Trackpad feedback. Force Touch trackpads tick under the finger; on anything else these calls do nothing.
/// Used sparingly: a tick means "something snapped, switched or landed", never decoration. Each store owns one, so
/// the Settings switch applies to every window and tests can watch what would have been felt.
@MainActor
final class Haptics {
    enum Pattern: Equatable { case generic, alignment, levelChange }

    /// Settings ▸ General ▸ Trackpad haptics.
    var isEnabled = true
    /// Where ticks go. Tests replace it.
    var output: (Pattern) -> Void = Haptics.system

    /// A drag lifted, or an action with weight (closing a tab, copying a link).
    func generic() { play(.generic) }
    /// Something snapped into place: a drop marker moved to a new gap, a swipe crossed its threshold, a folder opened.
    func alignment() { play(.alignment) }
    /// A step up or down: a drop landed, a space changed, a tab was pinned, Peek opened.
    func levelChange() { play(.levelChange) }

    private func play(_ pattern: Pattern) {
        guard isEnabled else { return }
        output(pattern)
    }

    private static func system(_ pattern: Pattern) {
        let system: NSHapticFeedbackManager.FeedbackPattern
        switch pattern {
        case .generic: system = .generic
        case .alignment: system = .alignment
        case .levelChange: system = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(system, performanceTime: .now)
    }
}
