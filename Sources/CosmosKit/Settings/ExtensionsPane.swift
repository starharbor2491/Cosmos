import SwiftUI
import AppKit
import CosmosCore
import CosmosImport

/// Settings ▸ Extensions: what is installed, and three ways to add more: a Chrome Web Store link, a folder, or the
/// extensions already in Arc or another browser on this Mac.
struct ExtensionsPane: View {
    let store: BrowserStore
    let model: SettingsModel
    @Local private var link = ""
    @Local private var found: [DiscoveredExtension]?
    @Local private var picked: Set<String> = []
    @Local private var scanning = false
    @Local private var problem: String?
    @Environment(\.palette) private var palette

    var body: some View {
        Pane(title: "Extensions", subtitle: "Chrome extensions, run by Chromium.", symbol: "puzzlepiece.extension.fill") {
            if let center = store.extensionCenter {
                installed(center)
                add(center)
                if let found { discovered(center, found) }
                Text("Cosmos runs extensions in Chromium, with Chrome's own extension APIs, and draws their buttons, popups, menu items and shortcuts itself. Extensions built for Manifest V3 work; Chromium no longer runs Manifest V2. Side panels, notifications and sign-in with a Google account don't show yet, and the Add prompt tells you when an extension uses them. Extensions are not loaded in Incognito windows.")
                    .font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Space.xs)
            } else {
                SettingsGroup {
                    SettingRow(title: "Extensions are off in this window", symbol: "puzzlepiece.extension") { EmptyView() }
                }
            }
        }
    }

    // MARK: Sections

    private func installed(_ center: ExtensionCenter) -> some View {
        SettingsGroup(title: "Installed") {
            if center.items.isEmpty {
                SettingRow(title: "No extensions yet", detail: "Add one below.", symbol: "puzzlepiece.extension") { EmptyView() }
            } else {
                DividedRows(center.items) { item in
                    let waiting = center.updatesWaiting[item.id].map { "Version \($0) is ready, and asks for more than this one." }
                    SettingRow(title: item.name, detail: ["Version \(item.version) · from \(item.origin)", waiting, center.loadErrors[item.id]].compactMap { $0 }.joined(separator: "\n")) {
                        HStack(spacing: Metrics.Space.m) {
                            if waiting != nil {
                                ActionButton(title: "Update…", kind: .secondary, enabled: !center.busy) { update(item, in: center) }
                            }
                            ActionButton(title: "Remove", kind: .quiet) { confirmRemove(item, from: center) }
                            SwitchControl(isOn: Binding(get: { item.enabled }, set: { center.setEnabled(item.id, $0) }), label: item.name)
                        }
                    }
                }
            }
            if center.items.contains(where: { $0.webStoreID != nil }) {
                Hairline()
                HStack(spacing: Metrics.Space.s) {
                    Text("Extensions from the Web Store are updated once a day. A new version that asks for more waits for your OK.")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    ActionButton(title: "Check Now", kind: .quiet, enabled: !center.busy && !center.checking) { Task { await center.checkForUpdates() } }
                }
                .cardInset()
            }
            if center.busy || center.checking || center.message != nil {
                Hairline()
                HStack(spacing: Metrics.Space.s) {
                    if center.busy || center.checking { OrbitSpinner(size: 13, color: palette.secondary) }
                    Text(center.busy || center.checking ? "Working…" : (center.message ?? "")).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.Space.l).padding(.vertical, Metrics.Space.m)
            }
        }
        .animation(Motion.standard, value: center.items.map(\.id))
    }

    private func add(_ center: ExtensionCenter) -> some View {
        SettingsGroup(title: "Add an extension") {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.s) {
                    FieldInput(text: $link, placeholder: "Chrome Web Store link or extension id", onSubmit: { addFromWebStore(center) })
                    ActionButton(title: "Add", kind: .primary, enabled: !link.trimmingCharacters(in: .whitespaces).isEmpty && !center.busy) { addFromWebStore(center) }
                }
                HStack(spacing: Metrics.Space.s) {
                    ActionButton(title: "Choose a Folder…", symbol: "folder", kind: .secondary) { addFromFolder(center) }
                    ActionButton(title: "Find in Arc and Other Browsers", symbol: "magnifyingglass", kind: .secondary, busy: scanning) { discover(center) }
                    Spacer(minLength: 0)
                }
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(palette.negative).transition(.opacity)
                }
            }
            .cardInset()
            .animation(Motion.quick, value: problem)
        }
    }

    private func discovered(_ center: ExtensionCenter, _ found: [DiscoveredExtension]) -> some View {
        SettingsGroup(title: "Found on this Mac") {
            if found.isEmpty {
                SettingRow(title: "No other extensions found", symbol: "magnifyingglass") { EmptyView() }
            } else {
                DividedRows(found) { ext in
                    SettingRow(title: ext.name, detail: "Version \(ext.version) · \(ext.source)") {
                        CheckControl(isOn: Binding(get: { picked.contains(ext.id) }, set: { on in if on { picked.insert(ext.id) } else { picked.remove(ext.id) } }), label: ext.name)
                    }
                }
                Hairline()
                HStack(spacing: Metrics.Space.s) {
                    ActionButton(title: "Select All", kind: .quiet) { picked = Set(found.map(\.id)) }
                    Spacer(minLength: 0)
                    ActionButton(title: "Add Selected", kind: .primary, enabled: !picked.isEmpty && !center.busy) { addPicked(center, found.filter { picked.contains($0.id) }) }
                }
                .cardInset()
            }
        }
    }

    // MARK: Actions

    private func confirm(_ summary: ExtensionRequestSummary) async -> Bool {
        var message = "From \(summary.origin)."
        if summary.lines.isEmpty { message += " It doesn't ask for any special access." }
        else { message += " It will be able to:" }
        return await model.confirm(.init(title: "Add “\(summary.name)”?", message: message, bullets: summary.lines + summary.problems.prefix(3),
                                         confirmTitle: "Add Extension"))
    }

    /// A newer version that asks for more: the user sees what, as when adding one.
    private func update(_ item: InstalledExtension, in center: ExtensionCenter) {
        problem = nil
        Task {
            do { try await center.update(item.id, confirm: confirm) }
            catch ExtensionError.declined {}
            catch { problem = error.localizedDescription }
        }
    }

    /// Removing deletes the extension's copy inside Cosmos, so it is asked about first.
    private func confirmRemove(_ item: InstalledExtension, from center: ExtensionCenter) {
        Task {
            let sure = await model.confirm(.init(title: "Remove “\(item.name)”?", message: "It stops running and its files are deleted from Cosmos. You can add it again later.",
                                                 confirmTitle: "Remove", destructive: true))
            if sure { center.remove(item.id) }
        }
    }

    private func addFromWebStore(_ center: ExtensionCenter) {
        let text = link
        problem = nil
        Task {
            do {
                try await center.installFromWebStore(text, confirm: confirm)
                link = ""
                store.haptics.levelChange()
            } catch ExtensionError.declined {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func addFromFolder(_ center: ExtensionCenter) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder that contains the extension's manifest.json"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        Task {
            do { try await center.install(from: url, origin: "a folder", confirm: confirm); store.haptics.levelChange() }
            catch ExtensionError.declined {}
            catch { problem = error.localizedDescription }
        }
    }

    private func discover(_ center: ExtensionCenter) {
        scanning = true
        problem = nil
        Task {
            found = await center.discoverable()
            picked = []
            scanning = false
        }
    }

    private func addPicked(_ center: ExtensionCenter, _ chosen: [DiscoveredExtension]) {
        problem = nil
        Task {
            var failures: [String] = []
            for ext in chosen {
                do { try await center.install(from: ext.directory, origin: ext.source, webStoreID: ext.id, confirm: confirm) }
                catch ExtensionError.declined {}
                catch { failures.append("\(ext.name): \(error.localizedDescription)") }
            }
            problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
            found = await center.discoverable()
            picked = []
            store.haptics.levelChange()
        }
    }
}
