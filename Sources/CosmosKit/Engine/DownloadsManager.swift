import AppKit
import CosmosEngine

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

    @ObservationIgnored fileprivate var download: EngineDownload?

    init(download: EngineDownload) {
        self.download = download
        sourceURL = download.url
        filename = DownloadsManager.safeFilename(download.suggestedFilename)
    }

    public func cancel() {
        download?.cancel()
        download = nil
        state = .cancelled
    }

    public func reveal() { if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) } }
    public func open() { if let destination { NSWorkspace.shared.open(destination) } }

    fileprivate func progressed(_ d: EngineDownload) { fraction = d.fraction; bytes = d.receivedBytes }
    fileprivate func finish(at url: URL) { destination = url; filename = url.lastPathComponent; state = .finished; fraction = 1; download = nil }
    fileprivate func fail(_ message: String) { state = .failed(message); download = nil }

    public var isRunning: Bool { if case .running = state { return true } else { return false } }
}

/// Downloads go straight to ~/Downloads (renamed on collision), like Arc, and show up in the Library.
@MainActor
@Observable
public final class DownloadsManager {
    public private(set) var items: [DownloadItem] = []
    /// Called when something starts or finishes, for toasts.
    @ObservationIgnored public var onEvent: ((DownloadItem) -> Void)?
    @ObservationIgnored public var directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    public init() {}

    public var hasActive: Bool { items.contains { $0.isRunning } }
    public var overallFraction: Double {
        let running = items.filter(\.isRunning)
        guard !running.isEmpty else { return 1 }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    /// The engine started a download. It writes the file where it keeps its own; once it is complete, it moves here.
    func began(_ download: EngineDownload) {
        let item = DownloadItem(download: download)
        download.onChange = { [weak self, weak item] d in
            guard let self, let item else { return }
            switch d.state {
            case .running: item.progressed(d)
            case .finished(let staged): self.finish(item, staged: staged)
            case .failed(let message): item.fail(message); self.onEvent?(item)
            case .cancelled: if item.isRunning { item.fail("Cancelled") }
            }
        }
        items.insert(item, at: 0)
        onEvent?(item)
    }

    private func finish(_ item: DownloadItem, staged: URL) {
        let destination = uniqueURL(for: item.filename)
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            item.fail(error.localizedDescription)
            onEvent?(item)
            return
        }
        Self.quarantine(destination, from: item.sourceURL)
        item.finish(at: destination)
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.apple.DownloadFileFinished"), object: destination.path)
        onEvent?(item)
    }

    /// Removes the downloads in `shown` that are over: Clear takes what the list shows, nothing it hides.
    public func clear(_ shown: [DownloadItem]) {
        let gone = Set(shown.filter { !$0.isRunning }.map(\.id))
        items.removeAll { gone.contains($0.id) }
    }

    /// Marks a file as downloaded from the web, so macOS checks it before it first opens, unless the engine already did.
    static func quarantine(_ file: URL, from source: URL?) {
        var url = file
        guard (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties == nil else { return }
        var properties: [String: Any] = [kLSQuarantineAgentNameKey as String: "Cosmos", kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let source, ["http", "https"].contains(source.scheme ?? "") { properties[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try? url.setResourceValues(values)
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
