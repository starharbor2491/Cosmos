import Foundation
import Network
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

@MainActor
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    var settings: Settings?
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if let settings, let url = navigationAction.request.url { ContentBlockerController.configure(preferences, for: url, settings: settings) }
        decisionHandler(.allow, preferences)
    }
    func load(_ url: URL, in web: WKWebView) async {
        web.navigationDelegate = self
        await withCheckedContinuation { c in
            continuation = c
            web.load(URLRequest(url: url))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(); continuation = nil }
}

/// Serves one fixed HTML page on 127.0.0.1 so a real http:// document can be loaded.
final class PageServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(html: String) async throws {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed { resumed = true; c.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if !resumed { resumed = true; c.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: .global())
        }
        listener = l
    }

    deinit { listener.cancel() }
}

