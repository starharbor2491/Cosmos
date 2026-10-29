import AppKit
import CosmosCore
import CosmosEngine

/// What extensions see of Cosmos's tabs and windows (`chrome.tabs`, `chrome.windows`), for one profile: the profile's
/// tabs that have a page, in each window's space as the sidebar orders them (Favorites and pinned tabs first). The
/// extensions are told whenever that changes.
@MainActor
final class ExtensionTabs: ExtensionTabsHost {
    private weak var store: BrowserStore?
    private weak var extensions: EngineExtensions?
    private let profileID: UUID

    init(store: BrowserStore, profileID: UUID, extensions: EngineExtensions) {
        self.store = store
        self.profileID = profileID
        self.extensions = extensions
        watch()
    }

    /// Once what `extensionTabs` reads changes (a tab opened, closed, moved or came forward; a window came or went), the
    /// extensions hear of it, after the change.
    private func watch() {
        guard let store else { return }
        withObservationTracking {
            _ = extensionTabs.map(\.isActive)
            _ = store.runtimeRevision
            _ = store.activeWindow
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.extensions?.tabsDidChange()
                self?.watch()
            }
        }
    }

    var extensionTabs: [ExtensionTab] {
        guard let store else { return [] }
        let workspace = store.workspace
        var out: [ExtensionTab] = []
        for w in store.windows {
            guard let space = workspace.space(w.focusedSpaceID) else { continue }
            let current = store.currentTabItemID(in: w)
            let pinned = (workspace.favorites + workspace.pinned(in: space)).flatMap { workspace.tabs(under: $0.id) }
            let unpinned = workspace.unpinned(in: space).flatMap { workspace.tabs(under: $0.id) }
            var index = 0
            for (item, isPinned) in pinned.map({ ($0, true) }) + unpinned.map({ ($0, false) }) {
                guard let rt = store.runtime(forItem: item.id, in: w), rt.profileID == profileID, !rt.isEphemeral else { continue }
                out.append(ExtensionTab(page: rt.page, windowID: store.extensionNumber(of: w), index: index, isActive: item.id == current, isPinned: isPinned))
                index += 1
            }
        }
        return out
    }

    var extensionWindows: [ExtensionWindow] {
        guard let store else { return [] }
        return store.windows.map { w in
            ExtensionWindow(id: store.extensionNumber(of: w), isFocused: w === (store.activeWindow ?? store.windows.first), frame: .zero)
        }
    }

    func openExtensionTab(_ url: URL, windowID: Int?, active: Bool) -> EnginePage? {
        guard let store, let w = windowID.flatMap(store.window(numbered:)) ?? store.activeWindow ?? store.windows.first else { return nil }
        // In a space of the extension's profile: the window's own, or the first that is.
        let space = store.workspace.space(w.focusedSpaceID).flatMap { $0.profileID == profileID ? $0 : nil }
            ?? store.workspace.spaces.first { $0.profileID == profileID }
        guard let space, let id = store.newTab(url: url, in: w, activate: active, spaceID: space.id) else { return nil }
        return store.runtime(forItem: id, in: w)?.page
    }

    func activateExtensionTab(_ page: EnginePage) {
        guard let store, let rt = TabRuntime.owning(page), let w = window(of: rt) else { return }
        store.select(rt.itemID, in: w)
    }

    func closeExtensionTab(_ page: EnginePage) {
        guard let store, let rt = TabRuntime.owning(page) else { return }
        store.closeTab(rt.itemID, in: window(of: rt))
    }

    func openExtensionWindow(_ url: URL, popup: Bool, size: CGSize?) -> EnginePage? {
        guard let store else { return nil }
        if popup {
            let page = store.environment(forProfile: profileID).makePage()
            let s = size ?? CGSize(width: 500, height: 600)
            let request = NewPageRequest(url: url, features: ["width=\(Int(s.width))", "height=\(Int(s.height))"], fromExtension: true)
            if store.openPopup(page, profileID: profileID, request: request) {
                page.load(url)
                return page
            }
            page.close()
        }
        // Cosmos opens a window of its own only for a popup; anything else is a tab.
        return openExtensionTab(url, windowID: nil, active: true)
    }

    private func window(of runtime: TabRuntime) -> WindowState? {
        guard let store else { return nil }
        return store.window(showing: runtime.itemID)
            ?? store.windows.first { store.workspace.spaceID(of: runtime.itemID) == $0.focusedSpaceID }
            ?? store.activeWindow
    }
}

extension BrowserStore {
    /// A window's number for extensions, the same while it is open.
    func extensionNumber(of window: WindowState) -> Int {
        if let n = extensionWindowNumbers.object(forKey: window) { return n.intValue }
        nextExtensionWindowNumber += 1
        extensionWindowNumbers.setObject(NSNumber(value: nextExtensionWindowNumber), forKey: window)
        return nextExtensionWindowNumber
    }

    func window(numbered n: Int) -> WindowState? { windows.first { extensionNumber(of: $0) == n } }
}
