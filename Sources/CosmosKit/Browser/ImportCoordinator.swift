import AppKit
import CosmosCore

/// One place a user can bring their browsing life from. The Welcome screen lists these.
struct ImportSource: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let detail: String
    /// Whether the source's data was found on this Mac.
    var isAvailable: Bool
    let run: @MainActor (BrowserStore, WindowState) async throws -> ImportOutcome
}

struct ImportOutcome {
    var summary: String
    var spacesAdded = 0
    var tabsAdded = 0
}

/// Collects the importers. The Arc importer and the other-browser importers register themselves here.
@MainActor
enum ImportCoordinator {
    static func sources(for store: BrowserStore) -> [ImportSource] {
        []
    }
}
