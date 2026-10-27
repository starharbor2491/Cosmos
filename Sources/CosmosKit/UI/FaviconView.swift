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
        .animation(Motion.standard, value: store.favicons.has(host: host ?? ""))
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

/// The loading indicator: a faint ring with a bright arc that trails off behind its head, turning. Every spinner in the
/// interface is this one. It turns under Reduce Motion too, only slower: a spinner that stands still reads as stuck.
struct OrbitSpinner: View {
    var size: CGFloat = 14
    var color: Color = .white

    var body: some View {
        let width = max(1.5, size * 0.13)
        let period = Motion.reduced ? 2.4 : 0.85
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: width)
                // The line's round ends reach a little past the arc, so the gradient is clear where the tail's end wraps round to.
                Circle().trim(from: 0, to: 0.7)
                    .stroke(AngularGradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: 0.7), .init(color: color, location: 0.73),
                                                .init(color: color.opacity(0), location: 0.74)], center: .center),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .padding(width / 2)
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}
