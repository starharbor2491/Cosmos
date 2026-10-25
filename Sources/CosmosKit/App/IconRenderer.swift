import AppKit
import SwiftUI

/// Renders the app icon (`Cosmos --render-icon icon.png`); scripts/build-app.sh turns the PNG into an .icns.
struct AppIconArtwork: View {
    var body: some View {
        ZStack {
            Color.clear
            ZStack {
                RoundedRectangle(cornerRadius: 184, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.05, blue: 0.22), Color(red: 0.30, green: 0.12, blue: 0.48), Color(red: 0.80, green: 0.30, blue: 0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Canvas { ctx, size in
                    var rng = SystemRandomNumberGenerator()
                    var seed: UInt64 = 0xC05305
                    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
                    _ = rng.next()
                    for _ in 0..<70 {
                        let x = next() * size.width, y = next() * size.height, r = 1.5 + next() * 4
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.25 + next() * 0.6)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 184, style: .continuous))
                CosmosLogo(size: 600)
                RoundedRectangle(cornerRadius: 184, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 3)
            }
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func renderAppIcon(to path: String) -> Bool {
    let renderer = ImageRenderer(content: AppIconArtwork())
    renderer.scale = 1
    renderer.isOpaque = false
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}
