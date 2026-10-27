import SwiftUI

/// What a loading bar shows, from what WebKit reports. WebKit's estimate jumps about, starts over on a redirect and says 1
/// a moment before the page is done, so the bar keeps its own: it starts from the left, only moves forward, never claims to
/// be finished while the page is loading, fills when the page is done, and then goes.
struct LoadingBarState: Equatable {
    enum Phase { case idle, loading, finishing }

    /// The least a load shows, so a page that has not reported anything yet already has a bar.
    static let minimum = 0.08
    /// The most it shows while the page is still loading.
    static let ceiling = 0.92

    private(set) var phase = Phase.idle
    private(set) var fraction = 0.0
    /// Counts each new load: the view moves back to the left without animating it.
    private(set) var restarts = 0
    /// Counts each change of phase: a timer that was set for an earlier one is ignored.
    private(set) var generation = 0

    mutating func update(isLoading: Bool, progress: Double) {
        let estimate = progress.isNaN ? 0 : min(max(progress, 0), 1)
        if isLoading {
            if phase != .loading { phase = .loading; fraction = Self.minimum; restarts += 1; generation += 1 }
            fraction = max(fraction, min(max(estimate, Self.minimum), Self.ceiling))
        } else if phase == .loading {
            phase = .finishing
            fraction = 1
            generation += 1
        }
    }

    /// The bar has been full long enough: it goes. Nothing happens if another load has started since.
    mutating func finish(generation expected: Int) {
        guard expected == generation, phase == .finishing else { return }
        phase = .idle
        fraction = 0
        generation += 1
    }
}

/// A thin line that fills along a page's address while it loads. A soft light runs along it while the page is still
/// loading, so a load that has stalled halfway still looks alive.
struct LoadingBar: View {
    let isLoading: Bool
    let progress: Double
    var height: CGFloat = 2
    @Environment(\.palette) private var palette
    @Local private var state = LoadingBarState()

    var body: some View {
        GeometryReader { g in
            Capsule().fill(palette.accent)
                .overlay { shimmer }
                .frame(width: max(height, g.size.width * state.fraction), height: height)
                // A load that starts over jumps back to the left; only moving forward is animated.
                .transaction(value: state.restarts) { $0.animation = nil }
                .animation(Motion.standard, value: state.fraction)
                .opacity(state.phase == .loading ? 1 : 0)
                // Done: the bar fills, stays a moment, and fades.
                .animation(state.phase == .loading ? Motion.quick : Motion.standard?.delay(0.2), value: state.phase)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isLoading, initial: true) { _, _ in state.update(isLoading: isLoading, progress: progress) }
        .onChange(of: progress) { _, _ in state.update(isLoading: isLoading, progress: progress) }
        .onChange(of: state.generation) { _, generation in
            guard state.phase == .finishing else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                state.finish(generation: generation)
            }
        }
    }

    private var shimmer: some View {
        TimelineView(.animation(paused: state.phase != .loading)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            GeometryReader { g in
                let glow = max(24, g.size.width * 0.35)
                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: glow)
                    .offset(x: (g.size.width + glow) * t - glow)
            }
        }
        .clipShape(Capsule())
    }
}
