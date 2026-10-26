import SwiftUI
import CosmosCore

/// Settings ▸ Radial Menu: whether a right click opens the ring, the sites where it stays out of the way, and what is on
/// the ring for each kind of thing you can click.
struct RadialPane: View {
    let store: BrowserStore
    @Local private var site = ""
    @Local private var problem: String?
    @Local private var context: RadialContext = .link
    @Local private var hovered: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var store = store
        let radial = store.settings.radialMenu
        Pane(title: "Radial Menu", subtitle: "A ring of actions where you right-click.", symbol: "chart.pie.fill") {
            SettingsGroup(note: "The ring holds what the system menu would offer for what is under the pointer: flick toward a slice, or click it. Hold ⌥ while you right-click for the system menu. A site that draws its own right-click menu keeps it, and VoiceOver always gets the system menu.") {
                SettingRow(title: "Radial menu on right click", detail: radial.enabled ? "On. Right-click a link, an image, some text or the page." : "Off. Right-click opens the system menu everywhere.", symbol: "chart.pie") {
                    SwitchControl(isOn: $store.settings.radialMenu.enabled, label: "Radial menu on right click")
                }
            }

            sites(radial)
                .opacity(radial.enabled ? 1 : 0.45)
                .disabled(!radial.enabled)

            customise(radial)
                .opacity(radial.enabled ? 1 : 0.45)
                .disabled(!radial.enabled)
        }
    }

    // MARK: Sites

    private func sites(_ radial: RadialSettings) -> some View {
        SettingsGroup(title: "Sites with the system menu", note: "Switch the ring off for a site, for example one whose own tools you use. It also covers the sites under it. You can do the same from a site's Site Controls.") {
            if radial.disabledHosts.isEmpty {
                SettingRow(title: "None", detail: "The ring opens on every site.", symbol: "circle.dashed") { EmptyView() }
            } else {
                DividedRows(items: radial.disabledHosts, id: \.self) { host in
                    SettingRow(title: host, symbol: "globe") {
                        IconButton(symbol: "xmark", label: "Use the radial menu on \(host) again") {
                            withAnimation(Motion.standard) { store.settings.radialMenu.enable(host: host) }
                        }
                    }
                }
            }
            Hairline()
            HStack(spacing: Metrics.Space.s) {
                FieldInput(text: $site, placeholder: "Site, e.g. docs.google.com", onSubmit: addSite)
                    .onChange(of: site) { problem = nil }
                ActionButton(title: "Turn Off", kind: .primary, enabled: !site.trimmingCharacters(in: .whitespaces).isEmpty, action: addSite)
            }
            .cardInset()
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(palette.negative)
                    .padding(.horizontal, Metrics.Space.l).padding(.bottom, Metrics.Space.m)
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: radial.disabledHosts)
        .animation(Motion.quick, value: problem)
    }

    private func addSite() {
        guard LinkRule.normalizedHost(site) != nil else {
            problem = "That isn't a site. Try something like github.com."
            return
        }
        var radial = store.settings.radialMenu
        let added = radial.disable(host: site)
        if added {
            withAnimation(Motion.standard) { store.settings.radialMenu = radial }
            store.haptics.levelChange()
        }
        problem = added ? nil : "The ring is already off there."
        if added { site = "" }
    }

    // MARK: Customising

    private func customise(_ radial: RadialSettings) -> some View {
        let actions = radial.ring(for: context)
        let overflow = actions.count > RadialLayout.maxSlices
        return SettingsGroup(title: "What is on the ring", note: "A ring holds eight slices. Actions beyond that, and anything else the system menu offers for what you clicked, wait under More. An action only shows up when the menu has it.") {
            SettingRow(title: "Edit the ring for") {
                Dropdown(selection: $context, options: RadialContext.allCases.map { Option(value: $0, label: $0.title) }, label: "Edit the ring for")
            }
            Hairline()
            HStack(alignment: .top, spacing: Metrics.Space.l) {
                RadialPreview(actions: actions, hovered: hovered)
                    .frame(width: RadialPreview.side, height: RadialPreview.side)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.Space.hair) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        row(action, at: index, count: actions.count)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .cardInset()
            .animation(Motion.standard, value: actions)
            Hairline()
            HStack(spacing: Metrics.Space.s) {
                Dropdown(selection: addBinding, options: radial.available(for: context).map { Option(value: Optional($0), label: $0.title) },
                         label: "Add an action", placeholder: "Add an action…", width: 220)
                    .disabled(radial.available(for: context).isEmpty)
                    .opacity(radial.available(for: context).isEmpty ? 0.4 : 1)
                Spacer(minLength: 0)
                if overflow {
                    Text("\(actions.count - RadialLayout.maxSlices + 1) under More").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
                ActionButton(title: "Reset to Default", symbol: "arrow.counterclockwise", kind: .secondary, enabled: radial.isCustomised(context)) {
                    withAnimation(Motion.standard) { store.settings.radialMenu.resetRing(for: context) }
                    store.haptics.levelChange()
                }
            }
            .cardInset()
        }
    }

    /// Picking from the "Add an action" list adds it; the list always shows its prompt again.
    private var addBinding: Binding<RadialAction?> {
        Binding(get: { nil }, set: { picked in
            guard let picked else { return }
            withAnimation(Motion.standard) { store.settings.radialMenu.add(picked, to: context) }
            store.haptics.levelChange()
        })
    }

    private func row(_ action: RadialAction, at index: Int, count: Int) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: action.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accentGlyph).frame(width: Metrics.Icon.row)
            Text(action.title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
            Spacer(minLength: 0)
            if index >= RadialLayout.maxSlices - 1 && count > RadialLayout.maxSlices {
                Text("More").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.tertiary)
            }
            IconButton(symbol: "chevron.up", label: "Move \(action.title) earlier") { move(index, -1) }
                .opacity(index == 0 ? 0.3 : 1).disabled(index == 0)
            IconButton(symbol: "chevron.down", label: "Move \(action.title) later") { move(index, 1) }
                .opacity(index == count - 1 ? 0.3 : 1).disabled(index == count - 1)
            IconButton(symbol: "xmark", label: "Take \(action.title) off the ring", destructive: true) {
                withAnimation(Motion.standard) { store.settings.radialMenu.remove(at: index, from: context) }
            }
            .opacity(count == 1 ? 0.3 : 1).disabled(count == 1)
        }
        .padding(.horizontal, Metrics.Space.s)
        .frame(height: Metrics.Height.row)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(hovered == index ? palette.hover : .clear))
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
    }

    private func move(_ index: Int, _ delta: Int) {
        withAnimation(Motion.standard) { store.settings.radialMenu.move(at: index, by: delta, in: context) }
        store.haptics.alignment()
        hovered = index + delta
    }
}

