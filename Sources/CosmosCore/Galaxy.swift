import Foundation
import CoreGraphics

/// The galaxy the welcome draws: a two-armed spiral of stars and glowing gas that gathers out of a scattered cloud, then
/// turns slowly.
///
/// Pure and seeded: where every star is at any moment is a function of the seed and the time, so a frame can be drawn
/// for any instant (and tested) without running anything.
public struct Galaxy: Sendable {
    public struct Star: Sendable, Equatable {
        /// Where it settles in the disc, 0 (centre) to 1 (edge), and at what angle when the turning starts.
        public var radius: Double
        public var angle: Double
        /// Off the disc's plane, in disc units: the disc has a little thickness, most of it at the centre.
        public var height: Double
        /// Where it starts out, in the scattered cloud the galaxy gathers from.
        public var startRadius: Double
        public var startAngle: Double
        /// When it starts falling in, and how long it takes, in seconds.
        public var delay: Double
        public var fall: Double
        /// Its size, relative: the renderer scales it with the galaxy.
        public var size: Double
        /// 0...1.
        public var brightness: Double
        /// Index into the palette (`palette(for:)`): 0 the white-hot centre, outward to 6 at the edge.
        public var tint: Int
    }

    /// Tilt of the disc away from the viewer, and its turn on the screen.
    public static let inclination = 64.0 * Double.pi / 180
    public static let positionAngle = -22.0 * Double.pi / 180
    /// By then every star is in place.
    public static let formation = 3.2

    public let stars: [Star]

