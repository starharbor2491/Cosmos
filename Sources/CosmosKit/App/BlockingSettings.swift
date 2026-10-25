import SwiftUI
import AppKit
import CosmosCore
import CosmosBlocking

/// Settings ▸ Blocking: the master switch, which filter lists are on, their state, your own lists and the sites where
/// blocking is off. The lists are downloaded from their publishers; Cosmos ships none of them.
struct BlockingSettings: View {
    let store: BrowserStore
    @Local private var customName = ""
    @Local private var customURL = ""
    @Local private var addProblem: String?

    var body: some View {
        @Bindable var store = store
        let blocker = store.blocker
        let statuses = Dictionary((blocker?.statuses ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let custom = (blocker?.statuses ?? []).filter(\.info.isCustom).map(\.info)
        let lists = FilterListCatalog.all + custom

        Form {
            Section {
                Toggle("Block ads and trackers", isOn: $store.settings.adBlockingEnabled)
                if store.settings.adBlockingEnabled, let blocker {
                    HStack(spacing: 8) {
                        if blocker.isUpdating { ProgressView().controlSize(.small) }
                        Text(summary(blocker)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Update Now") { blocker.updateNow() }.disabled(blocker.isUpdating)
                    }
                }
            } footer: {
                Text("Blocks ads, trackers and cookie banners before they load. You can switch it off for one site from the shield in the Site Controls panel.")
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }

            Section("Filter lists") {
                ForEach(lists, id: \.id) { info in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(
                            get: { store.settings.enabledFilterLists.contains(info.id) },
                            set: { on in
                                if on { if !store.settings.enabledFilterLists.contains(info.id) { store.settings.enabledFilterLists.append(info.id) } }
                                else { store.settings.enabledFilterLists.removeAll { $0 == info.id } }
                            })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                Text(info.isCustom ? info.url.absoluteString : info.summary)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let line = statusLine(statuses[info.id]) {
                                    Text(line).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .help(info.license.isEmpty ? info.url.absoluteString : "License: \(info.license)")
                        if info.isCustom {
                            Button("Remove") { Task { await blocker?.removeCustomList(id: info.id) } }
                                .buttonStyle(.link)
                        }
                    }
                }
                .disabled(!store.settings.adBlockingEnabled)
            }

            Section("Add your own list") {
                TextField("Name", text: $customName)
                TextField("Address (https:// or file://)", text: $customURL)
                HStack {
                    if let addProblem { Text(addProblem).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button("Add List") { addCustomList() }
                        .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !store.settings.adBlockAllowlist.isEmpty {
                Section("Sites where blocking is off") {
                    ForEach(store.settings.adBlockAllowlist, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Remove") { store.settings.adBlockAllowlist.removeAll { $0 == host } }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Lists are downloaded from their publishers when they are on, then checked about once a day. EasyList, EasyPrivacy and the cookie list are by the EasyList authors (easylist.to) and the Fanboy project; uBlock Origin's lists are by Raymond Hill and contributors. Hover a list to see its license.")
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ blocker: ContentBlockerController) -> String {
        let rules = blocker.installedRuleCount
        let count = rules.formatted(.number)
        if blocker.isUpdating { return rules == 0 ? "Getting the lists…" : "\(count) rules active. Checking for updates…" }
        guard let last = blocker.lastRefresh else { return rules == 0 ? "Using the built-in starter rules." : "\(count) rules active." }
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
            if info == nil { addProblem = "That list couldn't be added." } else { customName = ""; customURL = "" }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
