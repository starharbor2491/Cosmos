import SwiftUI
import AppKit
import CosmosCore
import CosmosImport

/// Settings ▸ Extensions: what is installed, and three ways to add more: a Chrome Web Store link, a folder, or the
/// extensions already in Arc or another browser on this Mac.
struct ExtensionsSettings: View {
    let store: BrowserStore
    @Local private var link = ""
    @Local private var found: [DiscoveredExtension]?
    @Local private var picked: Set<String> = []
    @Local private var scanning = false
    @Local private var problem: String?

    var body: some View {
        Form {
            if !ExtensionCenter.isSupported {
                Section {
                    Text("Extensions need macOS 15.4 or later. This Mac has an older macOS.")
                }
            } else if let center = store.extensionCenter {
                installedSection(center)
                addSection(center)
                if let found { discoverySection(center, found) }
                Section {
                    EmptyView()
                } footer: {
                    Text("Cosmos runs extensions with WebKit, the engine Safari uses. Most Chrome extensions work, including those built for Manifest V3. Features that only exist in Chrome (history, bookmarks, downloads, notifications and sign-in through Chrome) are not available, and the Add prompt tells you when an extension needs them. Extensions are not loaded in Incognito windows.")
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
            } else {
                Section { Text("Extensions are off in this window.") }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private func installedSection(_ center: ExtensionCenter) -> some View {
        Section("Installed") {
            if center.items.isEmpty {
                Text("No extensions yet.").foregroundStyle(.secondary)
            }
            ForEach(center.items) { item in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { item.enabled }, set: { center.setEnabled(item.id, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                            Text("Version \(item.version) · from \(item.origin)").font(.caption).foregroundStyle(.secondary)
                            if let error = center.loadErrors[item.id] {
                                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)
                            }
                        }
                    }
                    Button("Remove") { center.remove(item.id) }.buttonStyle(.link)
                }
            }
            if center.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) }
            }
            if let message = center.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func addSection(_ center: ExtensionCenter) -> some View {
        Section("Add an extension") {
            HStack {
                TextField("Chrome Web Store link or extension id", text: $link)
                    .onSubmit { addFromWebStore(center) }
                Button("Add") { addFromWebStore(center) }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || center.busy)
            }
            HStack {
                Button("Choose a Folder…") { addFromFolder(center) }
                Button(scanning ? "Looking…" : "Find in Arc and Other Browsers…") { discover(center) }
                    .disabled(scanning)
                Spacer()
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func discoverySection(_ center: ExtensionCenter, _ found: [DiscoveredExtension]) -> some View {
        Section("Found on this Mac") {
            if found.isEmpty { Text("No other extensions found.").foregroundStyle(.secondary) }
            ForEach(found) { ext in
                Toggle(isOn: Binding(get: { picked.contains(ext.id) }, set: { on in if on { picked.insert(ext.id) } else { picked.remove(ext.id) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ext.name)
                        Text("Version \(ext.version) · \(ext.source)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !found.isEmpty {
                HStack {
                    Button("Select All") { picked = Set(found.map(\.id)) }
                    Spacer()
                    Button("Add Selected") { addPicked(center, found.filter { picked.contains($0.id) }) }
                        .disabled(picked.isEmpty || center.busy)
                }
            }
        }
    }

    // MARK: Actions

    private func addFromWebStore(_ center: ExtensionCenter) {
        let text = link
        problem = nil
        Task {
            do {
                try await center.installFromWebStore(text, confirm: ExtensionPrompt.confirm)
                link = ""
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
            do { try await center.install(from: url, origin: "a folder", confirm: ExtensionPrompt.confirm) }
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
                do { try await center.install(from: ext.directory, origin: ext.source, webStoreID: ext.id, confirm: ExtensionPrompt.confirm) }
                catch ExtensionError.declined {}
                catch { failures.append("\(ext.name): \(error.localizedDescription)") }
            }
            problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
            found = await center.discoverable()
            picked = []
        }
    }
}

/// The "Add extension?" question.
@MainActor
enum ExtensionPrompt {
    static func confirm(_ summary: ExtensionRequestSummary) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(summary.name)”?"
        var text = "From \(summary.origin)."
        let lines = summary.lines
        if lines.isEmpty { text += "\n\nIt doesn't ask for any special access." }
        else { text += "\n\nIt will be able to:\n" + lines.map { "• \($0)" }.joined(separator: "\n") }
        if !summary.problems.isEmpty { text += "\n\n" + summary.problems.prefix(3).joined(separator: "\n") }
        alert.informativeText = text
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