    public init(seed: UInt64 = 0xC05_305, stars count: Int = 3400) {
        var rng = SplitMix(seed)
        var out: [Star] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let bulge = i % 7 == 0                     // a seventh of the stars make the bright centre
            let r: Double
            var angle: Double
            if bulge {
                r = min(0.3, abs(rng.gaussian()) * 0.075 + 0.004)
                angle = rng.unit() * 2 * .pi
            } else {
                r = min(1.02, 0.07 + -log(max(1e-6, rng.unit())) * 0.26)
                let inArm = rng.unit() < 0.86
                // Stars crowd the arms' middle and thin out to either side; further out the arms are looser.
                angle = inArm ? Self.armAngle(radius: r, arm: rng.unit() < 0.5 ? 0 : 1) + rng.gaussian() * (0.10 + 0.16 * r)
                              : rng.unit() * 2 * .pi
            }
            angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
            let tint = Self.tint(radius: r, jitter: rng.unit())
            // Most stars are faint; a few are bright.
            let bright = bulge ? 0.5 + rng.unit() * 0.5 : 0.3 + pow(rng.unit(), 1.8) * 0.7
            out.append(Star(
                radius: r, angle: angle, height: rng.gaussian() * 0.03 * (1.1 - r),
                startRadius: 0.6 + rng.unit() * 1.7, startAngle: angle - 1.2 - rng.unit() * 1.0,
                // The centre gathers first and the edge last, each star a little on its own.
                delay: 0.05 + r * 0.95 + rng.unit() * 0.45, fall: 1.4 + rng.unit() * 0.5,
                size: (bulge ? 0.9 : 0.7) + pow(rng.unit(), 7) * 2.6, brightness: bright, tint: tint))
        }
        stars = out
    }

    /// The angle of a spiral arm at `radius`: a logarithmic spiral, the shape real spiral galaxies have, trailing as the
    /// disc turns (the angle grows inward), so stars falling in along it swirl the way it curves.
    public static func armAngle(radius: Double, arm: Int) -> Double {
        Double(arm) * .pi - 2.3 * log(radius + 0.1)
    }

    /// Radians a second at `radius`. The disc turns as one (a full turn in about five minutes) and only the centre a
    /// little faster, so the arms keep their shape however long the welcome is left open.
    public static func angularSpeed(radius: Double) -> Double { 0.021 + 0.014 * exp(-radius / 0.06) }

    private static func tint(radius r: Double, jitter: Double) -> Int {
        let base = r < 0.07 ? 0 : (r < 0.2 ? 1 : (r < 0.36 ? 2 : (r < 0.55 ? 3 : (r < 0.75 ? 4 : 5))))
        return min(6, max(0, base + (jitter < 0.18 ? -1 : (jitter > 0.84 ? 1 : 0))))
    }

    /// Where a star is at `time` (seconds since the galaxy began to gather), on a screen whose disc has radius 1 and its
    /// centre at the origin (y down): its point, how near it is (for size, -1 far to 1 near) and how visible (0...1).
    public static func place(_ s: Star, at time: Double) -> (point: CGPoint, nearness: Double, alpha: Double) {
        let progress = min(1, max(0, (time - s.delay) / s.fall))
        let e = easeOutQuint(progress)
        let settled = s.angle + angularSpeed(radius: s.radius) * time
        let r = s.startRadius + (s.radius - s.startRadius) * e
        let a = s.startAngle + (settled - s.startAngle) * e
        let fadeIn = smoothstep(0, 0.45, progress)
        return (project(x: r * cos(a), y: r * sin(a), height: s.height), r * sin(a) * sin(inclination), s.brightness * fadeIn)
    }

    /// A point of the disc (x, y in disc radii, seen face-on) as it is on the screen: tilted away and turned.
    public static func project(x: Double, y yDisc: Double, height: Double = 0) -> CGPoint {
        let y = yDisc * cos(inclination) + height * sin(inclination)
        return CGPoint(x: x * cos(positionAngle) - y * sin(positionAngle), y: x * sin(positionAngle) + y * cos(positionAngle))
    }

    /// How the gas stands at `time`: the angle it has turned by, how much larger than settled it still is (it gathers
    /// out of a wider swirl) and how much of it shows.
    public static func gas(at time: Double) -> (spin: Double, scale: Double, alpha: Double) {
        let q = min(1, max(0, (time - 0.4) / 2.8))
        let p = easeOutQuint(q)
        return (angularSpeed(radius: 0.5) * time - 1.5 * (1 - p), 1 + 0.85 * (1 - p), smoothstep(0.05, 0.85, q))
    }

    /// How bright the centre glows at `time`: it lights as the stars gather, flares a little as the last ones arrive and
    /// settles.
    public static func coreGlow(at time: Double) -> Double {
        let rise = smoothstep(0.5, 2.3, time)
        let flare = exp(-pow((time - 2.45) / 0.5, 2)) * 0.32
        return rise * 0.85 + flare
    }

    // MARK: The gas

    /// The glowing gas at a point of the disc seen face-on (x, y in disc radii): how much lies in the arms (`inner` near
    /// the centre, `outer` beyond), 0...1 each. Two arms, clumpy, with a dark lane along the inside edge of each, fading
    /// toward the rim. The renderer bakes this into pictures once.
    public static func gas(x: Double, y: Double) -> (inner: Double, outer: Double) {
        let r = hypot(x, y)
        guard r < 1.15, r > 0.015 else { return (0, 0) }
        let theta = atan2(y, x)
        var arms = 0.0, lanes = 0.0
        for arm in 0..<2 {
            let d = wrap(theta - armAngle(radius: r, arm: arm))
            let width = 0.30 + 0.36 * r
            arms += exp(-pow(d / width, 2))
            // The lane runs along the arm's inner, concave edge.
            lanes += exp(-pow((d + width * 0.55) / (width * 0.3), 2))
        }
        // The disc glows everywhere a little, the arms a lot; both are clumpy, and the lanes come and go.
        let disc = exp(-r / 0.3) * 0.5
        let clumps = 0.15 + 1.35 * fbm(x * 6.5, y * 6.5) * (0.6 + 0.4 * fbm(x * 17 + 3.1, y * 17 - 1.7))
        let laneDepth = 0.65 * min(1, lanes) * smoothstep(0.25, 0.65, fbm(x * 9 + 5.3, y * 9 + 2.2))
        let envelope = smoothstep(1.12, 0.5, r) * smoothstep(0.0, 0.12, r)
        let density = min(1, max(0, (disc + 0.8 * arms * clumps) * envelope * (1 - laneDepth)))
        let outerShare = smoothstep(0.28, 0.72, r)
        return (density * (1 - outerShare), density * outerShare)
    }

    /// Bright knots of new stars along the arms (in disc radii, face-on): where, how large, how bright.
    public static func knots(seed: UInt64 = 0x4E_B01A) -> [(x: Double, y: Double, size: Double, brightness: Double)] {
        var rng = SplitMix(seed)
        return (0..<70).map { _ in
            let r = 0.2 + rng.unit() * 0.72
            let a = armAngle(radius: r, arm: rng.unit() < 0.5 ? 0 : 1) + rng.gaussian() * 0.14 + 0.06
            return (r * cos(a), r * sin(a), 0.005 + pow(rng.unit(), 2) * 0.012, 0.25 + rng.unit() * 0.5)
        }
    }

    private static func wrap(_ a: Double) -> Double {
        var a = a.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi } else if a < -.pi { a += 2 * .pi }
        return a
    }

    /// Smooth noise, 0...1, in three octaves.
    static func fbm(_ x: Double, _ y: Double) -> Double {
        var total = 0.0, amplitude = 0.55, frequency = 1.0
        for octave in 0..<3 {
            total += amplitude * valueNoise(x * frequency + Double(octave) * 17.3, y * frequency - Double(octave) * 9.1)
            amplitude *= 0.5
            frequency *= 2.1
        }
        return min(1, total / 0.9625)
    }

    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x), yi = floor(y)
        let fx = x - xi, fy = y - yi
        func corner(_ i: Double, _ j: Double) -> Double {
            var h = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(j)) &* 0xC2B2_AE3D_27D4_EB4F
            h ^= h >> 29; h &*= 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
            return Double(h >> 11) / Double(1 << 53)
        }
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = corner(xi, yi) + (corner(xi + 1, yi) - corner(xi, yi)) * sx
        let bottom = corner(xi, yi + 1) + (corner(xi + 1, yi + 1) - corner(xi, yi + 1)) * sx
        return top + (bottom - top) * sy
    }

    // MARK: Colour

    /// The galaxy's light in a sky's colours, from the white-hot centre (0) out to the edge (6): the sky's brightest
    /// colour near the middle, its deepest at the rim, each lit up so it glows. A pale sky's colours are deepened enough to
    /// read as colour against white text; a grey one stays silver.
    public static func palette(for theme: SpaceTheme) -> [RGBA] {
        let first = theme.colors[0], middle = theme.colors[theme.colors.count / 2], last = theme.colors[theme.colors.count - 1]
        func lit(_ c: RGBA, saturation: Double, brightness: Double = 1) -> RGBA {
            let hsb = c.hsb
            let s = hsb.s < 0.06 ? hsb.s : max(0.42 * saturation, hsb.s * saturation)
            return RGBA.fromHSB(h: hsb.h, s: min(1, s), b: brightness)
        }
        return [
            RGBA(1.0, 0.96, 0.90),
            lit(last, saturation: 0.40),
            lit(last, saturation: 0.85),
            lit(middle, saturation: 0.80),
            lit(first, saturation: 0.75),
            lit(first, saturation: 0.55),
            lit(first, saturation: 0.30),
        ]
    }

    public static func easeOutQuint(_ x: Double) -> Double { 1 - pow(1 - x, 5) }
    public static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

