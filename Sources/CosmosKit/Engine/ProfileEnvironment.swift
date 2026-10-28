import AppKit
import CosmosCore
import CosmosEngine

/// Everything engine-side that belongs to one browsing profile: its cookie jar and site data, the scripts its pages get
/// (the page agent and Boosts) and its content blocking. A page a site or an extension opens on its own comes here first
/// and goes to the tab that opened it, or to the store.
@MainActor
final class ProfileEnvironment: EngineProfileDelegate {
    /// `nil` for the incognito environment.
    let profileID: UUID?
    let engineProfile: EngineProfile
    weak var store: BrowserStore?

    init(profileID: UUID?, engineProfile: EngineProfile, store: BrowserStore?) {
        self.profileID = profileID
        self.engineProfile = engineProfile
        self.store = store
        engineProfile.delegate = self
        installBoosts(BoostLibrary())
    }

    func makePage() -> EnginePage { engineProfile.makePage() }

    // MARK: Scripts

    static let agentSource: String = {
        guard let url = Bundle.module.url(forResource: "agent", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    /// Replaces the Boost scripts. Applies to pages loaded from now on; the caller refreshes open tabs.
    func installBoosts(_ library: BoostLibrary) {
        var scripts = [PageScript(source: Self.agentSource, world: .agent, time: .documentStart)]
        for boost in library.boosts where boost.isEnabled && (boost.profileID == nil || boost.profileID == profileID) {
            scripts += BoostInjector.scripts(for: boost)
        }
        engineProfile.setPageScripts(scripts)
    }

    // MARK: EngineProfileDelegate

    func profile(_ profile: EngineProfile, didOpen page: EnginePage, opener: EnginePage?, request: NewPageRequest) -> Bool {
        if let opener, let tab = TabRuntime.owning(opener) { return tab.opened(page, request: request) }
        return store?.openedByExtension(page, request: request, profileID: profileID) ?? false
    }

    func profile(_ profile: EngineProfile, didStartDownload download: EngineDownload) {
        store?.downloads.began(download)
    }

    func profileDidRestart(_ profile: EngineProfile) {
        store?.engineRestarted(profileID: profileID)
    }
}

/// Turns a Boost into page scripts: one guarded style injection and one guarded script.
enum BoostInjector {
    static func scripts(for boost: Boost) -> [PageScript] {
        var out: [PageScript] = []
        let patterns = (try? String(data: JSONEncoder().encode(boost.hostPatterns), encoding: .utf8)) ?? "[]"
        let guardJS = """
        var __h = location.hostname.toLowerCase(), __ps = \(patterns);
        function __m(p){ p = p.toLowerCase().trim(); if (p === '*') return true; var i = p.indexOf('://'); if (i >= 0) p = p.slice(i+3); i = p.indexOf('/'); if (i >= 0) p = p.slice(0,i);
          if (p.indexOf('*.') === 0) return __h.endsWith(p.slice(1)); if (p.indexOf('www.') === 0) p = p.slice(4); return __h === p || __h.endsWith('.' + p); }
        if (!__ps.some(__m)) return;
        """
        let css = styleSheet(for: boost)
        if !css.isEmpty {
            let cssLiteral = jsString(css)
            let id = jsString("cosmos-boost-\(boost.id.uuidString)")
            // At document start there may be no root element yet to put the style in: it goes in as soon as there is.
            let src = """
            (function(){ \(guardJS)
              var s = document.getElementById(\(id)); if (!s) { s = document.createElement('style'); s.id = \(id); }
              s.textContent = \(cssLiteral);
              var add = function () { (document.head || document.documentElement).appendChild(s); };
              if (document.documentElement) { add(); return; }
              new MutationObserver(function (_, o) { if (document.documentElement) { o.disconnect(); add(); } }).observe(document, { childList: true }); })();
            """
            out.append(PageScript(source: src, world: .page, time: .documentStart))
        }
        if !boost.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let src = "(function(){ \(guardJS) try { \n\(boost.js)\n } catch (e) { console.error(\(jsString("[Cosmos Boost \(boost.name)]")), e); } })();"
            out.append(PageScript(source: src, world: .page, time: .documentEnd))
        }
        return out
    }

    static func styleSheet(for boost: Boost) -> String {
        var rules: [String] = []
        if let f = boost.colorFilter, !f.isIdentity {
            rules.append("html { filter: \(f.cssFilter) !important; }")
            if f.invert { rules.append("img, picture, video, canvas, svg image, [style*='background-image'] { filter: invert(1) hue-rotate(180deg) !important; }") }
        }
        if let font = boost.fontFamily?.trimmingCharacters(in: .whitespaces), !font.isEmpty {
            let safe = font.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ";", with: "")
            rules.append("body, body *:not(code):not(pre):not(kbd):not(samp):not([class*='icon' i]):not([class*='fa-' i]) { font-family: \"\(safe)\", system-ui, sans-serif !important; }")
        }
        let zaps = boost.zapSelectors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !zaps.isEmpty { rules.append(zaps.joined(separator: ",\n") + " { display: none !important; }") }
        if !boost.css.isEmpty { rules.append(boost.css) }
        return rules.joined(separator: "\n")
    }

    static func jsString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
