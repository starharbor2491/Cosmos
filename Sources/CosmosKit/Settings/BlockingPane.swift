import SwiftUI
import AppKit
import CosmosCore
import CosmosBlocking

/// Settings ▸ Blocking: the master switch, which filter lists are on, their state, your own lists and the sites where
/// blocking is off. The lists are downloaded from their publishers; Cosmos ships none of them.
struct BlockingPane: View {
    let store: BrowserStore
    @Local private var customName = ""
    @Local private var customURL = ""
    @Local private var addProblem: String?
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var store = store
        let blocker = store.blocker
        let statuses = Dictionary((blocker?.statuses ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let custom = (blocker?.statuses ?? []).filter(\.info.isCustom).map(\.info)
        let lists = FilterListCatalog.all + custom

        Pane(title: "Blocking", subtitle: "Ads, trackers and cookie banners, stopped before they load.", symbol: "shield.lefthalf.filled") {
            SettingsGroup(note: "You can switch blocking off for one site from the shield in its Site Controls panel.") {
                SettingRow(title: "Block ads and trackers", detail: summaryLine(blocker), symbol: "shield.lefthalf.filled") {
                    HStack(spacing: Metrics.Space.m) {
                        if store.settings.adBlockingEnabled, let blocker {
                            ActionButton(title: "Update Now", symbol: "arrow.triangle.2.circlepath", kind: .secondary, busy: blocker.isUpdating) { blocker.updateNow() }
                        }
                        SwitchControl(isOn: $store.settings.adBlockingEnabled, label: "Block ads and trackers")
                    }
                }
            }

            SettingsGroup(title: "Filter lists") {
                DividedRows(lists) { info in
                    SettingRow(title: info.name, detail: [info.isCustom ? info.url.absoluteString : info.summary, info.license.isEmpty ? nil : "License: \(info.license)", statusLine(statuses[info.id])].compactMap { $0 }.joined(separator: "\n")) {
                        HStack(spacing: Metrics.Space.s) {
                            if info.isCustom {
                                IconButton(symbol: "trash", label: "Remove \(info.name)", destructive: true) { Task { await blocker?.removeCustomList(id: info.id) } }
                            }
                            SwitchControl(isOn: Binding(
                                get: { store.settings.enabledFilterLists.contains(info.id) },
                                set: { on in
                                    if on { if !store.settings.enabledFilterLists.contains(info.id) { store.settings.enabledFilterLists.append(info.id) } }
                                    else { store.settings.enabledFilterLists.removeAll { $0 == info.id } }
                                }), label: info.name)
                        }
                    }
                }
                .opacity(store.settings.adBlockingEnabled ? 1 : 0.45)
                .disabled(!store.settings.adBlockingEnabled)
            }

            SettingsGroup(title: "Add your own list", note: "Use a web address or a file:// path to a list in the usual Adblock format.") {
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    HStack(spacing: Metrics.Space.s) {
                        FieldInput(text: $customName, placeholder: "Name", width: 150)
                        FieldInput(text: $customURL, placeholder: "Address (https:// or file://)", onSubmit: addCustomList)
                        ActionButton(title: "Add List", kind: .primary, enabled: !customURL.trimmingCharacters(in: .whitespaces).isEmpty, action: addCustomList)
                    }
                    if let addProblem {
                        Text(addProblem).font(.system(size: 12)).foregroundStyle(palette.negative).transition(.opacity)
                    }
                }
                .cardInset()
                .animation(Motion.quick, value: addProblem)
            }

            if !store.settings.adBlockAllowlist.isEmpty {
                SettingsGroup(title: "Sites where blocking is off") {
                    DividedRows(items: store.settings.adBlockAllowlist, id: \.self) { host in
                        SettingRow(title: host, symbol: "shield.slash") {
                            IconButton(symbol: "xmark", label: "Turn blocking back on for \(host)") {
                                withAnimation(Motion.standard) { store.settings.adBlockAllowlist.removeAll { $0 == host } }
                            }
                        }
                    }
                }
            }

            Text("Lists are downloaded from their publishers when they are on, then checked about once a day. EasyList, EasyPrivacy and the cookie list are by the EasyList authors (easylist.to) and the Fanboy project; uBlock Origin's lists are by Raymond Hill and contributors. Hover a list to see its license.")
                .font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.Space.xs)
        }
    }

    private func summaryLine(_ blocker: ContentBlockerController?) -> String {
        guard store.settings.adBlockingEnabled else { return "Off. Pages load everything they ask for." }
        guard let blocker else { return "On." }
        let count = blocker.installedRuleCount.formatted(.number)
        if blocker.isUpdating { return blocker.installedRuleCount == 0 ? "Getting the lists…" : "\(count) rules active. Checking for updates…" }
        guard let last = blocker.lastRefresh else { return blocker.installedRuleCount == 0 ? "Using the built-in starter rules." : "\(count) rules active." }
        return "\(count) rules active. Checked \(Self.relative.localizedString(for: last, relativeTo: Date()))."
    }

    private func statusLine(_ status: FilterListStatus?) -> String? {
        guard let status, status.isEnabled else { return nil }
        var parts: [String] = []
        if let n = status.ruleCount { parts.append("\(n.formatted(.number)) rules") }
        if let checked = status.lastChecked { parts.append("checked \(Self.relative.localizedString(for: checked, relativeTo: Date()))") }
        else { parts.append("not downloaded yet") }
        if let skipped = status.report?.skippedTotal, skipped > 0 { parts.append("\(skipped.formatted(.number)) unsupported lines skipped") }
        return parts.joined(separator: " · ")
    }

    private func addCustomList() {
        let raw = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            addProblem = "Enter a web address or a file:// path."
            return
        }
        let name = customName.trimmingCharacters(in: .whitespaces)
        addProblem = nil
        Task {
            let info = await store.blocker?.addCustomList(name: name.isEmpty ? (url.host ?? url.lastPathComponent) : name, url: url)
            if info == nil { addProblem = "That list couldn't be added." } else { customName = ""; customURL = ""; store.haptics.levelChange() }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
