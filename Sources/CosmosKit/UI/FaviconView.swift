import SwiftUI
import AppKit
import CosmosCore

/// A site icon, or a coloured letter tile while there is no icon yet.
struct FaviconView: View {
    let store: BrowserStore
    let url: URL?
    var size: CGFloat = 18
    var cornerRadius: CGFloat = 4.5

    var body: some View {
        let host = url?.host
        Group {
            if let image = store.favicons.image(forHost: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                LetterTile(host: host, url: url, size: size, cornerRadius: cornerRadius)
            }
        }
        .frame(width: size, height: size)
    }
}

struct LetterTile: View {
    let host: String?
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let color = Color(nsColor: FaviconStore.tileColor(for: host))
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if url?.scheme == "file" {
                Image(systemName: "doc.fill").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.9))
            } else if let letter = Self.letter(host) {
                Text(letter).font(.system(size: size * 0.56, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
            } else {
                Image(systemName: "sparkle").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    static func letter(_ host: String?) -> String? {
        guard var h = host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        guard let c = h.first, c.isLetter || c.isNumber else { return nil }
        return String(c).uppercased()
    }
}

/// A small orbiting-dot loading indicator (the planet-and-moon spinner used in tab rows).
struct OrbitSpinner: View {
    var size: CGFloat = 14
    var color: Color = .white

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 2 * .pi
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 1.2)
                Circle().fill(color).frame(width: size * 0.26, height: size * 0.26)
                    .offset(x: cos(angle) * size / 2, y: sin(angle) * size / 2)
            }
            .frame(width: size - 2, height: size - 2)
            .frame(width: size, height: size)
        }
    }
}
