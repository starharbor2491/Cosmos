import SwiftUI
import AppKit
import WebKit
import CosmosCore

enum SettingsTab: String, CaseIterable {
    case general, sidebar, blocking, extensions, privacy, links, about
}

/// The Settings window (⌘,). Plain system controls: it's a settings window, not a place for theming.
struct SettingsView: View {
    let store: BrowserStore
    @Local private var tab: SettingsTab

    init(store: BrowserStore, tab: SettingsTab = .general) {
        self.store = store
        _tab = Local(wrappedValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(store: store).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            SidebarSettings(store: store).tabItem { Label("Sidebar", systemImage: "sidebar.left") }.tag(SettingsTab.sidebar)
            BlockingSettings(store: store).tabItem { Label("Blocking", systemImage: "shield.lefthalf.filled") }.tag(SettingsTab.blocking)
            ExtensionsSettings(store: store).tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }.tag(SettingsTab.extensions)
            PrivacySettings(store: store).tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
            LinkSettings(store: store).tabItem { Label("Links", systemImage: "arrow.triangle.branch") }.tag(SettingsTab.links)
            AboutSettings(store: store).tabItem { Label("About", systemImage: "sparkles") }.tag(SettingsTab.about)
        }
        .frame(width: 560, height: 460)
    }
}

private struct GeneralSettings: View {
    let store: BrowserStore
    @Local private var isDefault = DefaultBrowser.isDefault

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack {
                    Text(isDefault ? "Cosmos is your default browser." : "Cosmos is not your default browser.")
                    Spacer()
                    if !isDefault { Button("Make Default") { DefaultBrowser.request { _ in isDefault = DefaultBrowser.isDefault } } }
                }
            }
            Section("Search") {
                Picker("Search engine", selection: $store.settings.searchEngineID) {
                    ForEach(store.catalog.engines) { Text($0.name).tag($0.id) }
                }
                Toggle("Show search suggestions in the Command Bar", isOn: $store.settings.showSearchSuggestions)
            }
            Section("Appearance") {
                Picker("Window appearance", selection: $store.settings.appearance) {
                    Text("Match system").tag(Settings.AppearanceMode.system)
                    Text("Light").tag(Settings.AppearanceMode.light)
                    Text("Dark").tag(Settings.AppearanceMode.dark)
                }
                Toggle("Show link address when hovering", isOn: $store.settings.showStatusBubble)
            }
            Section("Startup") {
                Toggle("Reopen windows from last time", isOn: $store.settings.restoreTabsOnLaunch)
                Toggle("Close the window when its last tab closes", isOn: $store.settings.closeWindowOnLastTab)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SidebarSettings: View {
    let store: BrowserStore

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Sidebar") {
                Toggle("Slide the sidebar in when the pointer touches the window edge", isOn: $store.settings.revealSidebarOnHover)
                Toggle("Open links from pinned tabs in Peek", isOn: $store.settings.peekFromPinned)
            }
            Section("Tabs") {
                Picker("Archive unpinned tabs", selection: $store.archive.interval) {
                    ForEach(ArchiveInterval.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Put idle tabs to sleep", selection: $store.settings.memorySaverMinutes) {
                    Text("Never").tag(0)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                    Text("After 2 hours").tag(120)
                }
                Toggle("Picture in Picture when you leave a tab playing video", isOn: $store.settings.autoPictureInPicture)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    let store: BrowserStore
    @Local private var cleared = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Browsing data") {
                HStack {
                    Text("History")
                    Spacer()
                    Button("Clear History…") { store.history.clear(since: nil); cleared = true }
                }
                HStack {
                    Text("Cookies and site data")
                    Spacer()
                    Button("Clear Site Data…") { clearSiteData() }
                }
                if cleared { Text("Done.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func clearSiteData() {
        let alert = NSAlert()
        alert.messageText = "Clear cookies and site data?"
        alert.informativeText = "You'll be signed out of websites in every profile."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for profile in store.workspace.profiles {
            store.environment(forProfile: profile.id).dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        cleared = true
    }
}

private struct LinkSettings: View {
    let store: BrowserStore
    @Local private var newHost = ""
    @Local private var newDestination: LinkDestination = .probe

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Links from other apps open in", selection: $store.linkRouting.defaultDestination) {
                    ForEach(destinations, id: \.0) { Text($0.0).tag($0.1) }
                }
                Text("Click a link in Mail, Slack or anywhere else and Cosmos opens it where you choose. Probe is a small floating window you can send to a space when you want to keep the page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rules") {
                ForEach(store.linkRouting.rules) { rule in
                    HStack {
                        Text(describe(rule))
                        Spacer()
                        Text(name(of: rule.destination)).foregroundStyle(.secondary)
                        Button { store.linkRouting.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Site, e.g. github.com", text: $newHost)
                    Picker("", selection: $newDestination) { ForEach(destinations, id: \.0) { Text($0.0).tag($0.1) } }.labelsHidden().frame(width: 170)
                    Button("Add") {
                        let h = newHost.trimmingCharacters(in: .whitespaces)
                        guard !h.isEmpty else { return }
                        store.linkRouting.rules.append(LinkRule(matches: [.host(h)], destination: newDestination))
                        newHost = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var destinations: [(String, LinkDestination)] {
        [("Probe window", .probe), ("Most recent space", .mostRecentSpace)] + store.workspace.spaces.map { ("Space: \($0.title)", LinkDestination.space($0.id)) }
    }

    private func name(of d: LinkDestination) -> String {
        switch d {
        case .probe: return "Probe"
        case .mostRecentSpace: return "Most recent space"
        case .space(let id): return store.workspace.space(id)?.title ?? "Space"
        }
    }

    private func describe(_ rule: LinkRule) -> String {
        rule.matches.map { m in
            switch m {
            case .host(let h): return h
            case .urlContains(let s): return "contains “\(s)”"
            case .urlPrefix(let s): return "starts with “\(s)”"
            case .urlSuffix(let s): return "ends with “\(s)”"
            }
        }.joined(separator: " and ")
    }
}

private struct AboutSettings: View {
    let store: BrowserStore

    var body: some View {
        VStack(spacing: 12) {
            CosmosLogo(size: 90)
            Text("Cosmos").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("A space-themed browser for people who miss Arc.\nBuilt on WebKit.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            HStack(spacing: 12) {
                Button("Show Welcome Screen") { store.activeWindow?.overlay = .welcome }
                Button("Reveal Data Folder") {
                    if let dir = store.dataDirectory { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
