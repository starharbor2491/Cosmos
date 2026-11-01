import SwiftUI
import AppKit
import CosmosCore

/// What a frame of the galaxy shows, apart from the stars' own motion: where the camera is, how near it has come, the
/// colours (and a change between two palettes under way), a pulse of light, and the way in's bloom.
struct GalaxyFrame {
    var camera: GalaxyCamera
    var zoom = 1.0
    var from: [RGBA]
    var to: [RGBA]
    /// How far the colours have gone from `from` to `to`, 0...1.
    var mix = 1.0
    /// Extra light, 0...1: the galaxy answering a choice.
    var pulse = 0.0
    /// The core's light filling the window on the way in, 0...1.
    var bloom = 0.0

    var palette: [RGBA] { mix >= 1 ? to : (mix <= 0 ? from : zip(from, to).map { $0.mixed(with: $1, mix) }) }
}

/// Deep space with the galaxy in it (`Galaxy`). Every frame is a function of `time`: a live view runs a timeline from
/// `start`, a picture of one moment passes the moment.
struct GalaxyView: View {
    let galaxy: Galaxy
    let sprites: GalaxySprites
    /// Seconds since the galaxy began to gather. Without it the view runs on its own from `start`.
    var time: Double?
    var start: Date = .now
    var frame: (Double) -> GalaxyFrame
    /// The pointer, -1...1 across the window, for the layers' parallax (read each frame, so moving it redraws nothing else).
    var pointer: () -> CGPoint = { .zero }
    /// Something is moving that needs every frame (the opening, the camera, the colours, the way in); otherwise the slow
    /// turning is drawn thirty times a second.
    var lively = true
    @Local private var smoothed = Smoothed()

    /// The pointer as the layers follow it: a little behind, so a quick move eases rather than jumps.
    final class Smoothed {
        var point = CGPoint.zero
        var last: Double?
        func follow(_ target: CGPoint, at time: Double) -> CGPoint {
            let dt = last.map { min(0.1, max(0, time - $0)) } ?? 1
            last = time
            let k = 1 - exp(-dt * 4)
            point = CGPoint(x: point.x + (target.x - point.x) * k, y: point.y + (target.y - point.y) * k)
            return point
        }
    }

    var body: some View {
        if let time {
            canvas(time: time, pointer: .zero)
        } else {
            TimelineView(.animation(minimumInterval: lively ? nil : 1.0 / 30)) { context in
                let t = context.date.timeIntervalSince(start)
                canvas(time: t, pointer: Motion.reduced ? .zero : smoothed.follow(pointer(), at: t))
            }
        }
    }

