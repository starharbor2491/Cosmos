import AppKit
import Testing
import CosmosCore
@testable import CosmosKit

/// What the welcome does to the browser: the steps it walks, what each choice changes, and the keys it takes.
@MainActor
@Suite struct OnboardingTests {
    private func welcome(_ rig: Rig, start: OnboardingStep = .welcome) -> OnboardingModel {
        rig.window.overlay = start == .bring ? .importBrowser : .welcome
        let model = OnboardingModel(store: rig.store, window: rig.window, start: start)
        model.frozen = 10
        return model
    }

    @Test func returnWalksTheStepsAndBackComesBack() {
        let rig = Rig()
        let model = welcome(rig)
        var seen = [model.step]
        while model.step != .ready {
            #expect(model.handleKey("\r", keyCode: 36, modifiers: []))
            seen.append(model.step)
        }
        #expect(seen == [.welcome, .bring, .sky, .features, .moves, .ready])
        #expect(model.handleKey("[", keyCode: 33, modifiers: .command))
        #expect(model.step == .moves)
        model.revisit(.bring)
        #expect(model.step == .bring)
        model.back()
        #expect(model.step == .bring, "the opening is not gone back to")
    }

    /// The last step's button is the way in: the first run is over and the welcome clears to the window itself (whose
    /// empty page offers the Command Bar); nothing pops over the arrival, and the window is left settled.
    @Test func enteringEndsTheFirstRunInTheWindow() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.frozen = nil
        var felt: [Haptics.Pattern] = []
        rig.store.haptics.output = { felt.append($0) }
        while model.step != .ready { model.primary() }
        model.primary()
        #expect(rig.store.settings.hasCompletedOnboarding && !rig.store.settings.welcomePending)
        // Generous: in the full suite another test can hold the main actor for seconds at a time.
        let deadline = Date.now.addingTimeInterval(OnboardingFlow.entryDuration + 60)
        while rig.window.overlay != nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.window.overlay == nil)
        #expect(!rig.window.arriving)
        #expect(felt == [.levelChange], "the landing is felt once")
    }

    @Test func theEmptyWindowGreetsByTheClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour))! }
        #expect(EmptyStateView.greeting(at: at(8), calendar: calendar) == "Good morning")
        #expect(EmptyStateView.greeting(at: at(14), calendar: calendar) == "Good afternoon")
        #expect(EmptyStateView.greeting(at: at(21), calendar: calendar) == "Good evening")
        #expect(EmptyStateView.greeting(at: at(2), calendar: calendar) == "Good evening")
    }

    @Test func escapeClosesAVisit() {
        let rig = Rig()
        rig.store.settings.hasCompletedOnboarding = true
        let model = welcome(rig)
        #expect(model.handleKey("\u{1b}", keyCode: 53, modifiers: []))
        #expect(rig.window.overlay == nil)
    }

    /// File ▸ Import opens only the Bring step, whose button closes it.
    @Test func importOnItsOwnIsOneStep() {
        let rig = Rig()
        rig.store.settings.hasCompletedOnboarding = true
        let model = welcome(rig, start: .bring)
        #expect(model.steps == [.bring] && model.isVisit && !model.canGoBack)
        model.primary()
        #expect(rig.window.overlay == nil)
    }

    /// Even before setup is done, File ▸ Import on its own closes with Esc (it has no last step to skip to).
    @Test func escapeClosesImportOnItsOwnBeforeSetup() {
        let rig = Rig()
        let model = welcome(rig, start: .bring)
        #expect(!model.isVisit)
        #expect(model.handleKey("\u{1b}", keyCode: 53, modifiers: []))
        #expect(rig.window.overlay == nil)
    }

    /// An import that hangs (macOS's Keychain question left open, an engine that never answers) holds the welcome only
    /// so long; then the person can go on and it finishes behind.
    @Test func aHungImportLetsThePersonGoOnAfterAWhile() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.patience = .milliseconds(150)
        model.primary()
        let gate = Gate()
        model.run(ImportSource(id: "stuck", name: "Stuck", symbol: "globe", detail: "", isAvailable: true) { _, _, _ in
            await gate.wait()
            return ImportOutcome(summary: "")
        })
        #expect(model.isBusy)
        let deadline = Date.now.addingTimeInterval(60)
        while model.isBusy, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        model.primary()
        #expect(model.step == .sky)
        await gate.open()
    }

    /// A first run quit after an import (which marks setup done) and opened again at launch is still a first run.
    @Test func aWelcomeReopenedAtLaunchAfterAnImportIsStillTheFirstRun() {
        let rig = Rig()
        rig.store.settings.welcomePending = true
        rig.store.settings.hasCompletedOnboarding = true
        #expect(!welcome(rig).isVisit)
    }

    /// The practice window's Command Bar takes typing: it finds tabs in either space, and Return opens the one picked.
    @Test func thePracticeCommandBarFindsAndOpensATab() {
        let rig = Rig()
        let model = welcome(rig)
        while model.step != .moves { model.primary() }
        #expect(model.handleKey("t", keyCode: 17, modifiers: .command))
        model.demoQuery = "road"
        #expect(model.demoResults.map(\.title) == ["Q4 roadmap"])
        #expect(model.handleKey("\r", keyCode: 36, modifiers: []))
        #expect(model.demoOpened == "Q4 roadmap" && !model.demoBarOpen && model.step == .moves)
        #expect(model.done.contains(.commandBar))
        model.perform(.commandBar)
        model.demoQuery = "jazz"
        #expect(model.handleKey("", keyCode: 125, modifiers: []))
        model.openDemoResult()
        #expect(model.demoOpened == "Results for “jazz”")
    }

    /// After a swipe to the other space, the practice Command Bar lists that space's tabs first, and Return opens the one
    /// it shows picked; the field keeps its editing keys.
    @Test func afterASwipeThePracticeCommandBarOpensWhatItShows() {
        let rig = Rig()
        let model = welcome(rig)
        while model.step != .moves { model.primary() }
        model.perform(.swipe)
        model.perform(.commandBar)
        #expect(model.demoResults.first?.title == "Design review")
        #expect(model.handleKey("\r", keyCode: 36, modifiers: []))
        #expect(model.demoOpened == "Design review")
        model.perform(.commandBar)
        for (key, code) in [("a", UInt16(0)), ("c", 8), ("v", 9), ("x", 7), ("z", 6)] {
            #expect(!model.handleKey(key, keyCode: code, modifiers: .command), "⌘\(key) edits the field")
        }
        #expect(!model.handleKey("", keyCode: 51, modifiers: .command), "⌘⌫ deletes in the field")
        #expect(!model.handleKey("м", keyCode: 9, modifiers: .command), "⌘V pastes on a Russian layout too")
        model.perform(.commandBar)
        #expect(model.handleKey("a", keyCode: 0, modifiers: .command), "with the bar closed, ⌘A is not the welcome's to pass on")
    }

    /// On Dvorak the key where Q sits on a US keyboard types ' and the one where H sits types D: ⌘D must not reach the
    /// browser behind (it would pin a tab there), while ⌘Q, typed as q, still quits.
    @Test func dvorakKeysAreToldApartByTheirLetters() {
        let rig = Rig()
        let model = welcome(rig)
        #expect(model.handleKey("d", keyCode: 4, modifiers: .command))
        #expect(!model.handleKey("q", keyCode: 7, modifiers: .command))
        #expect(!model.handleKey("/", keyCode: 12, modifiers: .command), "a layout with punctuation where Q sits still quits")
    }

    /// Picking a sky gives the space that sky, and the Dock icon follows it for the four skies that have one, unless
    /// the person says not to.
    @Test func aSkyIsTheSpacesAndTheIconFollows() {
        let rig = Rig()
        let model = welcome(rig)
        model.setMatchIcon(true)
        model.choose(.supernova)
        #expect(rig.space.theme == .supernova)
        #expect(rig.store.settings.appIcon == .supernova)
        model.choose(.pulsar)
        #expect(rig.space.theme == .pulsar)
        #expect(rig.store.settings.appIcon == .supernova, "Pulsar has no icon: the last one stays")
        model.setMatchIcon(false)
        model.choose(.aurora)
        #expect(rig.store.settings.appIcon == .supernova)
        model.chooseNeighbour(1)
        #expect(rig.space.theme == SpaceTheme.presets[2])
    }

    @Test func aFeatureCardSwitchesItsFeature() {
        let rig = Rig()
        let model = welcome(rig)
        for feature in OnboardingModel.offered {
            let before = rig.store.settings.isOn(feature)
            model.toggle(feature)
            #expect(rig.store.settings.isOn(feature) == !before)
        }
    }

    /// On the Moves step the moves' own keys work the little window; nothing reaches the browser behind.
    @Test func theMovesAreTriedInTheLittleWindow() {
        let rig = Rig()
        let model = welcome(rig)
        while model.step != .moves { model.primary() }
        let sidebar = rig.window.sidebarVisible
        #expect(model.handleKey("t", keyCode: 17, modifiers: .command))
        #expect(model.demoBarOpen && rig.window.overlay == .welcome)
        #expect(model.handleKey("\u{1b}", keyCode: 53, modifiers: []), "Esc closes the little Command Bar first")
        #expect(!model.demoBarOpen && rig.window.overlay == .welcome)
        #expect(model.handleKey("s", keyCode: 1, modifiers: .command))
        #expect(!model.demoSidebar && rig.window.sidebarVisible == sidebar)
        model.dragDemo(by: -20)
        model.endDemoDrag()
        #expect(model.demoSpace == 0, "a short drag springs back")
        model.dragDemo(by: -60)
        model.endDemoDrag()
        #expect(model.demoSpace == 1)
        #expect(model.done == Set(OnboardingModel.Move.allCases))
    }

    /// While the welcome is up, the browser's own ⌘ shortcuts wait; quitting, closing, hiding and Settings do not.
    @Test func browserShortcutsWaitButQuittingDoesNot() {
        let rig = Rig()
        let model = welcome(rig)
        #expect(model.handleKey("t", keyCode: 17, modifiers: .command), "⌘T would open a Command Bar over the welcome")
        #expect(model.handleKey("l", keyCode: 37, modifiers: .command))
        #expect(!model.handleKey("q", keyCode: 12, modifiers: .command))
        #expect(!model.handleKey("w", keyCode: 13, modifiers: .command))
        #expect(!model.handleKey(",", keyCode: 43, modifiers: .command))
        #expect(!model.handleKey("a", keyCode: 0, modifiers: []), "plain typing is not the welcome's")
        #expect(rig.window.overlay == .welcome)
    }

    @Test func aPrivateWindowSkipsTheImport() {
        let store = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        let window = store.makeWindowState()
        store.register(window)
        let model = OnboardingModel(store: store, window: window)
        #expect(!model.steps.contains(.bring))
    }

    /// While a browser is being brought over, the welcome stays on that step: an import that lands after the person
    /// moved on would undo what they chose since (a sky, or tabs opened after entering).
    @Test func theWelcomeWaitsForAnImportToFinish() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        #expect(model.step == .bring)
        let gate = Gate()
        let slow = ImportSource(id: "slow", name: "Slow", symbol: "globe", detail: "", isAvailable: true) { _, _, _ in
            await gate.wait()
            return ImportOutcome(summary: "Brought 1 space and 1 tab.")
        }
        model.run(slow)
        #expect(model.isBusy)
        model.primary()
        #expect(model.handleKey("\r", keyCode: 36, modifiers: []))
        model.revisit(.welcome)
        #expect(model.step == .bring, "nothing moves the welcome on while the import runs")
        await gate.open()
        let deadline = Date.now.addingTimeInterval(60)
        while model.isBusy, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        model.primary()
        #expect(model.step == .sky)
    }

    /// An import changes the space being looked at; the Sky step then shows (and the galaxy wears) that space's sky.
    @Test func theSkyStepShowsTheSkyAnImportBrought() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        let restyle = ImportSource(id: "arc", name: "Arc", symbol: "globe", detail: "", isAvailable: true) { store, window, _ in
            store.updateSpace(window.focusedSpaceID) { $0.theme = .supernova }
            return ImportOutcome(summary: "Brought 1 space.")
        }
        model.run(restyle)
        let deadline = Date.now.addingTimeInterval(60)
        while model.isBusy, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        model.primary()
        #expect(model.step == .sky)
        #expect(model.sky == .supernova)
        #expect(model.palette(at: model.time() + 5) == Galaxy.palette(for: .supernova))
    }

    /// A first run that is quit part-way (after a sky was picked, which saves the workspace) is still a first run next
    /// time: the welcome is due until it is finished.
    @Test func aWelcomeLeftPartWayIsDueAgainNextLaunch() {
        let rig = Rig()
        #expect(rig.store.welcomeIsDue(demo: false))
        let model = welcome(rig)
        model.choose(.aurora)
        rig.store.saveNow()
        let again = BrowserStore(directory: rig.dir, engine: FakeEngine(), passwordKey: { Rig.passwordKey })
        #expect(!again.isFirstLaunch)
        #expect(again.welcomeIsDue(demo: false))
        let window = again.makeWindowState()
        again.register(window)
        window.overlay = .welcome
        OnboardingModel(store: again, window: window).close()
        again.saveNow()
        #expect(!BrowserStore(directory: rig.dir, engine: FakeEngine(), passwordKey: { Rig.passwordKey }).welcomeIsDue(demo: false))
    }

    @Test func theDemoNeverShowsTheWelcome() {
        #expect(!Rig().store.welcomeIsDue(demo: true))
    }

    /// Keys are told apart by where they are on the keyboard too, so ⌘Q still quits on a Cyrillic layout and ⌘T still
    /// opens the little Command Bar; a held Return does not run through the welcome.
    @Test func keysWorkOnAnyLayoutAndAHeldReturnDoesNotRunAway() {
        let rig = Rig()
        let model = welcome(rig)
        #expect(!model.handleKey("й", keyCode: 12, modifiers: .command), "⌘Q on a Cyrillic layout")
        #expect(!model.handleKey("ц", keyCode: 13, modifiers: .command), "⌘W on a Cyrillic layout")
        #expect(model.handleKey("\r", keyCode: 36, modifiers: [], isRepeat: true))
        #expect(model.step == .welcome)
        while model.step != .moves { model.primary() }
        #expect(model.handleKey("е", keyCode: 17, modifiers: .command))
        #expect(model.demoBarOpen)
    }

    /// Spaces that came across are shown beside the Bring step, in the window they will be in; history alone is not.
    @Test func aSpacesImportIsShownBesideTheBringStep() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        #expect(!model.showsPreview)
        model.run(ImportSource(id: "history", name: "History", symbol: "globe", detail: "", isAvailable: true) { _, _, _ in
            ImportOutcome(summary: "Brought 12 pages of history.")
        })
        try await waitUntil { !model.isBusy }
        #expect(!model.showsPreview, "history alone has nothing to show in the sidebar")
        model.run(ImportSource(id: "spaces", name: "Spaces", symbol: "globe", detail: "", isAvailable: true, bringsSpaces: true) { store, window, _ in
            let work = store.addSpace(title: "Work", icon: .symbol("briefcase.fill"), theme: .deepField, profileID: nil, in: nil)
            store.switchSpace(to: work, in: window)
            return ImportOutcome(summary: "Brought 2 spaces.")
        })
        try await waitUntil { !model.isBusy }
        #expect(model.showsPreview && model.landedAt != nil)
        #expect(model.preview.focusedSpaceID == rig.window.focusedSpaceID, "the preview shows the space the import left open")
        #expect(rig.store.workspace.space(model.preview.focusedSpaceID)?.title == "Work")
        #expect(rig.window.overlay == .welcome && model.preview !== rig.window)
    }

    /// From the last step of a wide window the way in grows the window beside the words into the browser, which waits
    /// as it is; in a narrow one (no window beside the words) the browser waits under the light instead.
    @Test func theLastStepsWindowGrowsIntoTheBrowserWhenThereIsRoom() {
        for (width, grows) in [(1400.0, true), (1000.0, false)] {
            let rig = Rig()
            let model = welcome(rig)
            model.windowSize = CGSize(width: width, height: 860)
            while model.step != .ready { model.primary() }
            model.primary()
            #expect(model.enteredAt != nil)
            #expect(model.grows == grows)
            #expect(rig.window.arriving == !grows)
        }
    }

    /// Help ▸ Welcome over a page: the last step draws no empty window beside it (the page stays), and the way in leaves
    /// the page as it is.
    @Test func aVisitOverAPageShowsNoEmptyWindowAtTheEnd() {
        let rig = Rig()
        rig.store.settings.hasCompletedOnboarding = true
        let tab = rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window)
        #expect(tab != nil && rig.window.selectedItemID != nil)
        let model = welcome(rig)
        model.windowSize = CGSize(width: 1400, height: 860)
        while model.step != .ready { model.primary() }
        #expect(!model.showsPreview)
        model.primary()
        #expect(!model.grows && !rig.window.arriving)
    }

    /// A first run has the Dock follow the sky until the person says otherwise, an import with a sky of its own
    /// included; the row's line always says what the switch does.
    @Test func anImportKeepsTheMatchIconChoice() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        let custom = SpaceTheme(name: "Lagoon", colors: [RGBA(hex: 0x0B2A3C), RGBA(hex: 0x1F7A8C)], angle: 140)
        model.run(ImportSource(id: "spaces", name: "Spaces", symbol: "globe", detail: "", isAvailable: true, bringsSpaces: true) { store, window, _ in
            store.updateSpace(window.focusedSpaceID) { $0.theme = custom }
            return ImportOutcome(summary: "Brought 1 space.")
        })
        try await waitUntil { !model.isBusy && model.imported }
        model.primary()
        #expect(model.step == .sky && model.sky == custom)
        #expect(model.matchIcon, "an import's sky does not switch the Dock's following off")
        #expect(rig.store.settings.appIcon == .nebula)
        #expect(model.matchIconLine == "Lagoon has no icon of its own, so the Dock keeps Nebula.")
        model.choose(.aurora)
        #expect(rig.store.settings.appIcon == .aurora)
        #expect(model.matchIconLine == "While Cosmos is open, its Dock icon wears Aurora’s colours.")
        model.setMatchIcon(false)
        #expect(model.matchIconLine == "The Dock keeps Aurora whatever the sky.")
        model.choose(.supernova)
        #expect(rig.store.settings.appIcon == .aurora, "switched off, the Dock keeps its icon")
    }

    /// An import that leaves a sky with an icon of its own: the Sky step, saying the Dock follows, makes it so.
    @Test func theSkyStepPutsAnImportedSkysIconInTheDock() async throws {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        model.run(ImportSource(id: "spaces", name: "Spaces", symbol: "globe", detail: "", isAvailable: true, bringsSpaces: true) { store, window, _ in
            store.updateSpace(window.focusedSpaceID) { $0.theme = .deepField }
            return ImportOutcome(summary: "Brought 1 space.")
        })
        try await waitUntil { !model.isBusy && model.imported }
        #expect(rig.store.settings.appIcon == .nebula, "the Bring step leaves the Dock alone")
        model.primary()
        #expect(rig.store.settings.appIcon == .deepField)
    }

    /// In a window too narrow for words beside the galaxy, a step that sits to one side has the galaxy moved toward the
    /// window's lower corner and dimmed; a wide window, and a centred step, keep it where the step put it.
    @Test func aNarrowWindowMovesTheGalaxyAside() {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        #expect(model.step.placement != .centre)
        let wide = model.frame(at: 20, in: CGSize(width: 1400, height: 900))
        let narrow = model.frame(at: 20, in: CGSize(width: 1000, height: 700))
        #expect(wide.camera == model.frame(at: 20).camera)
        #expect(abs(narrow.camera.x - 0.5) > abs(wide.camera.x - 0.5))
        #expect(narrow.camera.y > wide.camera.y && narrow.camera.light < wide.camera.light)
        while model.step.placement != .centre { model.primary() }
        #expect(model.frame(at: 40, in: CGSize(width: 1000, height: 700)).camera == model.frame(at: 40).camera)
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        // Generous: in the full suite another test can hold the main actor for seconds at a time.
        let deadline = Date.now.addingTimeInterval(60)
        while !done(), Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(done())
    }

    /// Esc on a first run does not throw the setup away: it skips to the last step, where the way in is.
    @Test func escapeOnAFirstRunSkipsToTheEnd() {
        let rig = Rig()
        let model = welcome(rig)
        model.primary()
        #expect(model.handleKey("\u{1b}", keyCode: 53, modifiers: []))
        #expect(model.step == .ready && rig.window.overlay == .welcome)
        #expect(model.handleKey("\u{1b}", keyCode: 53, modifiers: []))
        #expect(model.step == .ready && rig.window.overlay == .welcome)
    }
}

/// Holds an import until the test lets it go.
private actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for c in waiting { c.resume() }
        waiting = []
    }
}

