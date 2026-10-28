import SwiftUI
import CosmosCore

/// Settings ▸ Menu Bar: the icon that opens a small browser under it, which pages it shows and whose logins it uses.
struct MenuBarPane: View {
    let store: BrowserStore
    @Local private var home: String
    @Local private var problem: String?
    @Environment(\.palette) private var palette

    init(store: BrowserStore) {
        self.store = store
        _home = Local(wrappedValue: store.settings.menuBar.homeAddress)
    }

    var body: some View {
        @Bindable var store = store
        let menuBar = store.settings.menuBar
        Pane(title: "Menu Bar", subtitle: "A small browser under an icon in the menu bar.", symbol: "menubar.rectangle") {
            SettingsGroup(note: "Click the icon to open it and click anywhere else to put it away. The pin in its toolbar keeps it open over your other windows. The page stays loaded while it is put away, so a video or song keeps playing. Right-click the icon for Settings and to hide it.") {
                SettingRow(title: "Show Cosmos in the menu bar", detail: menuBar.enabled ? "On. Look for the Cosmos icon at the top of the screen." : "Off. No icon is added to the menu bar.", symbol: "menubar.rectangle") {
                    SwitchControl(isOn: $store.settings.menuBar.enabled, label: "Show Cosmos in the menu bar")
                }
            }

            SettingsGroup(title: "Look", note: "Phone-sized is narrow and tells sites it is a phone, so they show their mobile pages. Desktop is wider and shows their desktop pages.") {
                SettingRow(title: "Size", symbol: "rectangle.portrait.arrowtriangle.2.outward") {
                    SegmentedControl(selection: $store.settings.menuBar.layout, options: [
                        Option(value: .phone, label: "Phone", symbol: "iphone"),
                        Option(value: .desktop, label: "Desktop", symbol: "desktopcomputer"),
                    ])
                    .frame(width: Metrics.Control.segmentedWidth)
                }
                Hairline()
                SettingRow(title: "Panel size", detail: "Drag any edge or corner of the panel to change it. Now \(Int(menuBar.size.width)) × \(Int(menuBar.size.height)).", symbol: "arrow.up.left.and.arrow.down.right") {
                    ActionButton(title: "Reset", enabled: menuBar.hasCustomSize) { store.settings.menuBar.resetSize() }
                }
            }
            .opacity(menuBar.enabled ? 1 : 0.45)
            .disabled(!menuBar.enabled)

            accounts(menuBar)
                .opacity(menuBar.enabled ? 1 : 0.45)
                .disabled(!menuBar.enabled)

            startPage(menuBar)
                .opacity(menuBar.enabled ? 1 : 0.45)
                .disabled(!menuBar.enabled)
        }
    }

    // MARK: Logins

    private func accounts(_ menuBar: MenuBarSettings) -> some View {
        let profiles = store.workspace.profiles
        let current = menuBar.profile(in: profiles)
        return SettingsGroup(title: "Logins", note: "The menu bar browser uses the same cookies and site data as the browser windows, so a site you are signed in to there is signed in here, and the other way round. Its pages also appear in your history.") {
            if profiles.count > 1, let current {
                SettingRow(title: "Use the logins of", detail: "A profile is a separate set of cookies. Spaces can use different ones.", symbol: "person.crop.circle") {
                    Dropdown(selection: Binding(get: { current.id }, set: { store.settings.menuBar.profileID = $0 }),
                             options: profiles.map { Option(value: $0.id, label: $0.name) }, label: "Use the logins of")
                }
            } else {
                SettingRow(title: "Same logins as the browser", detail: "There is one profile, so there is nothing to choose.", symbol: "person.crop.circle") { EmptyView() }
            }
        }
    }

    // MARK: Start page

    private func startPage(_ menuBar: MenuBarSettings) -> some View {
        @Bindable var store = store
        let engine = store.catalog.engine(store.settings.searchEngineID)
        let start = MenuBarSettings.homeURL(from: menuBar.homeAddress) ?? engine.homeURL
        return SettingsGroup(title: "Start page", note: "Leave it empty to start on your search engine's page.") {
            SettingRow(title: "Open on the page I left", detail: "Otherwise it starts on the start page every time.", symbol: "arrow.uturn.backward") {
                SwitchControl(isOn: $store.settings.menuBar.rememberPage, label: "Open on the page I left")
            }
            Hairline()
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                HStack(spacing: Metrics.Space.s) {
                    FieldInput(text: $home, placeholder: "Address, e.g. news.ycombinator.com", onSubmit: save)
                        .onChange(of: home) { problem = nil }
                    ActionButton(title: "Save", kind: .primary, enabled: home.trimmingCharacters(in: .whitespaces) != menuBar.homeAddress, action: save)
                }
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(palette.negative).transition(.opacity)
                } else if let start {
                    Text("Starts on \(URLInput.hostForDisplay(start))").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
            .cardInset()
            .animation(Motion.quick, value: problem)
        }
    }

    private func save() {
        let typed = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty || MenuBarSettings.homeURL(from: typed) != nil else {
            problem = "That isn't a web address. Try something like news.ycombinator.com."
            return
        }
        problem = nil
        store.settings.menuBar.homeAddress = typed
        home = typed
        store.haptics.levelChange()
    }
}
