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


/// Serves fixed responses by path on 127.0.0.1 and records every request line's path (query included), so a test can
/// check both what a client got and what it asked for.
final class SiteServer: @unchecked Sendable {
    struct Route {
        var type: String
        var body: Data
        /// Seconds the server waits before answering, to be in the middle of a request when something else happens.
        var delay: TimeInterval = 0
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private let listener: NWListener
    private let recorder: Recorder
    let port: UInt16
    var requests: [String] { recorder.all }

    init(routes: [String: Route]) async throws {
        let recorder = Recorder()
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let line = data.flatMap { String(decoding: $0, as: UTF8.self).components(separatedBy: "\r\n").first } ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                recorder.add(path)
                let route = routes[path.components(separatedBy: "?").first ?? path]
                let body = route?.body ?? Data()
                let head = "HTTP/1.1 \(route == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(route?.type ?? "text/plain")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                let send = { connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() }) }
                if let delay = route?.delay, delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
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
        self.recorder = recorder
    }

    deinit { listener.cancel() }
}
