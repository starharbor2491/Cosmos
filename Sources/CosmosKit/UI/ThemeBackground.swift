import SwiftUI
import AppKit
import CosmosCore

/// The window's backdrop for a space: gradient wash, soft nebula glows, a starfield and film grain.
struct ThemeBackground: View {
    let theme: SpaceTheme
    var animated = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                gradient
                glows(in: geo.size)
                if theme.starfield > 0.01 {
                    StarfieldView(density: theme.starfield, seed: UInt64(truncatingIfNeeded: abs(theme.name.hashValue)), animated: animated && !Motion.reduced, light: !theme.prefersLightForeground)
                }
                if theme.intensity < 0.999 {
                    Color(nsColor: .windowBackgroundColor).opacity(1 - theme.intensity)
                }
                GrainOverlay(amount: theme.grain)
            }
        }
        .ignoresSafeArea()
    }

    private var gradient: some View {
        let (start, end) = Self.points(angle: theme.angle)
        let colors = theme.legible.colors.map { Color($0) }
        return LinearGradient(colors: colors.count == 1 ? [colors[0], colors[0].opacity(0.85)] : colors, startPoint: start, endPoint: end)
    }

    private func glows(in size: CGSize) -> some View {
        let painted = theme.legible
        let a = Color(painted.accent)
        let other = Color(painted.colors.last ?? painted.accent)
        return ZStack {
            RadialGradient(colors: [a.opacity(0.34), .clear], center: UnitPoint(x: 0.85, y: 0.05), startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
            RadialGradient(colors: [other.opacity(0.28), .clear], center: UnitPoint(x: 0.05, y: 0.98), startRadius: 0, endRadius: max(size.width, size.height) * 0.5)
        }
    }

    static func points(angle: Double) -> (UnitPoint, UnitPoint) {
        let r = angle * .pi / 180
        let dx = cos(r) * 0.5, dy = -sin(r) * 0.5
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// Deterministic pseudo-random numbers so the same theme always paints the same sky.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct StarfieldView: View {
    struct Star { var x, y, size, alpha, phase, speed: Double; var bright: Bool }

    let density: Double
    let seed: UInt64
    var animated = true
    /// True over light themes: stars become soft dark specks so they stay visible.
    var light = false

    private let stars: [Star]
    /// A window that is not in front does not need its stars to twinkle.
    @Environment(\.controlActiveState) private var activeState

    init(density: Double, seed: UInt64, animated: Bool = true, light: Bool = false) {
        self.density = density; self.seed = seed; self.animated = animated; self.light = light
        var rng = SeededRandom(seed: seed)
        let count = Int(40 + density * 190)
        stars = (0..<count).map { i in
            Star(x: .random(in: 0...1, using: &rng), y: .random(in: 0...1, using: &rng),
                 size: Double.random(in: 0.5...1.5, using: &rng) * (i % 23 == 0 ? 1.8 : 1),
                 alpha: .random(in: 0.25...0.9, using: &rng), phase: .random(in: 0...6.28, using: &rng),
                 speed: .random(in: 0.4...1.6, using: &rng), bright: i % 23 == 0)
        }
    }

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: activeState == .inactive)) { ctx in
                canvas(time: ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: 0)
        }
    }

    private func canvas(time: Double) -> some View {
        Canvas { gc, size in
            let tint = light ? Color(red: 0.2, green: 0.15, blue: 0.4) : Color.white
            for s in stars {
                let twinkle = animated ? 0.65 + 0.35 * sin(time * s.speed + s.phase) : 1
                let a = s.alpha * twinkle * (light ? 0.35 : 1)
                let p = CGPoint(x: s.x * size.width, y: s.y * size.height)
                if s.bright {
                    let glow = s.size * 5
                    gc.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                            with: .radialGradient(Gradient(colors: [tint.opacity(a * 0.5), .clear]), center: p, startRadius: 0, endRadius: glow))
                }
                gc.fill(Path(ellipseIn: CGRect(x: p.x - s.size / 2, y: p.y - s.size / 2, width: s.size, height: s.size)), with: .color(tint.opacity(a)))
            }
            if animated, !light { drawShootingStar(gc, size: size, time: time) }
        }
        .allowsHitTesting(false)
    }

    /// One streak every ~47 s, from a random spot in the upper right, fading as it travels.
    private func drawShootingStar(_ gc: GraphicsContext, size: CGSize, time: Double) {
        let cycle = 47.0, dur = 1.1
        let n = floor(time / cycle)
        let t = (time - n * cycle) / dur
        guard t >= 0, t <= 1 else { return }
        var rng = SeededRandom(seed: seed ^ UInt64(max(0, n)))
        let sx = Double.random(in: 0.45...0.95, using: &rng) * size.width
        let sy = Double.random(in: 0.02...0.3, using: &rng) * size.height
        let len = 140.0, travel = 260.0
        let dx = -cos(0.5), dy = sin(0.5)
        let head = CGPoint(x: sx + dx * travel * t, y: sy + dy * travel * t)
        let tail = CGPoint(x: head.x - dx * len * (1 - t * 0.3), y: head.y - dy * len * (1 - t * 0.3))
        let fade = sin(t * .pi)
        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)
        gc.stroke(path, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.9 * fade)]), startPoint: tail, endPoint: head), lineWidth: 1.4)
    }
}

/// Fine film grain, tiled from a one-off noise bitmap.
struct GrainOverlay: View {
    let amount: Double
    private static let tile: NSImage = {
        let n = 160
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var rng = SeededRandom(seed: 42)
        for i in 0..<(n * n) {
            let v = UInt8.random(in: 0...255, using: &rng)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: n / 2, height: n / 2))
    }()

    var body: some View {
        if amount > 0.01 {
            Image(nsImage: Self.tile)
                .resizable(resizingMode: .tile)
                .opacity(amount * 0.16)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}
