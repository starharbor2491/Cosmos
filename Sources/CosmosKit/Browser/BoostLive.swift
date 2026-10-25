import AppKit
import WebKit
import CosmosCore

/// Applying Boost edits to pages that are already open, and the Zap element picker.
extension BrowserStore {
    /// Re-renders a Boost's style sheet in every open page it applies to, so edits show up while the editor is open.
    func applyBoostLive(_ boost: Boost) {
        let css = boost.isEnabled ? BoostInjector.styleSheet(for: boost) : ""
        let id = BoostInjector.jsString("cosmos-boost-\(boost.id.uuidString)")
        let literal = BoostInjector.jsString(css)
        let js = """
        (function(){ var s = document.getElementById(\(id));
          if (!s) { s = document.createElement('style'); s.id = \(id); (document.head || document.documentElement).appendChild(s); }
          s.textContent = \(literal); })();
        """
        for rt in runtimes.values {
            guard let host = rt.url?.host, boost.matches(host: host) else { continue }
            rt.evaluate(js)
        }
    }

    /// Removes a deleted Boost's style from open pages.
    func removeBoostLive(_ boost: Boost) {
        let id = BoostInjector.jsString("cosmos-boost-\(boost.id.uuidString)")
        for rt in runtimes.values {
            rt.evaluate("(function(){ var s = document.getElementById(\(id)); if (s) s.remove(); })();")
        }
    }

    /// A Boost to start from for the page in front: one per host, created on demand.
    @discardableResult
    func boostForCurrentPage(in window: WindowState) -> UUID? {
        guard let host = currentURL(in: window)?.host else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let existing = boosts.boosts.first(where: { $0.hostPatterns.contains(bare) }) { return existing.id }
        let boost = Boost(name: bare, hostPatterns: [bare])
        boosts.boosts.append(boost)
        return boost.id
    }
}

extension TabRuntime {
    /// Lets the user click an element on the page; completes with a CSS selector for it, or nil on Esc.
    func pickElement(completion: @escaping (String?) -> Void) {
        let script = """
        return await new Promise(function(resolve) {
          var box = document.createElement('div');
          box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #8b5cf6;background:rgba(139,92,246,.2);border-radius:4px;left:0;top:0;width:0;height:0;';
          document.documentElement.appendChild(box);
          var cur = null;
          function sel(el) {
            if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return '#' + CSS.escape(el.id);
            var parts = [], n = el;
            while (n && n.nodeType === 1 && n !== document.body && parts.length < 5) {
              var p = n.tagName.toLowerCase();
              if (n.id) { parts.unshift('#' + CSS.escape(n.id)); break; }
              var cls = Array.prototype.slice.call(n.classList).filter(function(c){ return !/^[0-9]|[:\\/]/.test(c); }).slice(0, 2);
              if (cls.length) p += '.' + cls.map(CSS.escape).join('.');
              var sibs = n.parentElement ? Array.prototype.filter.call(n.parentElement.children, function(x){ return x.tagName === n.tagName; }) : [];
              if (sibs.length > 1) p += ':nth-of-type(' + (sibs.indexOf(n) + 1) + ')';
              parts.unshift(p);
              n = n.parentElement;
              try { if (document.querySelectorAll(parts.join(' > ')).length === 1) break; } catch (e) {}
            }
            return parts.join(' > ');
          }
          function move(e) {
            var el = document.elementFromPoint(e.clientX, e.clientY);
            if (!el || el === box || el === document.documentElement) return;
            cur = el;
            var r = el.getBoundingClientRect();
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
          }
          function swallow(e) { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); }
          function click(e) { swallow(e); finish(cur ? sel(cur) : null); }
          function key(e) { if (e.key === 'Escape') { swallow(e); finish(null); } }
          function finish(v) {
            removeEventListener('mousemove', move, true); removeEventListener('click', click, true);
            removeEventListener('mousedown', swallow, true); removeEventListener('mouseup', swallow, true);
            removeEventListener('keydown', key, true); box.remove(); resolve(v);
          }
          addEventListener('mousemove', move, true); addEventListener('click', click, true);
          addEventListener('mousedown', swallow, true); addEventListener('mouseup', swallow, true);
          addEventListener('keydown', key, true);
        });
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
            if case .success(let value) = result { completion(value as? String) } else { completion(nil) }
        }
    }
}
