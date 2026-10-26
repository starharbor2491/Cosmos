// Makes the app icon from the galaxy artwork: the square art cut to a macOS icon tile (824 pt on a 1024 pt canvas, so
// the Dock and Finder have room for their shadow), with a soft shadow and a hairline edge.
//
//   swift scripts/make-app-icon.swift "cosmos icon/logos/app-icon/cosmos-app-icon-1024.png" "cosmos icon/cosmos-app-icon-tile.png"
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let art = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-app-icon.swift <artwork.png> <tile.png>\n".utf8))
    exit(1)
}

let canvas = 1024.0
let tile = 824.0
let rect = CGRect(x: (canvas - tile) / 2, y: (canvas - tile) / 2, width: tile, height: tile)

/// Apple's icon shape is a superellipse rather than a rounded rectangle: its corners curve in gradually.
func tilePath(in rect: CGRect) -> CGPath {
    let exponent = 4.2
    let path = CGMutablePath()
    for step in 0...720 {
        let angle = Double(step) / 720 * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let point = CGPoint(x: rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
                            y: rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.interpolationQuality = .high

let path = tilePath(in: rect)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.4))
context.addPath(path)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(path)
context.clip()
art.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
context.restoreGState()

// A fine light edge, so a dark tile still reads against a dark Dock.
context.addPath(tilePath(in: rect.insetBy(dx: 1, dy: 1)))
context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
context.setLineWidth(2)
context.strokePath()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: arguments[2])) } catch {
    FileHandle.standardError.write(Data("could not write \(arguments[2]): \(error)\n".utf8))
    exit(1)
}
