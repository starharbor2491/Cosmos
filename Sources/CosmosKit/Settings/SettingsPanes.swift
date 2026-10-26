import SwiftUI
import AppKit
import WebKit
import CosmosCore

// MARK: - General

struct GeneralPane: View {
    let store: BrowserStore
    @Local private var isDefault = DefaultBrowser.isDefault

    var body: some View {
        @Bindable var store = store
        Pane(title: "General", subtitle: "Search, appearance and how Cosmos starts.", symbol: "gearshape.fill") {
            SettingsGroup(title: "Default browser") {
                SettingRow(title: isDefault ? "Cosmos is your default browser" : "Cosmos is not your default browser",
                           detail: isDefault ? "Links from Mail, Slack and everywhere else open here." : "Make it the app that opens links from other apps.",
                           symbol: isDefault ? "checkmark.seal.fill" : "globe") {
                    if !isDefault {
                        ActionButton(title: "Make Default", kind: .primary) { DefaultBrowser.request { _ in isDefault = DefaultBrowser.isDefault } }
                    }
                }
            }
            SettingsGroup(title: "Search") {
                SettingRow(title: "Search engine", detail: "Used when you type something that isn't an address.") {
                    Dropdown(selection: $store.settings.searchEngineID, options: store.catalog.engines.map { Option(value: $0.id, label: $0.name) }, label: "Search engine")
                }
                Hairline()
                SettingRow(title: "Search suggestions", detail: "Show suggestions in the Command Bar as you type.") {
                    SwitchControl(isOn: $store.settings.showSearchSuggestions, label: "Search suggestions")
                }
            }
            SettingsGroup(title: "Appearance") {
                SettingRow(title: "Window appearance", detail: "Menus and dialogs. Each space keeps its own sky.") {
                    SegmentedControl(selection: $store.settings.appearance, options: [
                        Option(value: .system, label: "Auto", symbol: "circle.lefthalf.filled"),
                        Option(value: .light, label: "Light", symbol: "sun.max"),
                        Option(value: .dark, label: "Dark", symbol: "moon"),
                    ])
                    .frame(width: 270)
                }
                Hairline()
                SettingRow(title: "Show the link under the pointer", detail: "A small bubble with the address when you hover a link.") {
                    SwitchControl(isOn: $store.settings.showStatusBubble)
                }
            }
            SettingsGroup(title: "Startup") {
                SettingRow(title: "Reopen windows from last time") {
                    SwitchControl(isOn: $store.settings.restoreTabsOnLaunch, label: "Reopen windows from last time")
                }
                Hairline()
                SettingRow(title: "Close the window with its last tab") {
                    SwitchControl(isOn: $store.settings.closeWindowOnLastTab)
                }
            }
            SettingsGroup(title: "Feel", note: "Motion follows the Reduce Motion setting in System Settings. Loading spinners keep turning.") {
                SettingRow(title: "Trackpad haptics", detail: "A tick under your finger when something snaps, switches or lands.", symbol: "hand.tap") {
                    HStack(spacing: Metrics.Space.m) {
                        ActionButton(title: "Feel it", kind: .quiet, enabled: store.settings.trackpadHaptics) { store.haptics.levelChange() }
                        SwitchControl(isOn: $store.settings.trackpadHaptics, label: "Trackpad haptics")
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarPane: View {
    let store: BrowserStore

    private static let sleepChoices: [Option<Int>] = [
        Option(value: 0, label: "Never"), Option(value: 15, label: "After 15 minutes"), Option(value: 30, label: "After 30 minutes"),
        Option(value: 60, label: "After 1 hour"), Option(value: 120, label: "After 2 hours"),
    ]

    var body: some View {
        @Bindable var store = store
        Pane(title: "Sidebar", subtitle: "How tabs are kept, tidied and put to sleep.", symbol: "sidebar.left") {
            SettingsGroup(title: "Behaviour") {
                SettingRow(title: "Slide in from the window edge", detail: "While the sidebar is hidden, touching the edge brings it back over the page.") {
                    SwitchControl(isOn: $store.settings.revealSidebarOnHover)
                }
                Hairline()
                SettingRow(title: "Open links from pinned tabs in Peek", detail: "Pinned tabs and Favorites keep their place; other sites open beside them.") {
                    SwitchControl(isOn: $store.settings.peekFromPinned, label: "Open links from pinned tabs in Peek")
                }
            }
            SettingsGroup(title: "Tabs") {
                SettingRow(title: "Archive unpinned tabs", detail: "Tabs you haven't touched move to the Archive, where you can still search them.") {
                    Dropdown(selection: $store.archive.interval, options: ArchiveInterval.allCases.map { Option(value: $0, label: $0.label) }, label: "Archive unpinned tabs")
                }
                Hairline()
                SettingRow(title: "Put idle tabs to sleep", detail: "A sleeping tab frees its memory and wakes when you open it.") {
                    Dropdown(selection: $store.settings.memorySaverMinutes, options: Self.sleepChoices, label: "Put idle tabs to sleep")
                }
                Hairline()
                SettingRow(title: "Picture in Picture on leaving", detail: "A tab playing video floats over your other windows when you switch away.") {
                    SwitchControl(isOn: $store.settings.autoPictureInPicture)
                }
            }
        }
    }
}

// MARK: - Privacy

struct PrivacyPane: View {
    let store: BrowserStore
    let model: SettingsModel
    @Local private var note: String?
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var store = store
        let permissions = SitePermission.list(from: store.settings.permissionDecisions)
        Pane(title: "Privacy", subtitle: "What Cosmos remembers, and what sites may use.", symbol: "hand.raised.fill") {
            SettingsGroup(title: "Browsing data", note: "Cosmos has no account and no telemetry. History, cookies and logins stay on this Mac.") {
                SettingRow(title: "History", detail: "Every page you've visited, used for the Command Bar's suggestions.", symbol: "clock") {
                    ActionButton(title: "Clear History", kind: .destructive) { clearHistory() }
                }
                Hairline()
                SettingRow(title: "Cookies and site data", detail: "You'll be signed out of websites in every profile.", symbol: "lock.shield") {
                    ActionButton(title: "Clear Site Data", kind: .destructive) { clearSiteData() }
                }
                if let note {
                    Hairline()
                    HStack(spacing: Metrics.Space.s) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.positive)
                        Text(note).font(.system(size: 12.5)).foregroundStyle(palette.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.Space.l).padding(.vertical, Metrics.Space.m)
                    .transition(.opacity)
                }
            }
            .animation(Motion.standard, value: note)

            SettingsGroup(title: "Site permissions", note: "Camera, microphone and location answers Cosmos has remembered. A site asks again after you reset it.") {
                if permissions.isEmpty {
                    SettingRow(title: "Nothing remembered yet", detail: "Sites you allow or block appear here.", symbol: "checkmark.shield") { EmptyView() }
                } else {
                    DividedRows(permissions) { permission in
                        SettingRow(title: permission.host, detail: permission.name, symbol: permission.symbol) {
                            HStack(spacing: Metrics.Space.s) {
                                Text(permission.allowed ? "Allowed" : "Blocked")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(permission.allowed ? palette.positive : palette.negative)
                                IconButton(symbol: "xmark", label: "Forget \(permission.name) for \(permission.host)") {
                                    withAnimation(Motion.standard) { store.settings.permissionDecisions[permission.key] = nil }
                                }
                            }
                        }
                    }
                    Hairline()
                    SettingRow(title: "Forget all") {
                        ActionButton(title: "Reset Permissions", kind: .secondary) {
                            withAnimation(Motion.standard) { store.settings.permissionDecisions = [:] }
                        }
                    }
                }
            }
            .animation(Motion.standard, value: permissions.map(\.key))
        }
    }

    private func clearHistory() {
        Task {
            let ok = await model.confirm(.init(title: "Clear your history?", message: "Visited pages, what the Command Bar learned from them and the saved site icons are removed. This can't be undone.",
                                               confirmTitle: "Clear History", destructive: true))
            guard ok else { return }
            store.clearHistory()
            announce("History cleared.")
        }
    }

    private func clearSiteData() {
        Task {
            let ok = await model.confirm(.init(title: "Clear cookies and site data?", message: "You'll be signed out of websites in every profile. This can't be undone.",
                                               confirmTitle: "Clear Site Data", destructive: true))
            guard ok else { return }
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            for profile in store.workspace.profiles {
                await store.environment(forProfile: profile.id).dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
            }
            announce("Cookies and site data cleared.")
        }
    }

    private func announce(_ text: String) {
        note = text
        store.haptics.levelChange()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if note == text { note = nil }
        }
    }
}

// MARK: - Links

struct LinksPane: View {
    let store: BrowserStore
    @Local private var newHost = ""
    @Local private var newDestination: LinkDestination = .probe
    @Local private var problem: String?
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var store = store
        Pane(title: "Links", subtitle: "Where links from other apps open.", symbol: "arrow.triangle.branch") {
            SettingsGroup(title: "From other apps", note: "Click a link in Mail, Slack or anywhere else and Cosmos opens it where you choose. Probe is a small floating window you can send to a space when you want to keep the page.") {
                SettingRow(title: "Links open in") {
                    Dropdown(selection: $store.linkRouting.defaultDestination, options: destinations)
                }
            }
            SettingsGroup(title: "Rules", note: "A rule sends links to one site somewhere else. The first rule that matches wins.") {
                if store.linkRouting.rules.isEmpty {
                    SettingRow(title: "No rules yet", detail: "Add a site below, for example github.com.", symbol: "list.bullet") { EmptyView() }
                } else {
                    DividedRows(store.linkRouting.rules) { rule in
                        SettingRow(title: describe(rule), detail: name(of: rule.destination), symbol: "arrow.turn.down.right") {
                            IconButton(symbol: "xmark", label: "Remove rule for \(describe(rule))", destructive: true) {
                                withAnimation(Motion.standard) { store.linkRouting.rules.removeAll { $0.id == rule.id } }
                            }
                        }
                    }
                }
                Hairline()
                HStack(spacing: Metrics.Space.s) {
                    FieldInput(text: $newHost, placeholder: "Site, e.g. github.com", onSubmit: addRule)
                        .onChange(of: newHost) { problem = nil }
                    Dropdown(selection: $newDestination, options: destinations, label: "Open in", width: 190)
                    ActionButton(title: "Add", kind: .primary, enabled: !newHost.trimmingCharacters(in: .whitespaces).isEmpty, action: addRule)
                }
                .cardInset()
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(palette.negative)
                        .padding(.horizontal, Metrics.Space.l).padding(.bottom, Metrics.Space.m)
                        .transition(.opacity)
                }
            }
            .animation(Motion.standard, value: store.linkRouting.rules.map(\.id))
            .animation(Motion.quick, value: problem)
        }
    }

    private func addRule() {
        guard let host = LinkRule.normalizedHost(newHost) else {
            problem = "That isn't a site. Try something like github.com."
            return
        }
        problem = nil
        withAnimation(Motion.standard) { store.linkRouting.rules.append(LinkRule(matches: [.host(host)], destination: newDestination)) }
        newHost = ""
        store.haptics.levelChange()
    }

    private var destinations: [Option<LinkDestination>] {
        [Option(value: .probe, label: "Probe window"), Option(value: .mostRecentSpace, label: "Most recent space")]
            + store.workspace.spaces.map { Option(value: LinkDestination.space($0.id), label: "Space: \($0.title)") }
    }

    private func name(of destination: LinkDestination) -> String {
        switch destination {
        case .probe: "Opens in a Probe window"
        case .mostRecentSpace: "Opens in your most recent space"
        case .space(let id): "Opens in \(store.workspace.space(id)?.title ?? "a space")"
        }
    }

    private func describe(_ rule: LinkRule) -> String {
        rule.matches.map { match in
            switch match {
            case .host(let h): return h
            case .urlContains(let s): return "contains “\(s)”"
            case .urlPrefix(let s): return "starts with “\(s)”"
            case .urlSuffix(let s): return "ends with “\(s)”"
            }
        }.joined(separator: " and ")
    }
}

// MARK: - About

struct AboutPane: View {
    let store: BrowserStore
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Metrics.Space.m) {
            Spacer(minLength: 0)
            CosmosLogo(size: 104)
            Text("Cosmos").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(palette.text)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.secondary)
            Text("A space-themed browser for people who miss Arc.\nBuilt on WebKit.")
                .font(.system(size: 13.5)).multilineTextAlignment(.center).foregroundStyle(palette.secondary)
                .padding(.bottom, Metrics.Space.s)
            HStack(spacing: Metrics.Space.m) {
                ActionButton(title: "Show Welcome", symbol: "sparkles", kind: .secondary) { store.activeWindow?.overlay = .welcome }
                ActionButton(title: "Reveal Data Folder", symbol: "folder", kind: .secondary) {
                    if let dir = store.dataDirectory { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
            }
            Spacer(minLength: 0)
            Text("Cosmos is MIT licensed. It contains no code, assets or strings from Arc.")
                .font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
        }
        .padding(Metrics.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
