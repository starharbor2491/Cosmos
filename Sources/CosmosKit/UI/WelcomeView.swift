import SwiftUI
import AppKit
import CosmosCore

/// First-run screen: say hello, bring Arc (or another browser) along, optionally become the default browser.
struct WelcomeView: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var sources: [ImportSource] = []
    @Local private var loaded = false
    @Local private var running: String?
    @Local private var results: [String: String] = [:]
    @Local private var failures: [String: String] = [:]
    @Local private var defaultSet = DefaultBrowser.isDefault

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                CosmosLogo(size: 92)
                Text("Welcome to Cosmos").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(palette.text)
                Text("A browser made for people who miss Arc.\nSpaces, a sidebar, Boosts, Peek and Split View all come with you.")
                    .font(.system(size: 13.5)).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 30).padding(.bottom, 18)

            VStack(spacing: 8) {
                if !loaded {
                    ProgressView().controlSize(.small).padding(.vertical, 14)
                } else if sources.isEmpty {
                    Text("No other browsers found on this Mac. You can import later from the Cosmos menu.")
                        .font(.system(size: 12.5)).foregroundStyle(palette.tertiary).padding(.vertical, 14)
                }
                ForEach(sources) { source in
                    ImportRow(source: source, running: running == source.id, result: results[source.id], failure: failures[source.id]) {
                        run(source)
                    }
                    .disabled(running != nil)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                Button { DefaultBrowser.request { ok in defaultSet = ok || DefaultBrowser.isDefault } } label: {
                    Label(defaultSet ? "Cosmos is your default browser" : "Make Cosmos my default browser", systemImage: defaultSet ? "checkmark.circle.fill" : "safari")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(defaultSet ? palette.accent : palette.secondary)
                .disabled(defaultSet)

                Button { finish() } label: {
                    Text(results.isEmpty ? "Start Fresh" : "Start Exploring")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 220).padding(.vertical, 9)
                        .background(Capsule().fill(palette.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.bottom, 26)
        }
        .frame(width: 560, height: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous))
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
        .shadow(color: palette.shadow, radius: 40, y: 16)
        .task { sources = await ImportCoordinator.sources(for: store); loaded = true }
    }

    private func run(_ source: ImportSource) {
        running = source.id
        failures[source.id] = nil
        Task { @MainActor in
            do {
                let outcome = try await source.run(store, window)
                results[source.id] = outcome.summary
            } catch is CancellationError {
            } catch {
                failures[source.id] = error.localizedDescription
            }
            running = nil
        }
    }

    private func finish() {
        store.settings.hasCompletedOnboarding = true
        window.overlay = nil
        if window.selectedItemID == nil { window.overlay = .commandBar(.newTab) }
    }
}

private struct ImportRow: View {
    let source: ImportSource
    let running: Bool
    let result: String?
    let failure: String?
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.text)
                Text(result ?? failure ?? source.detail)
                    .font(.system(size: 12)).foregroundStyle(failure != nil ? Color.red.opacity(0.9) : palette.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if running {
                ProgressView().controlSize(.small)
            } else if result != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent).font(.system(size: 18))
            } else {
                Button(action: action) {
                    Text(source.isAvailable ? "Import" : "Choose…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(palette.hover.opacity(1.8)))
                        .foregroundStyle(palette.text)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).fill(palette.hover))
    }
}
