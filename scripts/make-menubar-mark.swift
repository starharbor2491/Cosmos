// Makes the menu-bar mark from the glyph's geometry (cosmos icon/logos/single-color/cosmos-menubar-glyph.svg): a
// crescent, the circle of radius 350 around (526, 512) less the circle of radius 278.5 around (606, 512), on a 1024
// canvas, cut by thin gaps. Drawn black on clear at 18, 36 and 54 px, as template images, with the gaps set on the pixel
// grid (see below).
//
//   swift scripts/make-menubar-mark.swift Sources/CosmosKit/Resources
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-menubar-mark.swift <folder>\n".utf8))
    exit(1)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

for pixels in [18, 36, 54] {
    let s = Double(pixels) / 1024
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    // The gaps fall on whole pixels, one pixel high, every third row, with a bar across the middle as in the glyph: at
    // menu-bar sizes the glyph's own thin gaps would land between pixels and turn grey. Centred so, the top and bottom
    // bars come out whole rather than as slivers. At 18 px there is no room for any, so the crescent is solid there.
    if pixels >= 36 {
        let clip = CGMutablePath()
        clip.addRect(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let pitch = 3, middle = pixels / 2
        var row = (middle - 2) % pitch
        while row < pixels {
            if row >= 0 { clip.addRect(CGRect(x: 0, y: row, width: pixels, height: 1)) }
            row += pitch
        }
        ctx.addPath(clip)
        ctx.clip(using: .evenOdd)
    }
    // The crescent as one outline, filled once (taking one anti-aliased disc out of another leaves a faint ring where
    // their edges share a pixel): from the upper tip round the outer circle's left to the lower tip, and back round the
    // inner circle's.
    func point(_ cx: Double, _ cy: Double, _ r: Double, _ a: Double) -> CGPoint {
        CGPoint(x: (cx + r * cos(a)) * s, y: Double(pixels) - (cy + r * sin(a)) * s)
    }
    let tipY = 139.8, outer = (526.0, 350.0), inner = (606.0, 278.5)
    let outerTip = asin(tipY / outer.1), innerTip = asin(tipY / inner.1)
    let path = CGMutablePath()
    for i in 0...360 {
        // Outer: from the upper tip (angle -outerTip, y down) the long way round, through the left, to the lower tip.
        let a = -outerTip - (2 * .pi - 2 * outerTip) * Double(i) / 360
        let q = point(outer.0, 512, outer.1, a)
        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    for i in 0...360 {
        // Inner: from the lower tip back the long way round to the upper tip.
        let a = innerTip + (2 * .pi - 2 * innerTip) * Double(i) / 360
        path.addLine(to: point(inner.0, 512, inner.1, a))
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    NSGraphicsContext.current = nil
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: folder.appendingPathComponent("MenuBarMark-\(pixels).png"))
}
