import AppKit
import WebKit
import CosmosCore

/// Everything WebKit-side that belongs to one browsing profile: its cookie jar / site data, the user scripts shared
/// by its tabs (the page agent and Boosts) and its content-blocking rules.
///
/// One `WKUserContentController` per profile (not per tab) keeps tab creation cheap and makes `window.open`
/// popups, which WebKit configures from the opener, behave: the shared agent routes messages to the right tab by
/// `message.webView`.
@MainActor
final class ProfileEnvironment {
    /// `nil` for the ephemeral incognito environment.
    let profileID: UUID?
    let dataStore: WKWebsiteDataStore
    let contentController = WKUserContentController()
    private let router = AgentMessageRouter()
    private(set) var ruleLists: [WKContentRuleList] = []
    /// The `WKWebExtensionController` (macOS 15.4+) web views of this profile are configured with, when extensions are on.
    var extensionController: AnyObject?

    init(profile: Profile?, isDefault: Bool) {
        profileID = profile?.id
        if let profile {
            dataStore = isDefault ? .default() : WKWebsiteDataStore(forIdentifier: profile.id)
        } else {
            dataStore = .nonPersistent()
        }
        contentController.add(router, contentWorld: .defaultClient, name: "cosmos")
        installAgent()
    }

    static let userAgentSuffix: String = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "Version/\(min(major, 26)).0 Safari/605.1.15"
    }()

    func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.userContentController = contentController
        c.applicationNameForUserAgent = Self.userAgentSuffix
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isTextInteractionEnabled = true
        c.upgradeKnownHostsToHTTPS = true
        c.allowsAirPlayForMediaPlayback = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController {
            c.webExtensionController = controller
        }
        return c
    }

    // MARK: Scripts

    private static let agentSource: String = {
        guard let url = Bundle.module.url(forResource: "agent", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    private var boostScripts: [WKUserScript] = []

    private func installAgent() {
        contentController.addUserScript(WKUserScript(source: Self.agentSource, injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: false, in: .defaultClient))
    }

    /// Replaces the Boost scripts. Applies to pages loaded from now on; the caller refreshes open tabs.
    func installBoosts(_ library: BoostLibrary) {
        contentController.removeAllUserScripts()
        installAgent()
        for boost in library.boosts where boost.isEnabled && (boost.profileID == nil || boost.profileID == profileID) {
            for script in BoostInjector.scripts(for: boost) { contentController.addUserScript(script) }
        }
    }

    // MARK: Content blocking

    func setRuleLists(_ lists: [WKContentRuleList]) {
        for old in ruleLists { contentController.remove(old) }
        ruleLists = lists
        for l in lists { contentController.add(l) }
    }
}

/// Receives `window.webkit.messageHandlers.cosmos.postMessage(...)` from the page agent and hands the message to
/// the tab that owns the web view.
final class AgentMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web = message.webView as? CosmosWebView, let body = message.body as? [String: Any] else { return }
        let isMainFrame = message.frameInfo.isMainFrame
        MainActor.assumeIsolated {
            web.runtime?.handleAgentMessage(body, fromMainFrame: isMainFrame)
        }
    }
}

/// Turns a Boost into user scripts: one guarded style injection and one guarded script.
enum BoostInjector {
    static func scripts(for boost: Boost) -> [WKUserScript] {
        var out: [WKUserScript] = []
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
            let src = """
            (function(){ \(guardJS)
              var s = document.getElementById(\(id)); if (!s) { s = document.createElement('style'); s.id = \(id); }
              s.textContent = \(cssLiteral); (document.head || document.documentElement).appendChild(s); })();
            """
            out.append(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if !boost.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let src = "(function(){ \(guardJS) try { \n\(boost.js)\n } catch (e) { console.error(\(jsString("[Cosmos Boost \(boost.name)]")), e); } })();"
            out.append(WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page))
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
