import SwiftUI
import AppKit
import CosmosCore

/// Boosts: per-site colour, font, zoom, hidden elements, CSS and JavaScript (Arc's Boosts).
struct BoostsPanel: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var selectedID: UUID?
    @Local private var tab: Tab = .colors

    enum Tab: String, CaseIterable, Identifiable {
        case colors = "Colors", font = "Font", zap = "Zap", css = "CSS", code = "JS"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .colors: return "paintpalette"
            case .font: return "textformat"
            case .zap: return "bolt"
            case .css: return "curlybraces"
            case .code: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    private var currentHost: String? {
        guard let host = store.currentURL(in: window)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        PanelFrame(title: "Boosts", symbol: "wand.and.stars", width: 840, height: 600, close: { window.overlay = nil }) {
            HStack(spacing: 0) {
                sidebar.frame(width: 232)
                Rectangle().fill(palette.stroke).frame(width: 0.5)
                editor
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = store.boostForCurrentPageIfExists(in: window) ?? store.boosts.boosts.first?.id }
        }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let host = currentHost {
                Button {
                    selectedID = store.boostForCurrentPage(in: window)
                } label: {
                    Label("Boost \(host)", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.accentFill))
                        .foregroundStyle(palette.onAccent)
                }
                .buttonStyle(.plain)
                .padding(12)
            } else {
                Button {
                    let b = Boost(name: "New Boost", hostPatterns: ["example.com"])
                    store.boosts.boosts.append(b); selectedID = b.id
                } label: {
                    Label("New Boost", systemImage: "plus").font(.system(size: 12.5, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.accentFill)).foregroundStyle(palette.onAccent)
                }
                .buttonStyle(.plain).padding(12)
            }
            if store.boosts.boosts.isEmpty {
                EmptyPanelMessage(symbol: "wand.and.stars", title: "No Boosts yet", detail: "Boost a site to recolour it, change its font, hide parts of it or run your own CSS and JavaScript.")
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.boosts.boosts) { b in
                            BoostListRow(boost: b, selected: b.id == selectedID, matchesCurrent: currentHost.map { b.matches(host: $0) } ?? false)
                                .onTapGesture { selectedID = b.id }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        if let id = selectedID, let index = store.boosts.boosts.firstIndex(where: { $0.id == id }) {
            let binding = Binding<Boost>(
                get: { store.boosts.boosts.indices.contains(index) ? store.boosts.boosts[index] : Boost(name: "", hostPatterns: []) },
                set: { new in
                    guard store.boosts.boosts.indices.contains(index) else { return }
                    var n = new; n.updatedAt = Date()
                    store.boosts.boosts[index] = n
                    store.applyBoostLive(n)
                })
            VStack(spacing: 0) {
                header(binding)
                Rectangle().fill(palette.stroke).frame(height: 0.5)
                HStack(spacing: 4) {
                    ForEach(Tab.allCases) { t in
                        Button { tab = t } label: {
                            Label(t.rawValue, systemImage: t.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(tab == t ? palette.accent.opacity(0.3) : .clear))
                                .foregroundStyle(tab == t ? palette.text : palette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                ScrollView {
                    Group {
                        switch tab {
                        case .colors: ColorsTab(boost: binding)
                        case .font: FontTab(boost: binding)
                        case .zap: ZapTab(store: store, window: window, boost: binding)
                        case .css: CodeTab(text: binding.css, prompt: "/* CSS applied to matching pages */", note: "Applies instantly.")
                        case .code: CodeTab(text: binding.js, prompt: "// JavaScript run on matching pages", note: "Runs when a page loads: reload to see changes.")
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            EmptyPanelMessage(symbol: "wand.and.stars", title: "Pick a Boost", detail: "Choose one from the list, or boost the site you're on.")
        }
    }

    private func header(_ boost: Binding<Boost>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PromptTextField(text: boost.name, prompt: "Name")
                    .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.text)
                Toggle("", isOn: boost.isEnabled).toggleStyle(.switch).labelsHidden().tint(palette.accent)
                Button(role: .destructive) {
                    let b = boost.wrappedValue
                    store.removeBoostLive(b)
                    store.boosts.boosts.removeAll { $0.id == b.id }
                    selectedID = store.boosts.boosts.first?.id
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(palette.secondary).help("Delete Boost")
            }
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(palette.tertiary)
                PromptTextField(text: Binding(
                    get: { boost.wrappedValue.hostPatterns.joined(separator: ", ") },
                    set: { boost.wrappedValue.hostPatterns = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                                prompt: "example.com, *.example.org")
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(palette.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct BoostListRow: View {
    let boost: Boost
    let selected: Bool
    let matchesCurrent: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(boost.isEnabled ? palette.accent : palette.tertiary).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(boost.name).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                Text(boost.hostPatterns.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(palette.tertiary).lineLimit(1)
            }
            Spacer()
            if matchesCurrent { Image(systemName: "eye.fill").font(.system(size: 10)).foregroundStyle(palette.accentGlyph).help("Applies to the page you're on") }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(selected ? palette.selected : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Tabs

private struct ColorsTab: View {
    @Binding var boost: Boost
    @Environment(\.palette) private var palette

    private var filter: ColorFilter { boost.colorFilter ?? ColorFilter() }
    private func set(_ change: (inout ColorFilter) -> Void) {
        var f = filter
        change(&f)
        boost.colorFilter = f.isIdentity ? nil : f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BoostSlider(title: "Hue", value: Binding(get: { filter.hue }, set: { v in set { $0.hue = v } }), range: -180...180, format: { "\(Int($0))°" })
            BoostSlider(title: "Saturation", value: Binding(get: { filter.saturation }, set: { v in set { $0.saturation = v } }), range: 0...2)
            BoostSlider(title: "Brightness", value: Binding(get: { filter.brightness }, set: { v in set { $0.brightness = v } }), range: 0.4...1.6)
            BoostSlider(title: "Contrast", value: Binding(get: { filter.contrast }, set: { v in set { $0.contrast = v } }), range: 0.5...1.6)
            Toggle(isOn: Binding(get: { filter.invert }, set: { v in set { $0.invert = v } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dark mode for this site").font(.system(size: 13, weight: .medium))
                    Text("Inverts the page and flips pictures back so they look natural.").font(.system(size: 11.5)).foregroundStyle(palette.secondary)
                }
            }
            .toggleStyle(.switch).tint(palette.accent)
            BoostSlider(title: "Zoom", value: Binding(get: { boost.zoom ?? 1 }, set: { boost.zoom = abs($0 - 1) < 0.01 ? nil : $0 }), range: 0.5...2.5)
            Button("Reset Colors") { boost.colorFilter = nil }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accentText)
                .disabled(boost.colorFilter == nil)
        }
        .foregroundStyle(palette.text)
    }
}

private struct BoostSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(palette.secondary).frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range).tint(palette.accent)
            Text(format(value)).font(.system(size: 11.5, design: .rounded)).foregroundStyle(palette.tertiary).frame(width: 44, alignment: .trailing)
        }
    }
}

private struct FontTab: View {
    @Binding var boost: Boost
    @Environment(\.palette) private var palette
    private static let families: [String] = {
        let all = NSFontManager.shared.availableFontFamilies
        let favourites = ["Helvetica Neue", "Georgia", "Avenir Next", "Menlo", "SF Mono", "Palatino", "Optima", "Futura", "Gill Sans", "Baskerville", "American Typewriter", "Charter"]
        return favourites.filter(all.contains) + all.filter { !favourites.contains($0) }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Font").font(.system(size: 12.5)).foregroundStyle(palette.secondary).frame(width: 84, alignment: .leading)
                Picker("", selection: Binding(get: { boost.fontFamily ?? "" }, set: { boost.fontFamily = $0.isEmpty ? nil : $0 })) {
                    Text("Site default").tag("")
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 260)
            }
            if let family = boost.fontFamily {
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.custom(family, size: 20)).foregroundStyle(palette.text)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
            }
            Text("Code blocks and icon fonts keep their own typefaces.").font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
        }
    }
}

private struct ZapTab: View {
    let store: BrowserStore
    let window: WindowState
    @Binding var boost: Boost
    @Environment(\.palette) private var palette
    @Local private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zap hides parts of a page for good: banners, sidebars, recommendations, anything you'd rather not see.")
                .font(.system(size: 12.5)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Button { startPicking() } label: {
                Label(picking ? "Click an element on the page… (Esc to cancel)" : "Pick an Element to Zap", systemImage: "scope")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(palette.accentFill.opacity(picking ? 0.5 : 1)))
                    .foregroundStyle(palette.onAccent)
            }
            .buttonStyle(.plain).disabled(picking || store.currentRuntime(in: window) == nil)
            if boost.zapSelectors.isEmpty {
                Text("Nothing zapped yet.").font(.system(size: 12.5)).foregroundStyle(palette.tertiary)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(boost.zapSelectors.enumerated()), id: \.offset) { index, selector in
                        HStack {
                            Text(selector).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.text).lineLimit(2)
                            Spacer()
                            Button { boost.zapSelectors.remove(at: index) } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.plain).foregroundStyle(palette.secondary).help("Bring it back")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(palette.hover))
                    }
                }
            }
        }
    }

    private func startPicking() {
        guard let rt = store.currentRuntime(in: window) else { return }
        picking = true
        // Peek at the page: the panel stays up but the page gets the clicks.
        window.overlay = nil
        rt.pickElement { selector in
            picking = false
            if let selector, !selector.isEmpty, !boost.zapSelectors.contains(selector) { boost.zapSelectors.append(selector) }
            window.overlay = .boosts
        }
    }
}

private struct CodeTab: View {
    @Binding var text: String
    let prompt: String
    let note: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(palette.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
            Text(note).font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
        }
    }
}

extension BrowserStore {
    /// The Boost already made for the page in front, if any.
    func boostForCurrentPageIfExists(in window: WindowState) -> UUID? {
        guard let host = currentURL(in: window)?.host else { return nil }
        return boosts.boosts.first { $0.matches(host: host) }?.id
    }
}
