import Foundation
import CosmosCore

/// A made-up workspace for `--demo` runs and screenshots: three themed spaces with Favorites, a folder, pinned and
/// Today tabs. Only applied to an empty workspace, and `--demo` uses a throwaway data directory.
@MainActor
enum DemoSeed {
    static func populate(_ store: BrowserStore) {
        guard store.workspace.isPristine else { return }
        store.edit { ws in
            let favorites: [(String, String)] = [
                ("https://github.com", "GitHub"), ("https://mail.google.com", "Gmail"), ("https://www.youtube.com", "YouTube"),
                ("https://www.notion.so", "Notion"), ("https://www.figma.com", "Figma"), ("https://news.ycombinator.com", "Hacker News"),
            ]
            for (url, title) in favorites { _ = ws.addTab(url: URL(string: url), title: title, under: ws.favoritesRootID) }

            // Home
            let home = ws.spaces[0]
            ws.spaces[0].title = "Home"
            ws.spaces[0].theme = .nebula
            ws.spaces[0].icon = .symbol("moon.stars.fill")
            if let daily = ws.addFolder(title: "Daily", under: home.pinnedRootID) {
                _ = ws.addTab(url: URL(string: "https://lobste.rs"), title: "Lobsters", under: daily)
                _ = ws.addTab(url: URL(string: "https://www.reddit.com"), title: "Reddit", under: daily)
                _ = ws.addTab(url: URL(string: "https://www.wikipedia.org"), title: "Wikipedia", under: daily)
            }
            _ = ws.addTab(url: URL(string: "https://developer.mozilla.org"), title: "MDN Web Docs", under: home.pinnedRootID)
            _ = ws.addTab(url: URL(string: "https://www.apple.com"), title: "Apple", under: home.pinnedRootID)
            for (url, title) in [("https://example.com", "Example Domain"), ("https://www.swift.org", "Swift.org"),
                                 ("https://en.wikipedia.org/wiki/Nebula", "Nebula - Wikipedia"), ("https://www.nasa.gov", "NASA")] {
                _ = ws.addTab(url: URL(string: url), title: title, under: home.unpinnedRootID)
            }

            // Work
            let workID = ws.addSpace(title: "Work", icon: .symbol("bolt.fill"), theme: .aurora, profileID: ws.profiles[0].id)
            if let work = ws.space(workID) {
                _ = ws.addTab(url: URL(string: "https://linear.app"), title: "Linear", under: work.pinnedRootID)
                _ = ws.addTab(url: URL(string: "https://slack.com"), title: "Slack", under: work.pinnedRootID)
                _ = ws.addTab(url: URL(string: "https://docs.github.com"), title: "GitHub Docs", under: work.unpinnedRootID)
            }

            // Reading
            let readID = ws.addSpace(title: "Reading", icon: .emoji("🪐"), theme: .solstice, profileID: ws.profiles[0].id)
            if let reading = ws.space(readID) {
                _ = ws.addTab(url: URL(string: "https://www.theguardian.com"), title: "The Guardian", under: reading.pinnedRootID)
                _ = ws.addTab(url: URL(string: "https://www.quantamagazine.org"), title: "Quanta Magazine", under: reading.unpinnedRootID)
            }
        }
        store.settings.hasCompletedOnboarding = true
    }
}
