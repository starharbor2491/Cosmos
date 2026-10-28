import AppKit
import CosmosCore
import CosmosEngine

/// Cosmos's engine: regular Chromium, run headless underneath Cosmos's own interface. It downloads Chromium on first use
/// and keeps it up to date with Google's newest snapshot, switching to a new one only once it has started.
@MainActor
public final class ChromiumEngine: BrowserEngine {
    public let name = "Chromium"
    public private(set) var status: EngineStatus = .preparing("Getting Chromium ready", progress: nil) {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    public var onStatusChange: (() -> Void)?
    /// Chromium's own settings, as Cosmos's Settings hold them. A change applies when each profile's Chromium next starts.
    public var settings = EngineSettings()

    private let install: ChromiumInstall
    private let override: URL?
    private let offline: Bool
    let extraFlags: [String]
    private(set) public var state: ChromiumInstallState
    private var app: URL?
    private var waiting: [CheckedContinuation<URL?, Never>] = []
    private var profiles: [WeakProfile] = []
    private var updating = false
    private struct WeakProfile { weak var value: ChromiumProfile? }

    /// - Parameter supportDirectory: where Chromium is kept (`~/Library/Application Support/Cosmos/Chromium`).
    /// - Parameter application: a Chromium.app to use as it is, without downloading or updating (tests, the harness).
    /// - Parameter offline: never touch the network.
    /// - Parameter extraFlags: more of Chromium's command-line switches (tests give it a fake camera and microphone).
    public init(supportDirectory: URL, application: URL? = nil, offline: Bool = false, extraFlags: [String] = []) {
        install = ChromiumInstall(root: supportDirectory)
        override = application
        self.offline = offline
        self.extraFlags = extraFlags
        state = install.loadState()
    }

    /// The version Cosmos runs (`159.0.8129.0`), once there is one.
    public var version: String? { app.flatMap(ChromiumInstall.version(of:)) }
    /// The snapshot that runs: its folder is named after it (`<root>/<revision>/chrome-mac/Chromium.app`).
    public var revision: Int? {
        guard override == nil, let app else { return nil }
        return Int(app.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
    }

    public var versionDescription: String? {
        guard let version else { return nil }
        return revision.map { "\(version) (snapshot \($0))" } ?? version
    }
    public var lastUpdateCheck: Date? { state.lastCheck }
    public var lastUpdateError: String? { state.lastError }
    public var pendingUpdate: String? {
        guard override == nil, let current = state.current, current != revision else { return nil }
        return "snapshot \(current)"
    }
    public func checkForUpdates() async { await checkForUpdate(force: true) }

    /// Finds or fetches Chromium, then checks for a newer one at most once a day.
    public func start() {
        if let override {
            ready(override)
            return
        }
        if let current = state.current, FileManager.default.fileExists(atPath: install.app(for: current).path) {
            ready(install.app(for: current))
            Task { await checkForUpdate(force: false) }
        } else {
            Task { await checkForUpdate(force: true) }
        }
    }

    private func ready(_ app: URL) {
        self.app = app
        status = .ready(version: ChromiumInstall.version(of: app) ?? "")
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(returning: app) }
    }

    /// The Chromium to start, waiting for the first download if there is none yet. Nil if there will not be one.
    func readyApplication() async -> URL? {
        if let app { return app }
        if case .failed = status, override == nil, state.current == nil { return nil }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// "Check Now" in Settings, and the daily check.
    public func checkForUpdate(force: Bool) async {
        guard override == nil, !updating else { return }
        guard !offline else {
            if app == nil { status = .failed("Cosmos is offline and has no Chromium yet.") }
            return
        }
        guard force || ChromiumUpdatePolicy.isCheckDue(state, now: Date()) else { return }
        updating = true
        defer { updating = false }
        do {
            let latest = try await install.latestRevision()
            state.lastCheck = Date()
            state.lastError = nil
            install.save(state)
            guard ChromiumUpdatePolicy.shouldInstall(latest: latest, state: state) else { return }
            if app == nil { status = .preparing("Downloading Chromium", progress: 0) }
            let installed = try await install.install(latest) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.app == nil else { return }
                    self.status = .preparing("Downloading Chromium", progress: fraction)
                }
            }
            if app == nil { status = .preparing("Starting Chromium", progress: nil) }
            guard await Self.starts(installed) else {
                state.bad.append(latest)
                throw ChromiumInstall.InstallError.wouldNotStart
            }
            state = ChromiumUpdatePolicy.promoted(latest, in: state)
            install.save(state)
            install.removeUnused(state)
            // Open profiles keep the Chromium they started with until Cosmos restarts; a first install is used at once.
            if app == nil { ready(installed) }
        } catch {
            state.lastError = String(describing: error)
            install.save(state)
            if app == nil {
                status = .failed("Cosmos could not get Chromium: \(error). Check the connection and try again from Settings ▸ Engine.")
                let continuations = waiting
                waiting = []
                continuations.forEach { $0.resume(returning: nil) }
            }
        }
    }

    /// A profile's Chromium would not start: go back to the previous snapshot if there is one.
    func launchFailed(_ failed: URL) {
        guard override == nil, failed == app, let previous = state.previous else { return }
        state = ChromiumUpdatePolicy.rolledBack(state)
        install.save(state)
        ready(install.app(for: previous))
    }

    /// Starts the app headless once and asks it for its version.
    static func starts(_ app: URL) async -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-start-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let process = try? ChromiumProcess(executable: app.appendingPathComponent("Contents/MacOS/Chromium"),
                                                 arguments: ChromiumProcess.arguments(userDataDirectory: folder, extraFlags: []),
                                                 environment: ChromiumProcess.environment(userDataDirectory: folder)) else { return false }
        defer { process.terminate() }
        let answer = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { (try? await process.connection.send("Browser.getVersion"))?["product"] != nil }
            group.addTask { try? await Task.sleep(nanoseconds: 20_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return answer
    }

    public func makeProfile(id: UUID?, directory: URL?) -> EngineProfile {
        let profile = ChromiumProfile(engine: self, id: id, directory: directory)
        profiles.removeAll { $0.value == nil }
        profiles.append(WeakProfile(value: profile))
        return profile
    }

    public func shutdown() {
        for profile in profiles.compactMap(\.value) { profile.close() }
        profiles.removeAll()
    }
}
