import AppKit
import SwiftUI
import Translation
import CosmosCore

/// The quick utilities at the right of the window: a rail of buttons, each opening its utility in a panel beside the
/// page. What they act on is the page the window shows.
public enum Utility: String, CaseIterable, Identifiable, Sendable {
    case translate, zoom, files, passwords, site

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: "Translate"
        case .zoom: "Zoom"
        case .files: "Files"
        case .passwords: "Passwords"
        case .site: "This Site"
        }
    }

    var symbol: String {
        switch self {
        case .translate: "character.bubble"
        case .zoom: "plus.magnifyingglass"
        case .files: "folder"
        case .passwords: "key"
        case .site: "switch.2"
        }
    }
}

/// The rail: one button per utility; the one whose panel is open is lit, and a second click puts it away.
struct UtilitiesRail: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    static let width: CGFloat = 40

    var body: some View {
        VStack(spacing: Metrics.Space.xs) {
            ForEach(Utility.allCases) { utility in
                let open = window.utility == utility
                ToolbarButton(symbol: utility.symbol, size: 14, box: Metrics.Height.button + 6, help: utility.title) {
                    window.utility = open ? nil : utility
                    store.haptics.alignment()
                }
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(open ? palette.selected : .clear))
                .overlay(alignment: .topTrailing) { badge(for: utility) }
                .accessibilityLabel(utility.title)
                .accessibilityAddTraits(open ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Metrics.Height.toolbar)
        .frame(width: Self.width)
    }

    /// A dot on Files while something downloads, and on Passwords while the page has a sign-in form Cosmos has a password for.
    @ViewBuilder private func badge(for utility: Utility) -> some View {
        let lit: Bool = switch utility {
        case .files: store.downloads.hasActive
        case .passwords: !(store.currentRuntime(in: window)?.savedLogins.isEmpty ?? true)
        default: false
        }
        if lit { Circle().fill(palette.accent).frame(width: 6, height: 6).offset(x: -4, y: 4).accessibilityHidden(true) }
    }
}

/// The open utility's panel, between the page and the rail.
struct UtilityPanel: View {
    let store: BrowserStore
    let window: WindowState
    let utility: Utility
    /// Over the page's edge (a narrow window), where it needs a ground of its own, as the find bar has.
    var floating = false
    @Environment(\.palette) private var palette

    static let width: CGFloat = 300

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: utility.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.secondary)
                Text(utility.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                Spacer(minLength: 0)
                ToolbarButton(symbol: "xmark", size: 11, box: Metrics.Height.compactButton, help: "Close \(utility.title)") { window.utility = nil }
                    .accessibilityLabel("Close \(utility.title)")
            }
            .padding(.horizontal, Metrics.Space.m)
            .frame(height: Metrics.Height.toolbar)
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch utility {
                    case .translate: TranslateUtility(store: store, window: window)
                    case .zoom: ZoomUtility(store: store, window: window)
                    case .files: FilesUtility(store: store, window: window)
                    case .passwords: PasswordsUtility(store: store, window: window)
                    case .site: SiteControlsPanel(store: store, window: window, embedded: true).padding(.horizontal, -Metrics.Space.m)
                    }
                }
                .padding(.horizontal, Metrics.Space.m)
                .padding(.bottom, Metrics.Space.m)
            }
        }
        .frame(width: Self.width)
        .background {
            if floating {
                shape.fill(palette.panel)
                shape.fill(.regularMaterial)
            } else {
                shape.fill(palette.isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.35))
            }
        }
        .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.5))
        .clipShape(shape)
        .padding(.vertical, Metrics.Space.s)
        .id(utility)
    }
}

/// A heading inside a utility's panel.
private struct UtilityHeading: View {
    let text: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .bold, design: .rounded)).tracking(0.8).textCase(.uppercase)
            .foregroundStyle(palette.tertiary).padding(.top, Metrics.Space.m).padding(.bottom, Metrics.Space.xs)
    }
}

/// A line of quiet text inside a utility's panel.
private struct UtilityNote: View {
    let text: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Zoom

struct ZoomUtility: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let rt = store.currentRuntime(in: window)
        let zoom = rt?.zoom ?? 1
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            UtilityHeading(text: rt?.url?.host ?? "This page")
            HStack(spacing: Metrics.Space.s) {
                ActionButton(title: "", symbol: "minus", enabled: rt != nil) { rt?.zoomOut() }
                    .accessibilityLabel("Zoom Out")
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity)
                ActionButton(title: "", symbol: "plus", enabled: rt != nil) { rt?.zoomIn() }
                    .accessibilityLabel("Zoom In")
            }
            ActionButton(title: "Actual Size", kind: .secondary, enabled: rt != nil && abs(zoom - 1) > 0.001) { rt?.resetZoom() }
            UtilityNote(text: "⌘+ and ⌘− zoom too. A Boost can keep a zoom for its site.")
        }
    }
}

// MARK: - Files

struct FilesUtility: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let items = Array(store.downloads.items.prefix(12))
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            UtilityHeading(text: "Downloads")
            if items.isEmpty {
                UtilityNote(text: "Files you download appear here.")
            } else {
                ForEach(items) { DownloadRow(item: $0) }
            }
            ActionButton(title: "Show All Downloads", kind: .quiet) { store.perform(.showDownloads, in: window) }
                .padding(.top, Metrics.Space.s)
        }
    }
}

// MARK: - Passwords

struct PasswordsUtility: View {
    let store: BrowserStore
    let window: WindowState
    @Local private var filled: UUID?
    @Environment(\.palette) private var palette

