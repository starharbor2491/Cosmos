import AppKit
import CosmosCEF
import CosmosCore
import CosmosEngine

/// Cosmos's engine: Chromium's stable release, built into Cosmos through CEF and drawn in Cosmos's own windows. A newer
/// Chromium comes with a newer Cosmos.
@MainActor
public final class ChromiumEngine: BrowserEngine {
    public let name = "Chromium"
    public private(set) var status: EngineStatus = .preparing("Starting Chromium", progress: nil) {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    public var onStatusChange: (() -> Void)?
    /// Chromium's own settings, as Cosmos's Settings hold them. Set them before `start`: the ones Chromium only reads as
    /// it starts apply from the next launch, a profile's when it next opens.
    public var settings = EngineSettings()
    private var profiles: [WeakProfile] = []
    private struct WeakProfile { weak var value: ChromiumProfile? }

    public init() {}

    /// Sets this process up for Chromium, first thing in `main`: the descriptors of Chromium's DevTools pipe, the
    /// framework (loading it swaps the process's memory allocator for Chromium's, which must happen while no other thread
    /// runs), and the application class CEF needs. Returns the application.
    public static func prepareApplication() -> NSApplication {
        CosmosCEFReservePipe()
        if let frameworks = Bundle.main.privateFrameworksURL {
            let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
            if FileManager.default.fileExists(atPath: framework.path) { CosmosCEFRuntime.loadFramework(framework.path) }
        }
        return CosmosApplication.shared
    }

    /// True while Chromium does its work on the main thread (`CosmosCEFRuntime.isDoingWork`).
    public static var isDoingWork: Bool { CosmosCEFRuntime.isDoingWork }

    /// Where Chromium keeps its data: every profile's folder is inside `root`. The profile `defaultProfileID`, whose
    /// folder is `defaultProfile`, is the one Chromium starts with and the one extensions run in. False when this Cosmos
    /// has no Chromium in it.
    @discardableResult
    public static func configure(root: URL, defaultProfileID: UUID, defaultProfile: URL, switches: [String] = []) -> Bool {
        guard let configuration = ChromiumRuntime.Configuration.app(root: root, defaultProfileID: defaultProfileID, defaultProfile: defaultProfile,
                                                                    switches: switches)
        else { return false }
        ChromiumRuntime.configuration = configuration
        return true
    }

    /// The version Cosmos runs (`156.0.8078.48`).
    public var versionDescription: String? { status.isReady ? ChromiumRuntime.shared.chromiumVersion : nil }

    /// Starts Chromium inside Cosmos.
    public func start() {
        Task {
            let runtime = ChromiumRuntime.shared
            status = await runtime.start(settings: settings)
                ? .ready(version: runtime.chromiumVersion)
                : .failed("Chromium did not start: \(runtime.failure ?? "unknown reason").")
        }
    }

    public func makeProfile(id: UUID?, directory: URL?) -> EngineProfile {
        let profile = ChromiumProfile(engine: self, id: id, directory: directory)
        profiles.removeAll { $0.value == nil }
        profiles.append(WeakProfile(value: profile))
        return profile
    }

    public func shutdown(then done: @escaping () -> Void) {
        closeProfiles()
        // Chromium stops once its pages have closed, writing out cookies and settings it was keeping for later.
        CosmosCEFRuntime.shutdown { _ in done() }
    }

    /// Closes every profile and leaves Chromium running (a test's end; Chromium starts only once in a process).
    func closeProfiles() {
        for profile in profiles.compactMap(\.value) { profile.close() }
        profiles.removeAll()
    }
}