/// A small picture of the ring for the actions chosen, in the order they will sit. The slice for the row under the pointer
/// lights up.
struct RadialPreview: View {
    static let side: CGFloat = 148
    let actions: [RadialAction]
    var hovered: Int?
    @Environment(\.palette) private var palette

    /// What the ring would show: up to eight slices, the last one standing for the rest ("More") when there are too many.
    private var slices: [(symbol: String, lit: Bool)] {
        let over = actions.count > RadialLayout.maxSlices
        var out = actions.prefix(over ? RadialLayout.maxSlices - 1 : RadialLayout.maxSlices).enumerated().map { ($0.element.symbol, hovered == $0.offset) }
        if over { out.append(("ellipsis", (hovered ?? 0) >= RadialLayout.maxSlices - 1)) }
        return out
    }

    var body: some View {
        let slices = slices
        let count = slices.count
        let inner = 24.0, outer = Self.side / 2 - 2
        let width = RadialGeometry.sliceAngle(count: count)
        let middle = (inner + outer) / 2
        ZStack {
            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                let centre = RadialGeometry.centerAngle(of: index, count: count)
                let sector = AnnularSector(startAngle: centre - width / 2 + 0.04, endAngle: centre + width / 2 - 0.04, innerRadius: inner, outerRadius: outer)
                sector.fill(slice.lit ? palette.accentFill : palette.hover)
                    .overlay(sector.stroke(palette.stroke, lineWidth: 0.8))
                let at = RadialGeometry.offset(of: index, count: count, radius: middle)
                Image(systemName: slice.symbol).font(.system(size: count > 6 ? 11 : 13, weight: .semibold))
                    .foregroundStyle(slice.lit ? palette.onAccent : palette.text)
                    .offset(x: at.x, y: at.y)
            }
            Circle().fill(palette.hover).overlay(Circle().strokeBorder(palette.stroke, lineWidth: 0.8)).frame(width: (inner - 3) * 2, height: (inner - 3) * 2)
        }
        .animation(Motion.quick, value: hovered)
    }
}
