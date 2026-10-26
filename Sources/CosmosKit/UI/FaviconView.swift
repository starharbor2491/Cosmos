import SwiftUI
import AppKit
import CosmosCore

/// A site's logo. While there is none (not fetched yet, or the site has no icon) it shows a quiet glyph on a tinted
/// tile, never a letter, and the logo fades in when it arrives. With `fetch` the view also asks for the logo, which
/// is what a sleeping or restored tab needs; lists of search results leave it off so typing never contacts a site.
struct FaviconView: View {
    let store: BrowserStore
    let url: URL?
    var size: CGFloat = Metrics.Icon.row
    var cornerRadius: CGFloat?
    var fetch = false

    var body: some View {
        let host = url?.host
        let radius = cornerRadius ?? Metrics.Radius.icon(size)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image = store.favicons.image(forHost: host) {
                let backing = store.favicons.backing(forHost: host)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(backing == .plain ? 0 : size * 0.12)
                    .frame(width: size, height: size)
                    .background(backing.fill, in: shape)
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                SiteGlyphTile(host: host, url: url, size: size, cornerRadius: radius)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: store.favicons.has(host: host ?? ""))
        .task(id: fetch ? (host ?? "") : "") {
            if fetch { store.favicons.ensure(url: url) }
        }
    }
}

private extension FaviconStore.Backing {
    var fill: Color {
        switch self {
        case .plain: .clear
        case .light: Color.white.opacity(0.92)
        case .dark: Color.black.opacity(0.62)
        }
    }
}

/// What stands in for a logo: a document for local files, a globe for sites, a sparkle for a blank tab.
struct SiteGlyphTile: View {
    let host: String?
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let color = Color(nsColor: FaviconStore.tileColor(for: host))
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: Self.symbol(for: url))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    static func symbol(for url: URL?) -> String {
        if url?.scheme == "file" { return "doc.fill" }
        if let host = url?.host, !host.isEmpty { return "globe" }
        return "sparkle"
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