/// A small fast generator with a seed, so the same seed always draws the same sky.
public struct SplitMix: Sendable {
    private var state: UInt64
    public init(_ seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// 0..<1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// A normal distribution, mean 0, deviation 1 (Box–Muller).
    public mutating func gaussian() -> Double {
        let u = max(1e-12, unit()), v = unit()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}

/// Where the welcome's camera looks for each part of the welcome, and how it moves between them: a critically damped
/// spring (it arrives without overshooting), worked out from the time alone so any frame can be drawn on its own.
public struct GalaxyCamera: Equatable, Sendable {
    /// Centre of the galaxy in the window, as fractions of its width and height.
    public var x: Double
    public var y: Double
    /// The disc's radius as a fraction of the window's smaller side.
    public var scale: Double
    /// How much the galaxy is let to shine: 1 full, lower to sit behind words.
    public var light: Double

    public init(x: Double, y: Double, scale: Double, light: Double) { self.x = x; self.y = y; self.scale = scale; self.light = light }

    /// Stiffness of the move, radians a second: settles in about a second.
    public static let stiffness = 5.5

    /// Where the camera is `elapsed` seconds after it set off from `from` toward `to`.
    public static func moving(from: GalaxyCamera, to: GalaxyCamera, elapsed: Double) -> GalaxyCamera {
        guard elapsed > 0 else { return from }
        let w = stiffness * elapsed
        let k = (1 + w) * exp(-w)       // what is left of the way: 1 at the start, 0 at the end
        func mix(_ a: Double, _ b: Double) -> Double { b + (a - b) * k }
        return GalaxyCamera(x: mix(from.x, to.x), y: mix(from.y, to.y), scale: mix(from.scale, to.scale), light: mix(from.light, to.light))
    }
}
