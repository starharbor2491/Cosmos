import AppKit
import WebKit

/// One file coming down (or already down).
@MainActor
@Observable
public final class DownloadItem: Identifiable {
    public enum State { case running, finished, failed(String), cancelled }

    public let id = UUID()
    public let sourceURL: URL?
    public private(set) var filename: String
    public private(set) var destination: URL?
    public private(set) var state: State = .running
    public private(set) var fraction: Double = 0
    public private(set) var bytes: Int64 = 0
    public let startedAt = Date()

    @ObservationIgnored fileprivate var download: WKDownload?
    @ObservationIgnored fileprivate var progressObservation: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        sourceURL = download.originalRequest?.url
        filename = sourceURL?.lastPathComponent.nonEmptyOr("Download") ?? "Download"
        progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            MainActor.assumeIsolated { self?.fraction = p.fractionCompleted; self?.bytes = p.completedUnitCount }
        }
    }

    public func cancel() {
        download?.cancel { _ in }
        state = .cancelled
    }

    public func reveal() { if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) } }
    public func open() { if let destination { NSWorkspace.shared.open(destination) } }

    fileprivate func set(filename: String, destination: URL) { self.filename = filename; self.destination = destination }
    fileprivate func finish() { state = .finished; fraction = 1; progressObservation = nil; download = nil }
    fileprivate func fail(_ message: String) { state = .failed(message); progressObservation = nil; download = nil }

    public var isRunning: Bool { if case .running = state { return true } else { return false } }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// Downloads go straight to ~/Downloads (renamed on collision), like Arc, and show up in the sidebar's tray.
@MainActor
@Observable
public final class DownloadsManager: NSObject, WKDownloadDelegate {
    public private(set) var items: [DownloadItem] = []
    /// Called when something starts or finishes, for toasts.
    @ObservationIgnored public var onEvent: ((DownloadItem) -> Void)?
    @ObservationIgnored private var byDownload: [ObjectIdentifier: DownloadItem] = [:]
    @ObservationIgnored public var directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    public var hasActive: Bool { items.contains { $0.isRunning } }
    public var overallFraction: Double {
        let running = items.filter(\.isRunning)
        guard !running.isEmpty else { return 1 }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    func began(_ download: WKDownload, from webView: WKWebView?) {
        let item = DownloadItem(download: download)
        byDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        onEvent?(item)
    }

    public func clearFinished() { items.removeAll { !$0.isRunning } }

    // MARK: WKDownloadDelegate

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                         completionHandler: @escaping @MainActor (URL?) -> Void) {
        let url = uniqueURL(for: Self.safeFilename(suggestedFilename))
        byDownload[ObjectIdentifier(download)]?.set(filename: url.lastPathComponent, destination: url)
        completionHandler(url)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.finish()
        if let dest = item.destination {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.apple.DownloadFileFinished"), object: dest.path)
        }
        onEvent?(item)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.fail(error.localizedDescription)
        onEvent?(item)
    }

    /// The name a server suggests is its opinion, not ours: it never gets to choose a folder.
    nonisolated static func safeFilename(_ suggested: String) -> String {
        let name = (suggested.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }

    private func uniqueURL(for name: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return candidate
    }
}
