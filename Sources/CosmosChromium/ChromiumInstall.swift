import CryptoKit
import Foundation

/// Which Chromium builds are on disk and which one Cosmos runs. Saved as `state.json` next to them.
public struct ChromiumInstallState: Codable, Equatable, Sendable {
    /// The snapshot (Chromium's revision number) Cosmos starts.
    public var current: Int?
    /// The one before, kept to go back to if `current` stops starting.
    public var previous: Int?
    /// Snapshots that downloaded but would not start: never tried again.
    public var bad: [Int] = []
    public var lastCheck: Date?
    public var lastError: String?
    public init() {}
}

/// The update rules, apart from the network and the disk, so they can be tested.
public enum ChromiumUpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 3600

    public static func isCheckDue(_ state: ChromiumInstallState, now: Date) -> Bool {
        guard let last = state.lastCheck else { return true }
        return now.timeIntervalSince(last) >= checkInterval || now < last
    }

    /// Whether the newest snapshot is worth downloading.
    public static func shouldInstall(latest: Int, state: ChromiumInstallState) -> Bool {
        latest > (state.current ?? 0) && !state.bad.contains(latest)
    }

    /// A new snapshot started: it becomes the one Cosmos runs, and the old one is kept to fall back on.
    public static func promoted(_ revision: Int, in state: ChromiumInstallState) -> ChromiumInstallState {
        var next = state
        if let current = state.current, current != revision { next.previous = current }
        next.current = revision
        return next
    }

    /// The current snapshot would not start: it is marked bad and the previous one comes back.
    public static func rolledBack(_ state: ChromiumInstallState) -> ChromiumInstallState {
        var next = state
        if let current = state.current, !next.bad.contains(current) { next.bad.append(current) }
        next.current = state.previous
        next.previous = nil
        return next
    }

    /// Snapshots on disk that are neither current nor previous.
    public static func removable(installed: [Int], state: ChromiumInstallState) -> [Int] {
        installed.filter { $0 != state.current && $0 != state.previous }
    }
}

/// Downloads Chromium snapshots from Google's public `chromium-browser-snapshots` bucket, checks them, and keeps the
/// newest one that starts. Regular, unmodified Chromium: no fork, no patches.
final class ChromiumInstall: @unchecked Sendable {
    static let bucket = URL(string: "https://storage.googleapis.com/chromium-browser-snapshots/")!

    let root: URL
    private let session: URLSession
    private let stateURL: URL

    init(root: URL, session: URLSession = .shared) {
        self.root = root
        self.session = session
        stateURL = root.appendingPathComponent("state.json")
    }

    /// `Mac_Arm` on Apple silicon, `Mac` on Intel.
    static var platformFolder: String {
        #if arch(arm64)
        return "Mac_Arm"
        #else
        return "Mac"
        #endif
    }

    // MARK: State

    func loadState() -> ChromiumInstallState {
        guard let data = try? Data(contentsOf: stateURL) else { return ChromiumInstallState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ChromiumInstallState.self, from: data)) ?? ChromiumInstallState()
    }

    func save(_ state: ChromiumInstallState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    func app(for revision: Int) -> URL {
        root.appendingPathComponent("\(revision)/chrome-mac/Chromium.app", isDirectory: true)
    }

    func installedRevisions() -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(Int.init).filter { FileManager.default.fileExists(atPath: app(for: $0).path) }
    }

    func removeUnused(_ state: ChromiumInstallState) {
        for revision in ChromiumUpdatePolicy.removable(installed: installedRevisions(), state: state) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("\(revision)"))
        }
    }

    static func version(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    // MARK: Network

    func latestRevision() async throws -> Int {
        let url = Self.bucket.appendingPathComponent("\(Self.platformFolder)/LAST_CHANGE")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let revision = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InstallError.badAnswer("LAST_CHANGE")
        }
        return revision
    }

    struct Archive { let url: URL; let size: Int64; let md5: Data }

    /// Where the snapshot's zip is, how big it is and its MD5, from the bucket's own record of it.
    func archive(for revision: Int) async throws -> Archive {
        let object = "\(Self.platformFolder)/\(revision)/chrome-mac.zip"
        var components = URLComponents(string: "https://storage.googleapis.com/storage/v1/b/chromium-browser-snapshots/o/")!
        components.percentEncodedPath += object.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))!
        components.queryItems = [URLQueryItem(name: "fields", value: "size,md5Hash")]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let md5 = (info["md5Hash"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let size = (info["size"] as? String).flatMap(Int64.init) else { throw InstallError.badAnswer("snapshot \(revision)") }
        return Archive(url: Self.bucket.appendingPathComponent(object), size: size, md5: md5)
    }

    /// Downloads, checks and unpacks a snapshot. Returns the app. Nothing is left behind if any step fails.
    func install(_ revision: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let archive = try await archive(for: revision)
        let staging = root.appendingPathComponent(".incoming-\(revision)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let zip = staging.appendingPathComponent("chrome-mac.zip")
        try await download(archive, to: zip, progress: progress)
        guard try Self.md5(of: zip) == archive.md5 else { throw InstallError.corrupt }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("chrome-mac/Chromium.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Chromium").path) else { throw InstallError.corrupt }
        let destination = root.appendingPathComponent("\(revision)", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: unpacked, to: destination)
        return self.app(for: revision)
    }

    private func download(_ archive: Archive, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: archive.url) { temporary, response, error in
                // The temporary file is gone once this returns, so it is moved here.
                if let error { continuation.resume(throwing: error); return }
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: InstallError.badAnswer("download")); return
                }
                do { try FileManager.default.moveItem(at: temporary, to: file); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    static func md5(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.badAnswer("\(tool) exited with \(p.terminationStatus)") }
    }

    enum InstallError: Error, CustomStringConvertible {
        case badAnswer(String), corrupt, wouldNotStart
        var description: String {
            switch self {
            case .badAnswer(let what): return "Unexpected answer for \(what)"
            case .corrupt: return "The download was damaged"
            case .wouldNotStart: return "That Chromium would not start"
            }
        }
    }
}
