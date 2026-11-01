import SwiftUI
import AppKit
import CosmosCore

/// A small Cosmos window for trying the three moves on: ⌘T drops a Command Bar into it (type to find a tab, Return to
/// open it), two fingers across it carry its sidebar to the other space (the sky following the fingers, as the real one
/// does), ⌘S hides its sidebar. Its spaces and tabs are its own, made up: nothing of the person's is tried on.
struct MiniBrowser: View {
    let model: OnboardingModel
    private let sidebarWidth: CGFloat = 190

    var body: some View {
        let skies = [model.sky, companion]
        let titles = [model.spaceTitle, "Work"]
        let symbols = ["house.fill", "briefcase.fill"]
        let current = model.demoSpace, other = 1 - model.demoSpace
        let drag = max(-sidebarWidth, min(sidebarWidth, model.demoDrag))
        let mix = Double(abs(drag) / sidebarWidth)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let shown = model.demoOpened ?? OnboardingModel.practiceTabs[current][0].title
        ZStack(alignment: .top) {
            ThemeBackground(theme: skies[current], animated: false)
                .id(current)
                .transition(.opacity)
            ThemeBackground(theme: skies[other], animated: false)
                .opacity(mix)
            HStack(spacing: 0) {
                if model.demoSidebar {
                    ZStack {
                        MiniSidebar(title: titles[current], symbol: symbols[current], tabs: OnboardingModel.practiceTabs[current],
                                    selected: shown, index: current)
                            .offset(x: drag)
                            .id(current)
                            .transition(.push(from: model.demoDirection > 0 ? .trailing : .leading))
                        if drag != 0 {
                            MiniSidebar(title: titles[other], symbol: symbols[other], tabs: OnboardingModel.practiceTabs[other],
                                        selected: OnboardingModel.practiceTabs[other][0].title, index: other)
                                .offset(x: drag + (drag < 0 ? sidebarWidth : -sidebarWidth))
                        }
                    }
                    .frame(width: sidebarWidth)
                    .clipped()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                MiniPage(title: shown)
                    .id(shown)
                    .transition(.opacity)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, model.demoSidebar ? 0 : 8)
            }
            // The window is the height it is given; what does not fit is cut off at its edge, never pushed past it.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
            if model.demoBarOpen {
                // The page steps back while the Command Bar is up, as in a real window.
                Color.black.opacity(0.16)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                // Across the page, as the real one sits across the window (nothing of the page shows beside it), under
                // the page's heading, so what is open stays in view.
                MiniCommandBar(model: model)
                    .padding(.leading, model.demoSidebar ? sidebarWidth + 18 : 26)
                    .padding(.trailing, 26)
                    .padding(.top, 68)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .overlay(SwipeCatcher(onMove: { model.dragDemo(by: $0) }, onEnd: { withAnimation(Motion.spring) { model.endDemoDrag() } }))
        .animation(Motion.spring, value: model.demoSidebar)
        .animation(Motion.spring, value: model.demoBarOpen)
        .animation(Motion.slide, value: model.demoSpace)
        .animation(Motion.standard, value: model.demoOpened)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Practice window")
        .accessibilityValue("\(titles[current]) space, showing \(shown), sidebar \(model.demoSidebar ? "shown" : "hidden")")
    }

    /// The other space's sky: one that sets the picked sky off.
    private var companion: SpaceTheme { model.sky.name == SpaceTheme.aurora.name ? .nebula : .aurora }
}

/// The practice window's sidebar, laid out as the real one is: its buttons, the address, the space's name, its tabs,
/// and the spaces along the bottom.
private struct MiniSidebar: View {
    let title: String
    let symbol: String
    let tabs: [OnboardingModel.PracticeTab]
    let selected: String
    let index: Int
    /// A short practice window leaves the buttons out.
    @Environment(\.onboardingCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                HStack(spacing: 10) {
                    Image(systemName: "sidebar.left")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                    Image(systemName: "arrow.clockwise")
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 4)
                .frame(height: 18)
                .padding(.bottom, 8)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
                Text("Search or enter address").font(.system(size: 10)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.13)))
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.top, 12)
            .padding(.bottom, 5)
            .padding(.leading, 3)
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                let on = tab.title == selected
                HStack(spacing: 7) {
                    // A site's icon, as the real sidebar shows one.
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(MiniPage.article(for: tab.title).colour)
                        .frame(width: 13, height: 13)
                        .overlay(Image(systemName: tab.symbol).font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white))
                    Text(tab.title).font(.system(size: 11, weight: on ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(on ? 0.98 : 0.74))
                .padding(.horizontal, 6)
                .frame(height: 25)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(on ? 0.18 : 0)))
            }
            Spacer(minLength: 0)
            // The spaces, the one shown picked.
            HStack(spacing: 6) {
                Image(systemName: "books.vertical").foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                ForEach(Array(["house.fill", "briefcase.fill"].enumerated()), id: \.offset) { i, symbol in
                    Image(systemName: symbol)
                        .foregroundStyle(.white.opacity(i == index ? 0.95 : 0.5))
                        .frame(width: 20, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(i == index ? 0.16 : 0)))
                }
                Spacer(minLength: 0)
                Image(systemName: "plus").foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 8.5, weight: .semibold))
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

