import SwiftUI
import AppKit
import CosmosCore

// MARK: - Site controls

/// The Site Control Center: what Cosmos is doing on the page you're looking at (blocking, zoom, Boosts, permissions).
struct SiteControlsPanel: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let rt = store.currentRuntime(in: window)
        let url = store.currentURL(in: window)
        let host = url?.host ?? ""
        let blocked = store.settings.adBlockAllowlist.contains(host) == false && store.settings.adBlockingEnabled
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FaviconView(store: store, url: url, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.isEmpty ? "No page" : host).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.text)
                    Text(url?.scheme == "https" ? "Connection is secure" : (url == nil ? "" : "Connection is not secure"))
                        .font(.system(size: 11.5)).foregroundStyle(url?.scheme == "https" ? palette.secondary : Color.orange)
                }
                Spacer()
            }
            .padding(14)
            Rectangle().fill(palette.stroke).frame(height: 0.5)

            VStack(spacing: 2) {
                if !host.isEmpty {
                    ControlRow(symbol: "shield.lefthalf.filled", title: "Ad & tracker blocking", detail: store.settings.adBlockingEnabled ? (blocked ? "On for this site" : "Off for this site") : "Off everywhere") {
                        SwitchControl(isOn: Binding(get: { blocked }, set: { on in
                            if on { store.settings.adBlockAllowlist.removeAll { $0 == host } }
                            else if !store.settings.adBlockAllowlist.contains(host) { store.settings.adBlockAllowlist.append(host) }
                            rt?.reload()
                        }), label: "Ad and tracker blocking on this site")
                        .opacity(store.settings.adBlockingEnabled ? 1 : 0.4)
                        .allowsHitTesting(store.settings.adBlockingEnabled)
                    }
                    ControlRow(symbol: "plus.magnifyingglass", title: "Page zoom", detail: "\(Int(((rt?.zoom ?? 1) * 100).rounded()))%") {
                        HStack(spacing: 2) {
                            ToolbarButton(symbol: "minus", size: 12, help: "Zoom Out") { rt?.zoomOut() }
                            ToolbarButton(symbol: "plus", size: 12, help: "Zoom In") { rt?.zoomIn() }
                            ToolbarButton(symbol: "arrow.counterclockwise", size: 12, help: "Actual Size") { rt?.resetZoom() }
                        }
                    }
                    ControlRow(symbol: "wand.and.stars", title: "Boost this site", detail: store.boostForCurrentPageIfExists(in: window) == nil ? "Recolour, change fonts, hide things" : "You have a Boost here") {
                        ActionButton(title: "Open", kind: .quiet) { window.overlay = .boosts }.padding(.trailing, -Metrics.Space.s)
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
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous))
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
        .shadow(color: palette.shadow, radius: 28, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, window.sidebarVisible ? Metrics.Sidebar.gutter : 90)
        .padding(.top, window.sidebarVisible ? Metrics.Height.toolbar + Metrics.Height.field + Metrics.Space.xs : 52)
    }

    struct ControlRow<Trailing: View>: View {
        let symbol: String
        let title: String
        let detail: String?
        @ViewBuilder var trailing: () -> Trailing
        @Environment(\.palette) private var palette

        var body: some View {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.accent).frame(width: 24)
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
    let window: WindowState
    @Environment(\.palette) private var palette

    private static let groups: [(String, [(String, String)])] = [
        ("Command Bar", [("⌘T", "New tab / open the Command Bar"), ("⌘L", "Search or edit the address"), ("⌘↩", "Open the result in a new tab"), ("Tab", "Search inside a site"), ("⎋", "Close the Command Bar")]),
        ("Tabs", [("⌘W", "Close tab"), ("⇧⌘T", "Reopen closed tab"), ("⌘D", "Pin or unpin"), ("⇧⌘D", "Add to Favorites"), ("⇧⌘K", "Archive all Today tabs"), ("⌃⇥", "Next recent tab"), ("⌘1–9", "Jump to a Favorite")]),
        ("Spaces", [("⌥⌘←  ⌥⌘→", "Previous / next space"), ("⌃1–9", "Go to space"), ("⌘S", "Toggle sidebar")]),
        ("Split View", [("⌃⇧=", "Add a split"), ("⌃⇧-", "Close the focused pane")]),
        ("Page", [("⌘F", "Find in page"), ("⌘G", "Next match"), ("⌘R", "Reload"), ("⌘[  ⌘]", "Back / forward"), ("⌘+  ⌘−  ⌘0", "Zoom"), ("⇧⌘C", "Copy link")]),
        ("Windows", [("⌘N", "New window"), ("⇧⌘N", "New incognito window"), ("⌥⌘N", "New Probe (a small floating window)"), ("⌘Y", "History"), ("⇧⌘J", "Downloads"), ("⌘,", "Settings")]),
    ]

    var body: some View {
        PanelFrame(title: "Keyboard Shortcuts", symbol: "keyboard", width: 760, height: 560, close: { window.overlay = nil }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), spacing: 28, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(Self.groups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundStyle(palette.tertiary)
                            ForEach(rows, id: \.0) { keys, what in
                                HStack(spacing: 10) {
                                    Text(keys)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(palette.text)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.hover.opacity(1.6)))
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
