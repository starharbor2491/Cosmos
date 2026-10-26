import SwiftUI
import AppKit
import CosmosCore

/// Edit a space: name, icon, profile and the whole look (gradient stops, angle, grain, stars).
struct ThemeEditorPanel: View {
    let store: BrowserStore
    let window: WindowState
    let spaceID: UUID
    @Environment(\.palette) private var palette
    @Local private var confirmDelete = false

    private var space: Space? { store.workspace.space(spaceID) }

    var body: some View {
        if let space {
            PanelFrame(title: "Edit Space", symbol: "paintpalette.fill", width: 560, height: 640, close: { window.overlay = nil }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        preview(space)
                        nameAndIcon(space)
                        presets(space)
                        gradient(space)
                        sliders(space)
                        profile(space)
                        footer(space)
                    }
                    .padding(18)
                }
            }
        } else {
            EmptyView()
        }
    }

    // MARK: Sections

    private func preview(_ space: Space) -> some View {
        ZStack(alignment: .bottomLeading) {
            ThemeBackground(theme: space.theme, animated: false)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous))
            HStack(spacing: 8) {
                SpaceIconView(icon: space.icon, size: 15)
                Text(space.title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Palette(theme: space.theme).text)
            .padding(14)
        }
        .frame(height: 118)
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.6))
    }

    private func nameAndIcon(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Name", systemImage: "textformat").sectionLabel(palette)
            TextField("Space name", text: Binding(get: { space.title }, set: { v in store.updateSpace(spaceID) { $0.title = v } }))
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
            Label("Icon", systemImage: "face.smiling").sectionLabel(palette).padding(.top, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                ForEach(Array(SpaceIcon.suggested.enumerated()), id: \.offset) { _, icon in
                    Button { store.updateSpace(spaceID) { $0.icon = icon } } label: {
                        SpaceIconView(icon: icon, size: 16)
                            .frame(width: 38, height: 34)
                            .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(icon == space.icon ? palette.accent.opacity(0.3) : palette.hover))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).strokeBorder(icon == space.icon ? palette.accent : .clear, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func presets(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Themes", systemImage: "sparkles").sectionLabel(palette)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(SpaceTheme.presets, id: \.name) { preset in
                    Button { store.updateSpace(spaceID) { $0.theme = preset } } label: {
                        VStack(spacing: 4) {
                            ThemeBackground(theme: preset, animated: false)
                                .frame(height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                                    .strokeBorder(space.theme.name == preset.name ? palette.accent : palette.stroke, lineWidth: space.theme.name == preset.name ? 2 : 0.6))
                            Text(preset.name).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func gradient(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Colors", systemImage: "circle.hexagongrid.fill").sectionLabel(palette)
                Spacer()
                Button { store.updateSpace(spaceID) { s in if s.theme.colors.count < 4 { s.theme.colors.append(s.theme.colors.last ?? RGBA(hex: 0x7B2D8E)); s.theme.name = "Custom" } } } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(palette.secondary).disabled(space.theme.colors.count >= 4).help("Add a colour stop")
            }
            HStack(spacing: 12) {
                ForEach(Array(space.theme.colors.enumerated()), id: \.offset) { index, color in
                    VStack(spacing: 4) {
                        ColorPicker("", selection: Binding(
                            get: { Color(color) },
                            set: { new in
                                if let rgba = new.rgba { store.updateSpace(spaceID) { $0.theme.colors[index] = rgba; $0.theme.name = "Custom" } }
                            }), supportsOpacity: false)
                            .labelsHidden()
                        if space.theme.colors.count > 1 {
                            Button { store.updateSpace(spaceID) { $0.theme.colors.remove(at: index); $0.theme.name = "Custom" } } label: {
                                Image(systemName: "minus.circle").font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundStyle(palette.tertiary)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func sliders(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ThemeSlider(title: "Angle", value: Binding(get: { space.theme.angle }, set: { v in update { $0.angle = v } }), range: 0...360, format: { "\(Int($0))°" })
            ThemeSlider(title: "Intensity", value: Binding(get: { space.theme.intensity }, set: { v in update { $0.intensity = v } }), range: 0.2...1)
            ThemeSlider(title: "Grain", value: Binding(get: { space.theme.grain }, set: { v in update { $0.grain = v } }), range: 0...1)
            ThemeSlider(title: "Stars", value: Binding(get: { space.theme.starfield }, set: { v in update { $0.starfield = v } }), range: 0...1)
            HStack {
                Text("Appearance").font(.system(size: 12.5)).foregroundStyle(palette.secondary).frame(width: 84, alignment: .leading)
                Picker("", selection: Binding(get: { space.theme.appearance }, set: { v in update { $0.appearance = v } })) {
                    Text("Auto").tag(Appearance.automatic)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
        }
    }

    private func update(_ change: @escaping (inout SpaceTheme) -> Void) {
        store.updateSpace(spaceID) { change(&$0.theme); $0.theme.name = "Custom" }
    }

    private func profile(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Profile", systemImage: "person.crop.circle").sectionLabel(palette)
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { space.profileID }, set: { store.changeProfile(ofSpace: spaceID, to: $0) })) {
                    ForEach(store.workspace.profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 200)
                Button("New Profile…") { promptNewProfile() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent)
            }
            Text("Spaces that share a profile share logins and cookies. Give a space its own profile to stay signed in to two accounts at once.")
                .font(.system(size: 11.5)).foregroundStyle(palette.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ space: Space) -> some View {
        HStack {
            if store.workspace.spaces.count > 1 {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Space", systemImage: "trash") }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.red.opacity(0.9))
                    .confirmationDialog("Delete “\(space.title)”?", isPresented: $confirmDelete) {
                        Button("Delete Space and Its Tabs", role: .destructive) { window.overlay = nil; store.deleteSpace(spaceID, in: window) }
                    } message: { Text("Its tabs move to the archive.") }
            }
            Spacer()
            Button("Done") { window.overlay = nil }
                .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(palette.accent.opacity(0.9))).foregroundStyle(.white)
                .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func promptNewProfile() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "A profile keeps its own logins and cookies."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let id = store.addProfile(named: name)
        store.changeProfile(ofSpace: spaceID, to: id)
    }
}

private struct ThemeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int($0 * 100))%" }
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(palette.secondary).frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range).tint(palette.accent)
            Text(format(value)).font(.system(size: 11.5, design: .rounded)).foregroundStyle(palette.tertiary).frame(width: 40, alignment: .trailing)
        }
    }
}

extension View {
    func sectionLabel(_ palette: Palette) -> some View {
        self.font(.system(size: 12, weight: .bold)).foregroundStyle(palette.secondary).labelStyle(.titleAndIcon)
    }
}

extension Color {
    /// The colour as sRGB components, or nil when it can't be converted.
    var rgba: RGBA? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}
