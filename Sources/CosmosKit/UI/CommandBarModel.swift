import AppKit
import SwiftUI
import CosmosCore

/// State and logic behind the Command Bar (⌘T / ⌘L): gathers candidates from tabs, the archive, history, top sites,
/// commands and the search engine, ranks them, and carries out the chosen one.
@MainActor
@Observable
final class CommandBarModel {
    let store: BrowserStore
    let window: WindowState
    let mode: CommandBarMode

    var text: String
    var rows: [CommandCandidate] = []
    var selected = 0
    var inlineCompletion: String?
    /// Site-search mode ("Search YouTube"), entered with Tab.
    var site: SiteSearch?
    var tabHint: SiteSearch?
    var suggestions: [String] = []
    /// False right after the user deleted text, so the field doesn't re-add the completion they just removed.
    var allowInline = true
    /// True when the field's initial contents (the current URL) should be fully selected for easy replacement.
    let selectAllInitially: Bool

    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var lastTyped = ""
    @ObservationIgnored private static let topDomains: [(name: String, domain: String)] = {
        guard let url = Bundle.module.url(forResource: "top-domains", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }()

    init(store: BrowserStore, window: WindowState, mode: CommandBarMode) {
        self.store = store
        self.window = window
        self.mode = mode
        if mode == .currentTab, let url = store.currentURL(in: window), url.scheme == "http" || url.scheme == "https" {
            text = url.absoluteString
            selectAllInitially = true
        } else {
            text = ""
            selectAllInitially = false
        }
        recompute()
    }

    // MARK: Candidates

    private func gatherCandidates(for query: String) -> [CommandCandidate] {
        var out: [CommandCandidate] = []
        let ws = store.workspace
        let now = Date()
        let recentRank = Dictionary(uniqueKeysWithValues: window.recent.prefix(30).enumerated().map { ($1, $0) })

        for space in ws.spaces {
            let sections: [[SidebarItem]] = [ws.tabs(under: space.pinnedRootID), ws.tabs(under: space.unpinnedRootID)]
            for item in sections.flatMap({ $0 }) {
                guard let tab = item.tab else { continue }
                let live = store.runtime(forItem: item.id, in: window)
                let url = live?.url ?? tab.url
                let title = store.title(forItem: item.id, in: window)
                let subtitle = URLInput.display(url) + (ws.spaces.count > 1 && space.id != window.focusedSpaceID ? "  ·  \(space.title)" : "")
                let recency = recentRank[item.id].map { 1.0 - Double($0) / 40 } ?? 0.3
                out.append(CommandCandidate(id: "tab:\(item.id)", kind: live != nil ? .openTab(item.id) : .sidebarItem(item.id), title: title,
                                            subtitle: subtitle, url: url, frecency: recency))
            }
        }
        for item in ws.favorites {
            guard let tab = item.tab else { continue }
            let url = store.runtime(forItem: item.id, in: window)?.url ?? tab.url
            out.append(CommandCandidate(id: "tab:\(item.id)", kind: .sidebarItem(item.id), title: store.title(forItem: item.id, in: window),
                                        subtitle: URLInput.display(url), url: url, frecency: 0.7))
        }

        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            for e in store.archive.entries.prefix(500) {
                guard let url = e.url else { continue }
                out.append(CommandCandidate(id: "arch:\(e.id)", kind: .archived(e.id), title: e.title, subtitle: "Archived  ·  " + URLInput.display(url), url: url, frecency: 0.2))
            }
            for h in store.history.search(q, limit: 40, now: now) {
                out.append(CommandCandidate(id: "hist:\(h.url.absoluteString)", kind: .history, title: h.title.isEmpty ? URLInput.display(h.url) : h.title,
                                            subtitle: URLInput.display(h.url), url: h.url, frecency: Frecency.score(h, now: now)))
            }
            for d in Self.topDomains {
                guard let url = URL(string: "https://\(d.domain)") else { continue }
                out.append(CommandCandidate(id: "top:\(d.domain)", kind: .topDomain, title: d.name, subtitle: d.domain, url: url, frecency: 0.35))
            }
            for c in BrowserCommand.allCases { out.append(c.candidate) }
            for s in ws.spaces where s.id != window.focusedSpaceID {
                out.append(CommandCandidate(id: "space:\(s.id)", kind: .space(s.id), title: "Go to \(s.title)", subtitle: "Space", symbol: "moon.stars", frecency: 0.8))
            }
        }
        return out
    }