/// The practice window's page: a short article, so it reads as a page and not as a picture of one.
private struct MiniPage: View {
    let title: String

    var body: some View {
        let article = Self.article(for: title)
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(white: 0.975))
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(article.kicker.uppercased()).font(.system(size: 8.5, weight: .bold)).kerning(0.6).foregroundStyle(article.colour)
                        Text(title).font(.system(size: 17, weight: .bold, design: .serif)).foregroundStyle(.black.opacity(0.86)).lineLimit(1)
                        Text(article.body)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.black.opacity(0.56))
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [article.colour.opacity(0.55), article.colour], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 112, height: 84)
                }
                .padding(18)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// A few lines for each practice page (and any search), written for this window.
    static func article(for title: String) -> (kicker: String, body: String, colour: Color) {
        switch title {
        case "Morning reading": ("Essay", "Slow mornings are back. A cup of something warm, one long article, and the rest of the day can wait a few minutes.", Color(red: 0.9, green: 0.52, blue: 0.5))
        case "Recipes to try": ("Kitchen", "A weeknight lemon pasta: ten minutes, one pan, and more flavour than it has any right to have.", Color(red: 0.92, green: 0.66, blue: 0.3))
        case "Weekend trip": ("Travel", "Two days by the coast: a quiet town, a long walk on the cliffs, and dinner where the boats come in.", Color(red: 0.36, green: 0.62, blue: 0.86))
        case "Evening playlist": ("Music", "Forty minutes of soft piano and slow jazz for the hour when the lights go down.", Color(red: 0.6, green: 0.46, blue: 0.86))
        case "Design review": ("Project", "Notes from Tuesday: the home page feels calmer, the type is larger, and the new colours stay.", Color(red: 0.36, green: 0.56, blue: 0.8))
        case "Q4 roadmap": ("Planning", "Three things this quarter: faster tabs, better search, and a menu-bar browser people want to keep.", Color(red: 0.3, green: 0.68, blue: 0.6))
        case "Team chat": ("Messages", "Lunch on Friday? The usual place, twelve thirty. Bring the sketches if they're ready.", Color(red: 0.5, green: 0.6, blue: 0.9))
        case "This week": ("Calendar", "Monday planning, Wednesday reviews, and a long quiet Thursday kept free for real work.", Color(red: 0.86, green: 0.48, blue: 0.62))
        default: ("Search", "The search engine’s answers would be here, with your history and open tabs above them.", Color(red: 0.5, green: 0.54, blue: 0.62))
        }
    }
}

/// The Command Bar as the practice window shows it, and it works: type to find a tab in either space (or search for
/// the words), ↑↓ to pick, Return or a click to open it in the practice window.
private struct MiniCommandBar: View {
    let model: OnboardingModel
    @FocusState private var focused: Bool
    @Environment(\.onboardingCompact) private var compact

    var body: some View {
        let rows = model.demoResults.map { ($0.symbol, $0.title, "Switch to Tab") }
            + (model.demoQuery.isEmpty ? [] : [("magnifyingglass", "Search for “\(model.demoQuery)”", "Search")])
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                TextField("Search or enter address", text: Binding(get: { model.demoQuery }, set: { model.demoQuery = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .accessibilityLabel("Practice Command Bar")
            }
            .padding(.horizontal, 11)
            .frame(height: compact ? 30 : 34)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                let picked = i == model.demoSelection
                HStack(spacing: 9) {
                    Image(systemName: row.0).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                    Text(row.1).font(.system(size: 12, weight: picked ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    if picked { Text(row.2).font(.system(size: 10.5, weight: .medium)).opacity(0.75) }
                }
                .foregroundStyle(.white.opacity(picked ? 1 : 0.72))
                .padding(.horizontal, 11)
                .frame(height: compact ? 24 : 27)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Color(model.tint).opacity(0.8) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.openDemoResult(at: i) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            }
            if rows.isEmpty {
                Text("No tab by that name").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 11).frame(height: 27)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.11, green: 0.11, blue: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .animation(Motion.quick, value: model.demoSelection)
        .onAppear { focused = true }
    }
}
