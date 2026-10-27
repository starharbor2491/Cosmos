import Testing
@testable import CosmosKit

/// The bar that fills along an address while a page loads: it starts at the left, only moves forward, fills when the page is
/// done and then goes, and a load that starts while the last one is finishing starts over.
@Suite struct LoadingBarTests {
    @Test func itIsQuietUntilAPageLoads() {
        var bar = LoadingBarState()
        bar.update(isLoading: false, progress: 0)
        #expect(bar.phase == .idle && bar.fraction == 0 && bar.restarts == 0)
    }

    @Test func aLoadStartsWithSomethingToSeeEvenBeforeWebKitHasAnEstimate() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 0)
        #expect(bar.phase == .loading)
        #expect(bar.fraction == LoadingBarState.minimum)
        #expect(bar.restarts == 1)
    }

    @Test func theBarOnlyMovesForwardWhileLoading() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 0.1)
        bar.update(isLoading: true, progress: 0.6)
        bar.update(isLoading: true, progress: 0.2)   // a redirect makes WebKit start its estimate over
        #expect(bar.fraction == 0.6)
        bar.update(isLoading: true, progress: 0.7)
        #expect(bar.fraction == 0.7)
    }

    @Test func itNeverLooksFinishedWhileThePageIsStillLoading() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 1)
        #expect(bar.fraction == LoadingBarState.ceiling)
        #expect(bar.fraction < 1)
    }

    @Test func aFinishedLoadFillsTheBarAndThenItGoes() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 0.4)
        bar.update(isLoading: false, progress: 1)
        #expect(bar.phase == .finishing && bar.fraction == 1)
        bar.finish(generation: bar.generation)
        #expect(bar.phase == .idle && bar.fraction == 0)
    }

    @Test func aTimerFromAnEarlierLoadCannotEndALaterOne() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 0.4)
        bar.update(isLoading: false, progress: 1)
        let stale = bar.generation
        bar.update(isLoading: true, progress: 0.1)   // the next page starts before the timer fires
        bar.finish(generation: stale)
        #expect(bar.phase == .loading, "the old timer was ignored")
    }

    @Test func aLoadThatStartsWhileTheLastIsFinishingStartsOverFromTheLeft() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 0.9)
        bar.update(isLoading: false, progress: 1)
        let before = bar.restarts
        bar.update(isLoading: true, progress: 0)
        #expect(bar.fraction == LoadingBarState.minimum)
        #expect(bar.restarts == before + 1, "the view jumps back without animating it")
    }

    @Test func anEstimateThatIsNotANumberOrOutOfRangeIsHarmless() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: .nan)
        #expect(bar.fraction == LoadingBarState.minimum)
        bar.update(isLoading: true, progress: -4)
        #expect(bar.fraction == LoadingBarState.minimum)
        bar.update(isLoading: true, progress: .infinity)
        #expect(bar.fraction == LoadingBarState.ceiling)
    }

    @Test func aPageThatKeepsLoadingKeepsTheSameLoad() {
        var bar = LoadingBarState()
        bar.update(isLoading: true, progress: 0.3)
        let restarts = bar.restarts
        bar.update(isLoading: true, progress: 0.5)
        #expect(bar.restarts == restarts)
    }
}
