import AppKit
import CosmosCore

extension BrowserStore {
    /// Turns a throwaway page (a Probe, a Peek) into a real tab at the top of Today, keeping its state.
    @discardableResult
    func adopt(runtime rt: TabRuntime, in window: WindowState) -> UUID? {
        guard let space = workspace.space(window.focusedSpaceID),
              let id = edit({ $0.addTab(url: rt.url, title: rt.title, under: space.unpinnedRootID, at: 0) }) else { return nil }
        rt.isEphemeral = false
        rt.adopt(itemID: id)
        runtimes[RuntimeKey(item: id, profile: profileID(forItem: id, in: window))] = rt
        runtimeRevision += 1
        select(id, in: window)
        return id
    }
}