    var body: some View {
        let rt = store.currentRuntime(in: window)
        let logins = rt?.savedLogins ?? []
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            UtilityHeading(text: rt?.url?.host ?? "This page")
            if store.isIncognito {
                UtilityNote(text: "Private windows neither save nor fill passwords.")
            } else if rt?.loginFormOrigins.isEmpty ?? true {
                UtilityNote(text: "This page has no sign-in form Cosmos can see.")
            } else if logins.isEmpty {
                UtilityNote(text: "Cosmos has no password for this site. Sign in, and it offers to keep it.")
            } else {
                ForEach(logins) { login in
                    HStack(spacing: Metrics.Space.s) {
                        Image(systemName: "person.crop.circle").foregroundStyle(palette.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.username.isEmpty ? "No user name" : login.username).font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(palette.text).lineLimit(1)
                            Text(login.site).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        ActionButton(title: filled == login.id ? "Filled" : "Fill", symbol: filled == login.id ? "checkmark" : nil, kind: .secondary) {
                            Task { if await rt?.fill(login) == true { filled = login.id } }
                        }
                    }
                    .padding(.vertical, Metrics.Space.xs)
                }
            }
            ActionButton(title: "Manage Passwords", kind: .quiet) { store.onShowSettingsTab?(.passwords) }
                .padding(.top, Metrics.Space.s)
        }
        .onChange(of: rt?.url) { _, _ in filled = nil }
    }
}

// MARK: - Translate

/// Translation on this Mac (Apple's Translation, which downloads a language the first time it is used), of the text the
/// page has selected or anything typed in; or the whole page through Google Translate, which is told its address.
struct TranslateUtility: View {
    let store: BrowserStore
    let window: WindowState
    @Local private var text = ""
    @Local private var result = ""
    @Local private var target = Locale.current.language.languageCode?.identifier ?? "en"
    @Local private var failed = false
    @Local private var request = 0
    @Environment(\.palette) private var palette

    static let languages: [(code: String, name: String)] = ["en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl", "tr", "ar",
                                                            "hi", "id", "th", "vi", "ja", "ko", "zh"]
        .map { ($0, Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
        .sorted { $0.1 < $1.1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            UtilityHeading(text: "Into")
            Dropdown(selection: $target, options: Self.languages.map { Option(value: $0.code, label: $0.name) }, label: "Translate into")
            UtilityHeading(text: "Text")
            TextEditor(text: $text)
                .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                .frame(height: 110).padding(Metrics.Space.xs)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(palette.hover))
                .accessibilityLabel("Text to translate")
            HStack(spacing: Metrics.Space.s) {
                ActionButton(title: "Use Selection", kind: .secondary) { Task { await takeSelection() } }
                Spacer(minLength: 0)
                ActionButton(title: "Translate", kind: .primary, enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    failed = false
                    request += 1
                }
            }
            if !result.isEmpty {
                Text(result).font(.system(size: 13)).foregroundStyle(palette.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, Metrics.Space.xs)
                ActionButton(title: "Copy", symbol: "doc.on.doc", kind: .quiet) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                }
            }
            if failed { UtilityNote(text: "This Mac couldn't translate that. The language may need downloading in System Settings ▸ General ▸ Language & Region ▸ Translation Languages.") }
            UtilityNote(text: "Translated on this Mac: the text goes nowhere.")

            UtilityHeading(text: "Whole page")
            ActionButton(title: "Translate This Page", symbol: "globe", kind: .secondary, enabled: Self.googleTranslate(store.currentURL(in: window), into: target) != nil) {
                if let url = Self.googleTranslate(store.currentURL(in: window), into: target) { store.newTab(url: url, in: window) }
            }
            UtilityNote(text: "Opens the page in a new tab through Google Translate, which is sent the page's address.")
        }
        .modifier(TranslationRunner(text: text, target: target, request: request) { translated in
            if let translated { result = translated } else { failed = true }
        })
        .task { await takeSelection() }
    }

    private func takeSelection() async {
        guard let rt = store.currentRuntime(in: window),
              let selected = await rt.evaluate(returning: "String(getSelection())", in: .agent) as? String,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = String(selected.prefix(5_000))
    }

    /// The page through Google Translate's proxy (`<host with dashes>.translate.goog`), or nil for a page that is not on
    /// the public web.
    static func googleTranslate(_ url: URL?, into language: String) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host,
              !host.isEmpty, host.contains("."), !host.hasSuffix(".translate.goog") else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = host.replacingOccurrences(of: "-", with: "--").replacingOccurrences(of: ".", with: "-") + ".translate.goog"
        c.path = url.path.isEmpty ? "/" : url.path
        var items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        items += [URLQueryItem(name: "_x_tr_sl", value: "auto"), URLQueryItem(name: "_x_tr_tl", value: language),
                  URLQueryItem(name: "_x_tr_hl", value: language)]
        c.queryItems = items
        c.fragment = url.fragment
        return c.url
    }
}

/// Runs a translation each time `request` goes up (macOS 15 and later; earlier, it says it could not).
private struct TranslationRunner: ViewModifier {
    let text: String
    let target: String
    let request: Int
    let done: (String?) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(Runner(text: text, target: target, request: request, done: done))
        } else {
            content.onChange(of: request) { _, _ in done(nil) }
        }
    }

    @available(macOS 15.0, *)
    private struct Runner: ViewModifier {
        let text: String
        let target: String
        let request: Int
        let done: (String?) -> Void
        @Local private var configuration: TranslationSession.Configuration?

        func body(content: Content) -> some View {
            content
                .onChange(of: request) { _, _ in
                    let wanted = Locale.Language(identifier: target)
                    if configuration?.target == wanted { configuration?.invalidate() }
                    else { configuration = TranslationSession.Configuration(source: nil, target: wanted) }
                }
                .translationTask(configuration) { session in
                    do { done(try await session.translate(text).targetText) } catch { done(nil) }
                }
        }
    }
}