    func recompute() {
        let q = text
        let cat = store.catalog
        let engine = cat.engine(store.settings.searchEngineID)

        if q.trimmingCharacters(in: .whitespaces).isEmpty && site == nil {
            // Nothing typed: recent tabs and your most-used sites.
            let recent = window.recent.compactMap { id -> CommandCandidate? in
                guard let item = store.workspace.item(id), let tab = item.tab else { return nil }
                let live = store.runtime(forItem: id, in: window)
                return CommandCandidate(id: "tab:\(id)", kind: live != nil ? .openTab(id) : .sidebarItem(id), title: store.title(forItem: id, in: window),
                                        subtitle: URLInput.display(live?.url ?? tab.url), url: live?.url ?? tab.url)
            }.prefix(6)
            let top = store.history.topSites(limit: 6).map {
                CommandCandidate(id: "hist:\($0.url.absoluteString)", kind: .history, title: $0.title.isEmpty ? URLInput.display($0.url) : $0.title,
                                 subtitle: URLInput.display($0.url), url: $0.url)
            }
            var seen = Set<String>()
            rows = (Array(recent) + top).filter { c in
                let key = c.url.map { CommandRanker.dedupeKey($0) } ?? c.id
                return seen.insert(key).inserted
            }
            inlineCompletion = nil; tabHint = nil
            selected = min(selected, max(0, rows.count - 1))
            return
        }

        if let site {
            // Site-search mode: the one row is "Search <site> for …".
            let query = q.trimmingCharacters(in: .whitespaces)
            if let url = site.searchURL(for: query), !query.isEmpty {
                rows = [CommandCandidate(id: "site:\(site.id):\(query)", kind: .siteSearch(site.id), title: "Search \(site.name) for “\(query)”", url: url, symbol: "magnifyingglass")]
            } else {
                rows = []
            }
            inlineCompletion = nil; tabHint = nil; selected = 0
            return
        }

        let ranked = CommandRanker.rank(query: q, candidates: gatherCandidates(for: q), learned: store.learned, limit: 9)
        let out = CommandComposer.compose(query: q, ranked: ranked, suggestions: store.settings.showSearchSuggestions ? suggestions : [],
                                          catalog: cat, engine: engine)
        rows = Array(out.rows.prefix(11))
        inlineCompletion = out.inlineCompletion
        tabHint = out.tabSearchSite
        selected = 0
        scheduleSuggestions(for: q, engine: engine)
    }

    /// What you type is sent to your search engine and nowhere else: no cache entry on disk, no cookies kept or sent.
    /// (`URLSession.shared` would write the request, query included, to a cache file outside the data folder.)
    static let suggestionSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private func scheduleSuggestions(for query: String, engine: SearchEngine) {
        suggestTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard store.settings.showSearchSuggestions, q.count >= 2, q != lastTyped.trimmingCharacters(in: .whitespaces) || suggestions.isEmpty else {
            if q.count < 2 { suggestions = [] }
            return
        }
        guard case .search = URLInput.resolve(q), let url = engine.suggestURL(for: q) else { suggestions = []; return }
        lastTyped = q
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            var req = URLRequest(url: url, timeoutInterval: 4)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await Self.suggestionSession.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 1,
                  let list = json[1] as? [Any] else { return }
            let strings = list.compactMap { $0 as? String }
            await MainActor.run {
                guard let self, !Task.isCancelled, self.text.trimmingCharacters(in: .whitespaces) == q else { return }
                self.suggestions = strings
                let engine = self.store.catalog.engine(self.store.settings.searchEngineID)
                let ranked = CommandRanker.rank(query: q, candidates: self.gatherCandidates(for: q), learned: self.store.learned, limit: 9)
                let out = CommandComposer.compose(query: q, ranked: ranked, suggestions: strings, catalog: self.store.catalog, engine: engine)
                let keep = self.rows.indices.contains(self.selected) ? self.rows[self.selected].id : nil
                self.rows = Array(out.rows.prefix(11))
                if let keep, let i = self.rows.firstIndex(where: { $0.id == keep }) { self.selected = i }
            }
        }
    }

    // MARK: Interaction

    func textChanged(_ new: String) {
        guard new != text else { return }
        text = new
        recompute()
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
    }

    /// Tab: enter site search for a recognised site name.
    func tab() {
        if let hint = tabHint {
            site = hint
            text = ""
            recompute()
        } else if let c = inlineCompletion {
            text = c
            recompute()
        }
    }

    func backspaceOnEmpty() -> Bool {
        if site != nil { site = nil; recompute(); return true }
        return false
    }

    func close() { window.overlay = nil }

    func activateSelected(newTabOverride: Bool = false) {
        guard rows.indices.contains(selected) else {
            // Nothing matched: treat the text as a search / URL.
            let q = text.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return }
            openText(q, newTab: newTabOverride)
            return
        }
        activate(rows[selected], newTabOverride: newTabOverride)
    }

    func activate(_ c: CommandCandidate, newTabOverride: Bool = false) {
        let query = text
        store.learned.record(query: query, candidateID: c.id)
        let effectiveMode: CommandBarMode = newTabOverride ? (mode == .newTab ? .currentTab : .newTab) : mode
        switch c.kind {
        case .openTab(let id), .sidebarItem(let id):
            store.select(id, in: window)
            if newTabOverride, mode == .currentTab, let url = c.url { _ = url }
        case .archived(let id):
            if let e = store.archive.entries.first(where: { $0.id == id }) { store.restore(e, in: window) }
        case .history, .topDomain, .suggestion, .siteSearch, .webSearch, .typedURL:
            guard let url = c.url else { return }
            let typed: Bool = { if case .typedURL = c.kind { return true }; if case .webSearch = c.kind { return true }; return false }()
            store.openFromCommandBar(url, mode: effectiveMode, typed: typed, in: window)
        case .command(let raw):
            window.overlay = nil
            if let cmd = BrowserCommand(rawValue: raw) { store.perform(cmd, in: window) }
        case .space(let id):
            window.overlay = nil
            store.switchSpace(to: id, in: window)
        case .calculation:
            store.copy(c.title)
            window.overlay = nil
            window.showToast("Copied \(c.title)", symbol: "equal.square")
        }
    }

    private func openText(_ q: String, newTab: Bool) {
        let engine = store.catalog.engine(store.settings.searchEngineID)
        let effective: CommandBarMode = newTab ? (mode == .newTab ? .currentTab : .newTab) : mode
        switch URLInput.resolve(q) {
        case .url(let u): store.openFromCommandBar(u, mode: effective, typed: true, in: window)
        case .search(let s): if let u = engine.searchURL(for: s) { store.openFromCommandBar(u, mode: effective, typed: true, in: window) }
        }
    }
}
