import AppKit
import LocalAuthentication
import SwiftUI
import CosmosCore

/// Settings ▸ Passwords: whether Cosmos offers to keep what is typed into sign-in forms, and the sign-ins it keeps.
/// Showing or copying a password asks for the Mac's password (or Touch ID) first, once while the pane is open.
struct PasswordsPane: View {
    let store: BrowserStore
    let model: SettingsModel
    @Local private var search = ""
    @Local private var shown: Set<UUID> = []
    @Local private var unlocked = false
    @Local private var note: String?
    @Local private var importing = false
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var store = store
        let passwords = store.passwords
        let list = Self.matching(passwords.logins, search)
        Pane(title: "Passwords", subtitle: "Sign-ins Cosmos keeps for you, locked with a key in your Keychain.", symbol: "key.fill") {
            SettingsGroup(title: "Saving", note: "Passwords stay on this Mac. Private windows neither save nor fill them.") {
                SettingRow(title: "Offer to save passwords", detail: "When you sign in to a site, Cosmos asks whether to keep the password.", symbol: "key") {
                    SwitchControl(isOn: $store.settings.offerToSavePasswords)
                }
                Hairline()
                SettingRow(title: "Import from Arc", detail: "Arc's saved passwords, and the sites you are signed in to. macOS asks before Cosmos can read them.",
                           symbol: "arrow.down.doc") {
                    ActionButton(title: "Import…", kind: .secondary, busy: importing) { importFromArc() }
                }
                if let message = note ?? passwords.problem {
                    Hairline()
                    HStack(spacing: Metrics.Space.s) {
                        Image(systemName: note == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(note == nil ? palette.negative : palette.positive)
                        Text(message).font(.system(size: 12.5)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .cardInset()
                }
            }

            SettingsGroup(title: "Saved passwords") {
                if !passwords.logins.isEmpty {
                    FieldInput(text: $search, placeholder: "Search sites and user names").cardInset()
                    Hairline()
                }
                if list.isEmpty {
                    SettingRow(title: passwords.logins.isEmpty ? "No saved passwords" : "Nothing matches",
                               detail: passwords.logins.isEmpty ? "Passwords you save or import appear here." : nil, symbol: "key") { EmptyView() }
                } else {
                    DividedRows(list) { login in
                        SettingRow(title: login.site, detail: login.username.isEmpty ? "No user name" : login.username, symbol: "person.crop.circle") {
                            HStack(spacing: Metrics.Space.xs) {
                                if shown.contains(login.id) {
                                    Text(login.password).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.text)
                                        .textSelection(.enabled).lineLimit(1)
                                }
                                IconButton(symbol: shown.contains(login.id) ? "eye.slash" : "eye",
                                           label: (shown.contains(login.id) ? "Hide" : "Show") + " the password for \(login.site)") { toggle(login) }
                                IconButton(symbol: "doc.on.doc", label: "Copy the password for \(login.site)") { copy(login) }
                                IconButton(symbol: "trash", label: "Delete the password for \(login.site)", destructive: true) { delete(login) }
                            }
                        }
                    }
                }
            }
            .animation(Motion.standard, value: list.map(\.id))

            if !passwords.neverSaved.isEmpty {
                SettingsGroup(title: "Never saved", note: "Sites you asked Cosmos never to offer to save a password for.") {
                    DividedRows(items: passwords.neverSaved, id: \.self) { origin in
                        SettingRow(title: URLComponents(string: origin)?.host ?? origin, symbol: "nosign") {
                            IconButton(symbol: "xmark", label: "Offer to save passwords for \(origin) again") { passwords.allowSaving(origin) }
                        }
                    }
                }
            }
        }
        .onAppear { passwords.load() }
    }

    /// The sign-ins whose site or user name contains `search` (all of them when it is empty).
    static func matching(_ logins: [SavedLogin], _ search: String) -> [SavedLogin] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return logins }
        return logins.filter { $0.site.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    private func toggle(_ login: SavedLogin) {
        if shown.contains(login.id) { shown.remove(login.id); return }
        unlock { shown.insert(login.id) }
    }

    private func copy(_ login: SavedLogin) {
        unlock {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(login.password, forType: .string)
            // Clipboard managers that follow the convention don't keep it, and it is gone a minute later unless something
            // else was copied since.
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            let copied = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if board.changeCount == copied { board.clearContents() } }
            withAnimation(Motion.standard) { note = "Copied the password for \(login.site). It is cleared from the clipboard in a minute." }
        }
    }

    private func delete(_ login: SavedLogin) {
        Task {
            let sure = await model.confirm(.init(title: "Delete the password for \(login.site)?",
                                                 message: "Cosmos forgets \(login.username.isEmpty ? "this sign-in" : login.username + "'s sign-in"). You can't undo this.",
                                                 confirmTitle: "Delete", destructive: true))
            if sure { withAnimation(Motion.standard) { store.passwords.remove(login.id) } }
        }
    }

    /// Runs `then` once the person at the Mac has proved it is them (their password or Touch ID), the first time.
    private func unlock(_ then: @escaping () -> Void) {
        if unlocked { then(); return }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your saved passwords") { ok, _ in
            Task { @MainActor in
                guard ok else { return }
                unlocked = true
                then()
            }
        }
    }

    private func importFromArc() {
        importing = true
        Task {
            let summary = await ImportCoordinator.importArcSignIns(into: store)
            importing = false
            withAnimation(Motion.standard) { note = summary }
        }
    }
}
