import SwiftUI
import AppKit
import CosmosCore

// MARK: - Site controls

/// The Site Control Center: what Cosmos is doing on the page you're looking at (blocking, zoom, Boosts, permissions).
struct SiteControlsPanel: View {
    let store: BrowserStore
    let window: WindowState
    /// In the utilities' panel beside the page: the controls alone, without the floating panel around them.
    var embedded = false
    @Environment(\.palette) private var palette

    var body: some View {
        if embedded {
            controls
        } else {
            controls
                .frame(width: 340)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous))
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).fill(palette.panel))
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
                .shadow(color: palette.shadow, radius: 28, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, window.sidebarVisible ? Metrics.Sidebar.gutter : 90)
                .padding(.top, window.sidebarVisible ? Metrics.Height.toolbar + Metrics.Height.field + Metrics.Space.xs : 52)
        }
    }

    @ViewBuilder private var controls: some View {
        let rt = store.currentRuntime(in: window)
        let url = store.currentURL(in: window)
        let host = url?.host ?? ""
        let blocked = store.settings.adBlockingEnabled && !(url.map { ContentBlockerController.isAllowlisted($0, allowlist: store.settings.adBlockAllowlist) } ?? false)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FaviconView(store: store, url: url, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.isEmpty ? "No page" : host).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.text)
                    // Nothing to say about the connection of a page that isn't on the web, so no empty line either.
                    switch URLInput.connection(of: url) {
                    case .secure: Text("Connection is secure").font(.system(size: 11.5)).foregroundStyle(palette.secondary)
                    case .notSecure: Text("Connection is not secure").font(.system(size: 11.5)).foregroundStyle(palette.warning)
                    case .none: EmptyView()
                    }
                }
                Spacer()
            }
            .padding(14)
            Rectangle().fill(palette.stroke).frame(height: 0.5)

            VStack(spacing: 2) {
                if !host.isEmpty {
                    ControlRow(symbol: "shield.lefthalf.filled", title: "Ad & tracker blocking", detail: store.settings.adBlockingEnabled ? (blocked ? "On for this site" : "Off for this site") : "Off everywhere") {
                        SwitchControl(isOn: Binding(get: { blocked }, set: { on in
                            if let url { store.settings.adBlockAllowlist = ContentBlockerController.allowlist(store.settings.adBlockAllowlist, blocking: on, for: url) }
                            rt?.reload()
                        }), label: "Ad and tracker blocking on this site")
                        .opacity(store.settings.adBlockingEnabled ? 1 : 0.4)
                        .disabled(!store.settings.adBlockingEnabled)
                    }
                    ControlRow(symbol: "chart.pie", title: "Radial menu", detail: radialDetail(host)) {
                        SwitchControl(isOn: Binding(get: { !store.settings.radialMenu.isDisabled(host: host) }, set: { on in
                            if on { store.settings.radialMenu.enable(host: host) } else { store.settings.radialMenu.disable(host: host) }
                        }), label: "Radial menu on this site")
                        .opacity(store.settings.radialMenu.enabled ? 1 : 0.4)
                        .disabled(!store.settings.radialMenu.enabled)
                    }
                    ControlRow(symbol: "plus.magnifyingglass", title: "Page zoom", detail: "\(Int(((rt?.zoom ?? 1) * 100).rounded()))%") {
                        HStack(spacing: 2) {
                            ToolbarButton(symbol: "minus", size: 12, help: "Zoom Out") { rt?.zoomOut() }
                            ToolbarButton(symbol: "plus", size: 12, help: "Zoom In") { rt?.zoomIn() }
                            ToolbarButton(symbol: "arrow.counterclockwise", size: 12, help: "Actual Size") { rt?.resetZoom() }
                        }
                    }
                    if store.settings.isOn(.boosts) {
                        ControlRow(symbol: "wand.and.stars", title: "Boost this site", detail: store.boostForCurrentPageIfExists(in: window) == nil ? "Recolour, change fonts, hide things" : "You have a Boost here") {
                            ActionButton(title: "Open", kind: .quiet) { window.overlay = .boosts }.padding(.trailing, -Metrics.Space.s)
                        }
                    }
                    if let rt, rt.isAudible || rt.isMuted {
                        ControlRow(symbol: rt.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: "Sound", detail: rt.isMuted ? "Muted" : "Playing") {
                            ActionButton(title: rt.isMuted ? "Unmute" : "Mute", kind: .quiet) { rt.isMuted.toggle() }.padding(.trailing, -Metrics.Space.s)
                        }
                    }
                    ForEach(SitePermission.list(from: store.settings.permissionDecisions).filter { $0.host == host }) { permission in
                        ControlRow(symbol: permission.symbol, title: permission.name, detail: permission.allowed ? "Allowed" : "Blocked") {
                            ActionButton(title: "Reset", kind: .quiet) { store.settings.permissionDecisions[permission.key] = nil }.padding(.trailing, -Metrics.Space.s)
                        }
                    }
                }
                ControlRow(symbol: "link", title: "Copy link", detail: nil) {
                    ActionButton(title: "Copy", kind: .quiet) { store.perform(.copyLink, in: window); window.overlay = nil }.padding(.trailing, -Metrics.Space.s)
                }
            }
            .padding(8)
        }
    }

    private func radialDetail(_ host: String) -> String {
        let radial = store.settings.radialMenu
        guard radial.enabled else { return "Off everywhere" }
        guard let entry = radial.disablingEntry(for: host) else { return "On for this site" }
        return entry == host ? "Off for this site" : "Off for \(entry)"
    }

    struct ControlRow<Trailing: View>: View {
        let symbol: String
        let title: String
        let detail: String?
        @ViewBuilder var trailing: () -> Trailing
        @Environment(\.palette) private var palette

        var body: some View {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.accentGlyph).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                    if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(palette.secondary) }
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsPanel: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    struct Entry {
        /// As the menus show them; several chords are two spaces apart, a run of keys is "1–9".
        let keys: String
        let what: String
        /// Listed while this feature is switched on.
        var feature: Feature?
        init(_ keys: String, _ what: String, _ feature: Feature? = nil) { self.keys = keys; self.what = what; self.feature = feature }
    }

    /// Every chord here that the menus have is written as the menu writes it (a test holds them to it).
    static let groups: [(String, [Entry])] = [
        ("Command Bar", [Entry("⌘T", "New tab / open the Command Bar"), Entry("⌘L", "Search or edit the address"),
                         Entry("⌘↩", "Open the result the other way: here, or in a new tab"), Entry("Tab", "Search inside a site"), Entry("esc", "Close the Command Bar")]),
        ("Tabs", [Entry("⌘W", "Archive the tab (a pinned one goes to sleep)"), Entry("⇧⌘T", "Reopen closed tab"), Entry("⌘D", "Pin or unpin"),
                  Entry("⌥⌘D", "Add to or remove from Favorites"), Entry("⇧⌘K", "Archive all Today tabs"), Entry("⌥⌘↓  ⌥⌘↑", "Next / previous tab"),
                  Entry("⌃⇥", "Most recent tab"), Entry("⌘1–9", "Jump to a Favorite"), Entry("⌘O", "Keep a Peek page as a tab", .peek)]),
        ("Spaces", [Entry("⌥⌘←  ⌥⌘→", "Previous / next space"), Entry("⌃1–9", "Go to space"), Entry("⌘S", "Show or hide the sidebar")]),
        ("Split View", [Entry("⌃⇧=", "Add a split"), Entry("⌃⇧-", "Close the focused pane")]),
        ("Page", [Entry("⌘F", "Find in page"), Entry("⌘G", "Next match"), Entry("⌘R", "Reload"), Entry("⌘[  ⌘]", "Back / forward"),
                  Entry("⌘=  ⌘-  ⌘0", "Zoom in, out, actual size"), Entry("⇧⌘C", "Copy link"), Entry("⌥⌘P", "Picture in Picture"),
                  Entry("⌥⌘B", "Boost this site", .boosts)]),
        ("Windows", [Entry("⌘N", "New window"), Entry("⇧⌘N", "New incognito window"), Entry("⌥⌘N", "New Probe (a small floating window)"),
                     Entry("⌘Y", "History"), Entry("⇧⌘A", "Archived tabs"), Entry("⇧⌘J", "Downloads"),
                     Entry("⌃⌘S", "Show or hide the utilities", .utilities), Entry("⌘,", "Settings"), Entry("⌘/", "This list")]),
    ]

    var body: some View {
        PanelFrame(title: "Keyboard Shortcuts", symbol: "keyboard", width: 760, height: 560, close: { window.overlay = nil }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), spacing: 28, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(Self.groups, id: \.0) { title, entries in
                        let rows = entries.filter { $0.feature.map(store.settings.isOn) ?? true }.map { ($0.keys, $0.what) }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundStyle(palette.tertiary)
                            ForEach(rows, id: \.0) { keys, what in
                                HStack(spacing: 10) {
                                    Text(keys)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(palette.text)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.hoverStrong))
                                        .frame(minWidth: 96, alignment: .leading)
                                    Text(what).font(.system(size: 12.5)).foregroundStyle(palette.secondary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
    }
}
