import SwiftUI
import CosmosCore
import CosmosEngine

/// Settings ▸ Engine: the Chromium Cosmos runs, and Chromium's own settings, folded into Cosmos's. They are written into
/// Chromium's settings files as Chromium starts and as a profile opens.
struct EnginePane: View {
    let store: BrowserStore
    /// The settings the engine started with, to say when a change is waiting for a restart.
    @Local private var started: EngineSettings?
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var store = store
        let engine = store.engine
        Pane(title: "Engine", subtitle: "\(engine.name) draws every page. Its settings live here.", symbol: "cpu.fill") {
            SettingsGroup(title: engine.name, note: "Cosmos runs Chromium's stable release, built into Cosmos through CEF (the Chromium Embedded Framework) and drawn in Cosmos's own windows. A newer Chromium comes with each Cosmos update.") {
                SettingRow(title: "Version", detail: engine.versionDescription ?? statusText(store.engineStatus), symbol: "shippingbox") { EmptyView() }
            }

            SettingsGroup(title: "Privacy and security") {
                SettingRow(title: "Cookies", detail: "Third-party cookies let sites follow you from one site to the next.", symbol: "lock.shield") {
                    Dropdown(selection: $store.settings.engine.cookies, options: [
                        Option(value: .allowAll, label: "Allow all"),
                        Option(value: .blockThirdPartyInPrivate, label: "Block third-party in Incognito"),
                        Option(value: .blockThirdParty, label: "Block third-party"),
                    ])
                }
                Hairline()
                SettingRow(title: "Ask sites not to track you", detail: "Sends “Do Not Track” with every request. Most sites ignore it.", symbol: "eye.slash") {
                    SwitchControl(isOn: $store.settings.engine.doNotTrack)
                }
                Hairline()
                SettingRow(title: "Preload pages", detail: "Fetches pages you are likely to open next, so they open sooner.", symbol: "bolt") {
                    SwitchControl(isOn: $store.settings.engine.preloadPages)
                }
                Hairline()
                SettingRow(title: "Warn about dangerous sites", detail: "Stops pages from sites on public malware and phishing lists (URLhaus, OpenPhish, PhishTank), checked on this Mac; the lists are fetched twice a day.", symbol: "exclamationmark.shield") {
                    SwitchControl(isOn: $store.settings.warnAboutDangerousSites)
                }
                Hairline()
                SettingRow(title: "Always use secure connections", detail: "Tries HTTPS first and warns before a site that has none.", symbol: "lock") {
                    SwitchControl(isOn: $store.settings.engine.httpsFirst)
                }
                Hairline()
                SettingRow(title: "Secure DNS", detail: "Looks addresses up over an encrypted connection.", symbol: "network.badge.shield.half.filled") {
                    SegmentedControl(selection: $store.settings.engine.secureDNS, options: [
                        Option(value: .off, label: "Off"), Option(value: .automatic, label: "Automatic"), Option(value: .secure, label: "Custom"),
                    ])
                }
                if store.settings.engine.secureDNS == .secure {
                    Hairline()
                    SettingRow(title: "DNS server", detail: "A DNS-over-HTTPS address. Empty uses your provider's, when it has one.") {
                        FieldInput(text: $store.settings.engine.secureDNSTemplate, placeholder: "https://dns.example/dns-query", width: 250)
                    }
                }
                Hairline()
                SettingRow(title: "WebRTC", detail: "Which of your addresses calls and video chats may use.", symbol: "video") {
                    Dropdown(selection: $store.settings.engine.webRTC, options: [
                        Option(value: .standard, label: "Any"),
                        Option(value: .publicInterfaceOnly, label: "Public address only"),
                        Option(value: .disableNonProxiedUDP, label: "Through a proxy only"),
                    ])
                }
            }

            SettingsGroup(title: "What sites may do", note: "A site you answered for keeps your answer; these are for sites that have not asked yet.") {
                SettingRow(title: "JavaScript", symbol: "curlybraces") { SwitchControl(isOn: $store.settings.engine.javaScript) }
                Hairline()
                SettingRow(title: "Images", symbol: "photo") { SwitchControl(isOn: $store.settings.engine.images) }
                Hairline()
                SettingRow(title: "Pop-up windows", detail: "Windows a site opens without your click.", symbol: "macwindow.on.rectangle") {
                    SwitchControl(isOn: $store.settings.engine.popups)
                }
                Hairline()
                SettingRow(title: "Sound", symbol: "speaker.wave.2") { SwitchControl(isOn: $store.settings.engine.sound) }
                ForEach(askRows, id: \.title) { row in
                    Hairline()
                    SettingRow(title: row.title, symbol: row.symbol) {
                        SegmentedControl(selection: row.binding, options: [Option(value: .ask, label: "Ask"), Option(value: .block, label: "Block")])
                    }
                }
            }

            SettingsGroup(title: "Fonts") {
                SettingRow(title: "Font size", detail: "The size of text on pages that leave it to you.", symbol: "textformat.size") {
                    Dropdown(selection: $store.settings.engine.defaultFontSize, options: [9, 10, 12, 14, 16, 18, 20, 24, 28].map { Option(value: $0, label: "\($0) pt") }, width: 120)
                }
                Hairline()
                SettingRow(title: "Smallest text", detail: "Pages can't make text smaller than this.", symbol: "textformat.size.smaller") {
                    Dropdown(selection: $store.settings.engine.minimumFontSize, options: [0, 9, 10, 11, 12, 14, 16, 18, 20, 24].map { Option(value: $0, label: $0 == 0 ? "Any" : "\($0) pt") }, width: 120)
                }
                Hairline()
                SettingRow(title: "Standard font", detail: "Empty: Chromium's own choice.", symbol: "textformat") {
                    FieldInput(text: $store.settings.engine.standardFont, placeholder: "Times", width: 180)
                }
                Hairline()
                SettingRow(title: "Fixed-width font", symbol: "chevron.left.forwardslash.chevron.right") {
                    FieldInput(text: $store.settings.engine.fixedFont, placeholder: "Menlo", width: 180)
                }
            }

            SettingsGroup(title: "System") {
                SettingRow(title: "Languages", detail: "What pages are asked for, in order, separated by commas. Empty: your Mac's languages.", symbol: "globe") {
                    FieldInput(text: Binding(get: { store.settings.engine.languages.joined(separator: ", ") },
                                             set: { store.settings.engine.languages = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                               placeholder: "en-US, fr", width: 180)
                }
                Hairline()
                SettingRow(title: "Use the graphics processor", detail: "Draws pages with the GPU. Turn off only if pages draw wrongly.", symbol: "cpu") {
                    SwitchControl(isOn: $store.settings.engine.hardwareAcceleration)
                }
            }

            if let started, started != store.settings.engine {
                SettingsGroup {
                    SettingRow(title: "Restart the engine to use these settings", detail: "Open tabs reload.", symbol: "arrow.clockwise") {
                        ActionButton(title: "Restart Engine", kind: .primary) {
                            store.restartEngine()
                            self.started = store.settings.engine
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .onAppear { if started == nil { started = store.settings.engine } }
        .animation(Motion.standard, value: store.settings.engine)
    }

    private struct AskRow { let title: String; let symbol: String; let binding: Binding<EngineSettings.Ask> }

    private var askRows: [AskRow] {
        @Bindable var store = store
        return [
            AskRow(title: "Several downloads at once", symbol: "arrow.down.circle", binding: $store.settings.engine.automaticDownloads),
            AskRow(title: "Notifications", symbol: "bell", binding: $store.settings.engine.notifications),
            AskRow(title: "Location", symbol: "location", binding: $store.settings.engine.location),
            AskRow(title: "Camera", symbol: "camera", binding: $store.settings.engine.camera),
            AskRow(title: "Microphone", symbol: "mic", binding: $store.settings.engine.microphone),
            AskRow(title: "Clipboard", symbol: "doc.on.clipboard", binding: $store.settings.engine.clipboard),
        ]
    }

    private func statusText(_ status: EngineStatus) -> String {
        switch status {
        case .preparing(let what, let progress): progress.map { "\(what) (\(Int($0 * 100))%)" } ?? what
        case .ready(let version): version
        case .failed(let why): why
        }
    }
}
