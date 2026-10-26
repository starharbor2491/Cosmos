import SwiftUI
import CosmosCore

/// The menu-bar browser: a row of controls over the page, on the current space's sky.
struct MenuBarBrowserView: View {
    let store: BrowserStore
    let session: MenuBarSession
    @Local private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        let theme = store.currentTheme
        let palette = Palette(theme: theme)
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous)
        ZStack {
            ThemeBackground(theme: theme, animated: false)
            VStack(spacing: 0) {
                if let runtime = session.runtime {
                    toolbar(runtime, palette)
                    RuntimeWebHost(runtime: runtime)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous))
                        .padding(EdgeInsets(top: 0, leading: Metrics.Space.s, bottom: Metrics.Space.s, trailing: Metrics.Space.s))
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.8))
        .environment(\.palette, palette)
        .environment(\.haptics, store.haptics)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .background(shortcuts)
    }

    // MARK: Toolbar

    private func toolbar(_ runtime: TabRuntime, _ palette: Palette) -> some View {
        HStack(spacing: Metrics.Space.xs) {
            ToolbarButton(symbol: "chevron.left", enabled: runtime.canGoBack, help: "Back") { runtime.goBack() }
            ToolbarButton(symbol: "chevron.right", enabled: runtime.canGoForward, help: "Forward") { runtime.goForward() }
            ToolbarButton(symbol: runtime.isLoading ? "xmark" : "arrow.clockwise", help: runtime.isLoading ? "Stop" : "Reload") {
                if runtime.isLoading { runtime.webView.stopLoading() } else { runtime.reload() }
            }
            address(runtime, palette)
            ToolbarButton(symbol: session.isPinned ? "pin.fill" : "pin", help: session.isPinned ? "Let it close when you click away" : "Keep it open") {
                session.isPinned.toggle()
                store.haptics.alignment()
            }
            ToolbarButton(symbol: "arrow.up.right.square", enabled: runtime.url != nil, help: "Open in Cosmos") {
                if let url = runtime.url { session.onOpenInCosmos(url) }
            }
        }
        .padding(.horizontal, Metrics.Space.s)
        .frame(height: Metrics.Height.bar)
        .overlay(alignment: .bottom) { loadingLine(runtime, palette) }
    }

    private func address(_ runtime: TabRuntime, _ palette: Palette) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        return HStack(spacing: Metrics.Space.s) {
            FaviconView(store: store, url: runtime.url, size: 16)
            PromptTextField(text: $text, prompt: "Search or enter address")
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text)
                .focused($typing)
                .onSubmit { session.go(text); typing = false }
                .onKeyPress(.escape) {
                    guard typing else { return .ignored }
                    typing = false
                    text = Self.shown(runtime.url)
                    return .handled
                }
        }
        .padding(.horizontal, Metrics.Space.m)
        .frame(height: Metrics.Control.height)
        .background(shape.fill(typing ? palette.hoverStrong : palette.hover))
        .overlay(shape.strokeBorder(typing ? palette.accent.opacity(0.8) : palette.stroke, lineWidth: typing ? 1.2 : 0.8))
        .animation(Motion.quick, value: typing)
        .onAppear { text = Self.shown(runtime.url) }
        .onChange(of: runtime.url) { if !typing { text = Self.shown(runtime.url) } }
        .onChange(of: typing) {
            // Typing starts from the whole address, selected for replacing by ⌘A; leaving it shows the site again.
            text = typing ? (runtime.url?.absoluteString ?? "") : Self.shown(runtime.url)
        }
        .onChange(of: session.addressFocusRequests) { typing = true }
    }

    private static func shown(_ url: URL?) -> String { URLInput.hostForDisplay(url) }

    /// A thin line along the toolbar's lower edge while the page loads.
    private func loadingLine(_ runtime: TabRuntime, _ palette: Palette) -> some View {
        GeometryReader { bar in
            Rectangle().fill(palette.accent)
                .frame(width: bar.size.width * max(0.04, runtime.progress), height: 2)
                .opacity(runtime.isLoading ? 1 : 0)
                .animation(Motion.quick, value: runtime.progress)
                .animation(Motion.standard, value: runtime.isLoading)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    // MARK: Keys

    /// The panel's own keys, taken before the browser's menu can aim them at a browser window (⌘W would close its tab).
    private var shortcuts: some View {
        Group {
            Button("Close") { session.onHide() }.keyboardShortcut("w")
            Button("Address") { typing = true }.keyboardShortcut("l")
            Button("Reload") { session.runtime?.reload() }.keyboardShortcut("r")
            Button("Back") { session.runtime?.goBack() }.keyboardShortcut("[")
            Button("Forward") { session.runtime?.goForward() }.keyboardShortcut("]")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