    private func canvas(time: Double, pointer: CGPoint) -> some View {
        // Reduce Motion: the galaxy as it ends up, holding still (the camera and colours still change, without moving).
        let t = Motion.reduced && self.time == nil ? Galaxy.formation + 1 : time
        let frame = frame(time)
        return Canvas { ctx, size in
            GalaxyPainter.paint(&ctx, size: size, galaxy: galaxy, sprites: sprites, time: t, frame: frame, pointer: pointer)
        }
        .drawingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Paints a frame. Light adds up (`plusLighter`), as it does on a long exposure, so dense places glow.
@MainActor
enum GalaxyPainter {
    static func paint(_ ctx: inout GraphicsContext, size: CGSize, galaxy: Galaxy, sprites: GalaxySprites, time t: Double, frame: GalaxyFrame,
                      pointer: CGPoint) {
        let bounds = CGRect(origin: .zero, size: size)
        let side = min(size.width, size.height)
        let camera = frame.camera, palette = frame.palette
        let light = min(1, camera.light + frame.pulse * 0.3)
        let centre = CGPoint(x: camera.x * size.width, y: camera.y * size.height)
        func colour(_ i: Int) -> Color { Color(palette[i]) }

        // The dark, with a breath of the galaxy's colour around it.
        ctx.fill(Path(bounds), with: .color(Color(red: 0.012, green: 0.014, blue: 0.034)))
        ctx.fill(Path(bounds), with: .radialGradient(Gradient(colors: [colour(4).opacity(0.16 * light + 0.04), .clear]),
                                                     center: centre, startRadius: 0, endRadius: side * 1.25))

        // The far stars, tiled at their own size (so they stay sharp in any window), moving a little against the pointer.
        let drift = CGPoint(x: -pointer.x * 7, y: -pointer.y * 5)
        ctx.fill(Path(bounds), with: .tiledImage(sprites.field, origin: drift, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 0.5))
        // Each picture is resolved once a frame; the thousands of draws reuse it.
        let glow = ctx.resolve(sprites.glow)

        ctx.blendMode = .plusLighter
        // Clouds of gas far behind, drifting very slowly.
        for cloud in GalaxySprites.clouds {
            let wander = CGPoint(x: sin(t * 0.021 + cloud.phase) * 0.02, y: cos(t * 0.017 + cloud.phase) * 0.015)
            let p = CGPoint(x: (cloud.x + wander.x) * size.width - pointer.x * 12, y: (cloud.y + wander.y) * size.height - pointer.y * 9)
            let r = cloud.size * side
            var c = ctx
            c.opacity = cloud.alpha * (0.55 + 0.45 * light)
            c.addFilter(.colorMultiply(colour(cloud.tint)))
            c.draw(glow, in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        let radius = camera.scale * side * frame.zoom
        let origin = CGPoint(x: centre.x - pointer.x * 20, y: centre.y - pointer.y * 14)
        // On the way in, everything thins out as it rushes past.
        let rushing = max(0, frame.zoom - 1.02)
        let fade = 1 / (1 + rushing * 0.3)

        // The gas: the disc's arms, seen face-on in the pictures, tilted and turned here.
        let gas = Galaxy.gas(at: t)
        if gas.alpha > 0.002 {
            var disc = ctx
            disc.translateBy(x: origin.x, y: origin.y)
            disc.rotate(by: .radians(Galaxy.positionAngle))
            disc.scaleBy(x: 1, y: cos(Galaxy.inclination))
            disc.rotate(by: .radians(gas.spin))
            let extent = radius * gas.scale * GalaxyArt.extent
            let rect = CGRect(x: -extent, y: -extent, width: 2 * extent, height: 2 * extent)
            for (layer, tint, strength) in [(sprites.gasOuter, 4, 0.85), (sprites.gasInner, 2, 0.95), (sprites.gasKnots, 1, 0.9)] {
                var c = disc
                c.opacity = gas.alpha * strength * (0.3 + 0.7 * light) * fade
                c.addFilter(.colorMultiply(colour(tint)))
                c.draw(layer, in: rect)
            }
        }

        // The stars. While the colours change, the old palette's stars fade under the new one's, which adds up to the
        // mix exactly (the light is additive) without making new pictures each frame.
        let next = sprites.stars(for: frame.to).map { ctx.resolve($0) }
        var layers = [(images: next, weight: 1.0)]
        if frame.mix < 1 {
            layers = [(sprites.stars(for: frame.from).map { ctx.resolve($0) }, 1 - frame.mix), (next, frame.mix)]
        }
        let starScale = sqrt(max(0.25, radius / 300))
        let previous = radius / (1 + min(0.14, rushing * 0.05))
        let visible = bounds.insetBy(dx: -30, dy: -30)
        // As the haze of the way in rises, the stars and the core give way to it (so nothing clips to white, and nothing
        // white is left to turn grey as the welcome clears).
        let starLight = (0.4 + 0.6 * light) * (1 - 0.75 * frame.bloom)
        for s in galaxy.stars {
            let placed = Galaxy.place(s, at: t)
            guard placed.alpha > 0.004 else { continue }
            let p = CGPoint(x: origin.x + placed.point.x * radius, y: origin.y + placed.point.y * radius)
            guard visible.contains(p) else { continue }
            let d = s.size * starScale * (1 + placed.nearness * 0.15) * 5
            let alpha = min(1, placed.alpha * starLight) * fade
            if rushing > 0.15, s.brightness > 0.6 {
                // Moving past fast, a bright star leaves a short trail that thins to nothing behind it.
                let q = CGPoint(x: origin.x + placed.point.x * previous, y: origin.y + placed.point.y * previous)
                var trail = Path()
                trail.move(to: q)
                trail.addLine(to: p)
                var c = ctx
                c.opacity = alpha * 0.7
                c.stroke(trail, with: .linearGradient(Gradient(colors: [.clear, colour(max(2, s.tint))]), startPoint: q, endPoint: p),
                         style: StrokeStyle(lineWidth: max(0.5, d * 0.16), lineCap: .round))
            }
            for layer in layers {
                var c = ctx
                c.opacity = alpha * layer.weight
                c.draw(layer.images[s.tint], in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            }
        }

        // The centre: a warm glow that lights as the stars gather, rounder than the disc (the bulge stands up from it).
        let core = Galaxy.coreGlow(at: t) * (0.35 + 0.65 * light) * (1 + frame.pulse * 0.5) * (rushing > 0 ? 1 : fade) * (1 - 0.7 * frame.bloom)
        var bulge = ctx
        bulge.translateBy(x: origin.x, y: origin.y)
        bulge.rotate(by: .radians(Galaxy.positionAngle))
        bulge.scaleBy(x: 1, y: 0.62)
        for (tint, size, alpha) in [(3, 0.7, 0.16), (2, 0.38, 0.3), (1, 0.18, 0.55), (0, 0.07, 0.95)] {
            let r = size * radius
            var c = bulge
            // As the camera nears, the white heart gives way to the haze rather than swelling into a white-out.
            c.opacity = core * alpha * (tint == 0 ? 1 - 0.85 * frame.bloom : 1) / (1 + rushing * (tint == 0 ? 0.35 : 0.12))
            c.addFilter(.colorMultiply(colour(tint)))
            c.draw(glow, in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        }

        // A few near stars, in front of everything, that move most with the pointer.
        for star in GalaxySprites.nearStars {
            let twinkle = 0.75 + 0.25 * sin(t * star.speed + star.phase)
            let p = CGPoint(x: star.x * size.width - pointer.x * 30, y: star.y * size.height - pointer.y * 22)
            var c = ctx
            c.opacity = star.alpha * twinkle * fade
            c.draw(next[star.tint], in: CGRect(x: p.x - star.size / 2, y: p.y - star.size / 2, width: star.size, height: star.size))
        }

        // The way in: the core's light opens out into a haze of the sky's colour that fills the window (never a white-out;
        // the browser comes through it).
        if frame.bloom > 0 {
            let reach = hypot(size.width, size.height) * (0.35 + 0.9 * frame.bloom)
            for (tint, scale, alpha) in [(4, 1.0, 0.5), (3, 0.66, 0.42), (2, 0.38, 0.34)] {
                let r = reach * scale
                var c = ctx
                c.opacity = frame.bloom * alpha
                c.addFilter(.colorMultiply(colour(tint)))
                c.draw(glow, in: CGRect(x: origin.x - r, y: origin.y - r, width: 2 * r, height: 2 * r))
            }
            ctx.fill(Path(bounds), with: .color(Color(palette[3]).opacity(0.24 * frame.bloom)))
        }

        // The edges fall away into the dark.
        ctx.blendMode = .normal
        ctx.fill(Path(bounds), with: .radialGradient(
            Gradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.55 * (1 - frame.bloom)), location: 1)]),
            center: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0, endRadius: hypot(size.width, size.height) / 2))
    }
}

/// The galaxy's pictures as views draw them, with its stars in each palette made as they are first needed (a few are
/// kept, so going back and forth between skies makes nothing new).
@MainActor
final class GalaxySprites {
    let art: GalaxyArt
    let glow, gasInner, gasOuter, gasKnots, field: Image
    private var stars: [[RGBA]: [Image]] = [:]
    private var order: [[RGBA]] = []

    init(art: GalaxyArt) {
        self.art = art
        glow = Image(decorative: art.glow, scale: 1)
        gasInner = Image(decorative: art.gasInner, scale: 1)
        gasOuter = Image(decorative: art.gasOuter, scale: 1)
        gasKnots = Image(decorative: art.gasKnots, scale: 1)
        field = Image(decorative: art.field, scale: 1)
    }

    /// A star in each of the palette's colours: a white core with a halo of its colour.
    func stars(for palette: [RGBA]) -> [Image] {
        if let images = stars[palette] { return images }
        let images = palette.map { Image(decorative: GalaxyArt.star(tint: $0), scale: 1) }
        stars[palette] = images
        order.append(palette)
        if order.count > 6 { stars[order.removeFirst()] = nil }
        return images
    }

    struct Cloud { let x, y, size, alpha, phase: Double; let tint: Int }
    static let clouds: [Cloud] = [
        Cloud(x: 0.16, y: 0.20, size: 0.62, alpha: 0.12, phase: 0.0, tint: 4),
        Cloud(x: 0.88, y: 0.80, size: 0.72, alpha: 0.10, phase: 2.1, tint: 3),
        Cloud(x: 0.74, y: 0.10, size: 0.40, alpha: 0.07, phase: 4.2, tint: 6),
        Cloud(x: 0.08, y: 0.90, size: 0.48, alpha: 0.08, phase: 1.3, tint: 2),
    ]

    struct Near { let x, y, size, alpha, speed, phase: Double; let tint: Int }
    static let nearStars: [Near] = {
        var rng = SplitMix(0x5EED_57A2)
        return (0..<18).map { _ in
            Near(x: rng.unit(), y: rng.unit(), size: 4 + rng.unit() * 6, alpha: 0.25 + rng.unit() * 0.45,
                 speed: 0.5 + rng.unit() * 1.4, phase: rng.unit() * 6.3, tint: [0, 0, 6, 5, 1][Int(rng.unit() * 5) % 5])
        }
    }()
}

/// The pictures the galaxy is drawn with, baked from the pure model (`Galaxy.gas`, `Galaxy.knots`) off the main thread.
/// The welcome holds them while it is up and lets them go when it closes.
final class GalaxyArt: @unchecked Sendable {
    /// How far the gas pictures reach, in disc radii from the centre.
    static let extent = 1.2

    /// The gas seen face-on, white, its density in the alpha: the inner arms, the outer arms and the bright knots.
    let gasInner, gasOuter, gasKnots: CGImage
    /// A soft round light, white: all falloff.
    let glow: CGImage
    /// A tile of faint far stars, 2 pixels to the point.
    let field: CGImage

    private init(gasInner: CGImage, gasOuter: CGImage, gasKnots: CGImage, glow: CGImage, field: CGImage) {
        self.gasInner = gasInner; self.gasOuter = gasOuter; self.gasKnots = gasKnots; self.glow = glow; self.field = field
    }

    /// Takes a moment (a fifth of a second or so): call it off the main thread.
    static func bake() -> GalaxyArt {
        let n = 640
        var inner = [UInt8](repeating: 0, count: n * n * 4), outer = inner, knots = inner
        let scale = 2 * extent / Double(n)
        for j in 0..<n {
            let y = (Double(j) + 0.5) * scale - extent
            for i in 0..<n {
                let x = (Double(i) + 0.5) * scale - extent
                let g = Galaxy.gas(x: x, y: y)
                let k = (j * n + i) * 4
                let a = UInt8(min(255, g.inner * 255)), b = UInt8(min(255, g.outer * 255))
                inner[k] = a; inner[k + 1] = a; inner[k + 2] = a; inner[k + 3] = a
                outer[k] = b; outer[k + 1] = b; outer[k + 2] = b; outer[k + 3] = b
            }
        }
        for knot in Galaxy.knots() {
            let cx = (knot.x + extent) / scale, cy = (knot.y + extent) / scale, r = knot.size / scale * 2.2
            for j in max(0, Int(cy - r))..<min(n, Int(cy + r) + 1) {
                for i in max(0, Int(cx - r))..<min(n, Int(cx + r) + 1) {
                    let d = hypot(Double(i) - cx, Double(j) - cy) / r
                    guard d < 1 else { continue }
                    let v = knot.brightness * exp(-pow(d / 0.38, 2)) * 255
                    let k = (j * n + i) * 4
                    let a = UInt8(min(255, Double(knots[k + 3]) + v))
                    knots[k] = a; knots[k + 1] = a; knots[k + 2] = a; knots[k + 3] = a
                }
            }
        }
        return GalaxyArt(gasInner: image(inner, width: n, height: n), gasOuter: image(outer, width: n, height: n),
                         gasKnots: image(knots, width: n, height: n), glow: glowImage(), field: fieldImage())
    }

    private static func glowImage() -> CGImage {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let c = Double(n - 1) / 2
        for y in 0..<n {
            for x in 0..<n {
                let d = hypot(Double(x) - c, Double(y) - c) / c
                guard d < 1 else { continue }
                let v = UInt8(min(255, exp(-pow(d / 0.48, 2)) * (1 - d) * 255))
                let i = (y * n + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = v
            }
        }
        return image(bytes, width: n, height: n)
    }

    /// A star: a tight white core with a halo of `tint`.
    static func star(tint: RGBA) -> CGImage {
        let n = 48
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let c = Double(n - 1) / 2
        for y in 0..<n {
            for x in 0..<n {
                let d = hypot(Double(x) - c, Double(y) - c) / c
                guard d < 1 else { continue }
                let a = min(1, exp(-pow(d / 0.15, 2)) * 1.1 + 0.2 * exp(-pow(d / 0.42, 2))) * (1 - d * d)
                let white = exp(-pow(d / 0.1, 2))
                let i = (y * n + x) * 4
                bytes[i] = UInt8(min(255, (tint.r + (1 - tint.r) * white) * a * 255))
                bytes[i + 1] = UInt8(min(255, (tint.g + (1 - tint.g) * white) * a * 255))
                bytes[i + 2] = UInt8(min(255, (tint.b + (1 - tint.b) * white) * a * 255))
                bytes[i + 3] = UInt8(min(255, a * 255))
            }
        }
        return image(bytes, width: n, height: n)
    }

    /// Faint far stars, with a few brighter ones and a dusting of colour, on a tile that repeats without a seam.
    private static func fieldImage() -> CGImage {
        let n = 1400
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var rng = SplitMix(0xFA2F_1E1D)
        let tints = [RGBA(1, 1, 1), RGBA(1, 0.92, 0.85), RGBA(0.8, 0.88, 1), RGBA(0.75, 0.8, 1)]
        func plot(_ x: Int, _ y: Int, _ v: Double, _ t: RGBA) {
            let x = (x + n) % n, y = (y + n) % n
            let i = (y * n + x) * 4
            bytes[i] = UInt8(min(255, Double(bytes[i]) + t.r * v * 255))
            bytes[i + 1] = UInt8(min(255, Double(bytes[i + 1]) + t.g * v * 255))
            bytes[i + 2] = UInt8(min(255, Double(bytes[i + 2]) + t.b * v * 255))
            bytes[i + 3] = UInt8(min(255, Double(bytes[i + 3]) + v * 255))
        }
        for _ in 0..<2600 {
            let x = Int(rng.unit() * Double(n)), y = Int(rng.unit() * Double(n))
            let v = pow(rng.unit(), 3.4) * 0.8 + 0.035
            let t = tints[Int(rng.unit() * Double(tints.count)) % tints.count]
            plot(x, y, v, t)
            if v > 0.45 {   // the brightest are a little larger
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { plot(x + dx, y + dy, v * 0.3, t) }
            }
        }
        return image(bytes, width: n, height: n)
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
