import Foundation
import Testing
@testable import CosmosCore

/// The welcome's order and choreography, and the galaxy it draws: all functions of time and a seed, so any frame can be
/// checked without drawing it.
@Suite struct OnboardingFlowTests {
    @Test func theStepsRunInOrderAndAPrivateWindowHasNoImport() {
        let all = OnboardingFlow.steps(canImport: true)
        #expect(all == [.welcome, .bring, .sky, .features, .moves, .ready])
        #expect(!OnboardingFlow.steps(canImport: false).contains(.bring))
        #expect(OnboardingFlow.next(after: .welcome, in: all) == .bring)
        #expect(OnboardingFlow.next(after: .ready, in: all) == nil)
        #expect(OnboardingFlow.previous(before: .bring, in: all) == .welcome)
        #expect(OnboardingFlow.previous(before: .welcome, in: all) == nil)
        #expect(OnboardingFlow.counted(all) == [.bring, .sky, .features, .moves, .ready], "the opening is not a step to count")
    }

    /// The opening's parts come in one after another: the mark's bars from the top, then the name's letters in order,
    /// then the line, then the button, and all of it is in place when the opening ends.
    @Test func theOpeningComesInInOrderAndEnds() {
        let t = OnboardingFlow.self
        #expect(t.bar(0, at: t.markStarts) == 0 && t.bar(0, at: t.markStarts + 0.2) > t.bar(10, at: t.markStarts + 0.2))
        #expect(t.letter(0, at: t.titleStarts - 0.01) == 0)
        for i in 0..<5 { #expect(t.letter(i, at: t.titleStarts + 0.3) > t.letter(i + 1, at: t.titleStarts + 0.3)) }
        #expect(t.markStarts < t.titleStarts && t.titleStarts < t.lineStarts && t.lineStarts < t.buttonStarts)
        for i in 0..<11 { #expect(t.bar(i, at: t.openingEnds) > 0.999) }
        for i in 0..<6 { #expect(t.letter(i, at: t.openingEnds) > 0.999) }
        #expect(t.line(at: t.openingEnds) > 0.999 && t.button(at: t.openingEnds) > 0.999)
    }

    /// The camera arrives without overshooting, from wherever it was.
    @Test func theCameraSettlesWithoutOvershoot() {
        let a = OnboardingStep.welcome.camera, b = OnboardingStep.bring.camera
        #expect(GalaxyCamera.moving(from: a, to: b, elapsed: 0) == a)
        var last = a.x
        for i in 1...60 {
            let x = GalaxyCamera.moving(from: a, to: b, elapsed: Double(i) * 0.05).x
            #expect((x - last) * (b.x - a.x) >= 0, "it only ever moves toward where it is going")
            #expect(abs(x - a.x) <= abs(b.x - a.x) + 1e-9)
            last = x
        }
        #expect(abs(GalaxyCamera.moving(from: a, to: b, elapsed: 3).x - b.x) < 1e-3)
    }

    @Test func theWayInRushesAndClears() {
        #expect(OnboardingFlow.entryZoom(at: 0) == 1)
        #expect(OnboardingFlow.entryZoom(at: 0.3) < OnboardingFlow.entryZoom(at: 0.9))
        #expect(OnboardingFlow.entryCover(at: 0) == 1 && OnboardingFlow.entryCover(at: OnboardingFlow.entryDuration) == 0)
    }

    @Test func theColoursChangeOverAboutASecond() {
        let a = Galaxy.palette(for: .nebula), b = Galaxy.palette(for: .supernova)
        #expect(OnboardingFlow.palette(from: a, to: b, elapsed: 0) == a)
        #expect(OnboardingFlow.palette(from: a, to: b, elapsed: 2) == b)
        let middle = OnboardingFlow.palette(from: a, to: b, elapsed: 0.55)
        #expect(middle != a && middle != b && middle.count == 7)
    }
}

@Suite struct GalaxyTests {
    @Test func theSameSeedDrawsTheSameGalaxy() {
        #expect(Galaxy(seed: 7, stars: 200).stars == Galaxy(seed: 7, stars: 200).stars)
        #expect(Galaxy(seed: 7, stars: 200).stars != Galaxy(seed: 8, stars: 200).stars)
    }

    /// Before it gathers nothing shows; once gathered, every star sits where it settles (turned by the time passed),
    /// inside the disc, and the gas is in place and lit.
    @Test func itGathersFromNothingIntoTheDisc() {
        let galaxy = Galaxy(seed: 3, stars: 400)
        #expect(galaxy.stars.allSatisfy { Galaxy.place($0, at: 0).alpha == 0 })
        let end = Galaxy.formation + 0.5
        for star in galaxy.stars {
            let placed = Galaxy.place(star, at: end)
            #expect(placed.alpha > 0)
            let a = star.angle + Galaxy.angularSpeed(radius: star.radius) * end
            let settled = Galaxy.project(x: star.radius * cos(a), y: star.radius * sin(a), height: star.height)
            #expect(abs(placed.point.x - settled.x) < 1e-6 && abs(placed.point.y - settled.y) < 1e-6)
            #expect(hypot(placed.point.x, placed.point.y) < 1.1)
        }
        let gas = Galaxy.gas(at: end)
        #expect(gas.alpha == 1 && abs(gas.scale - 1) < 1e-3)
        #expect(Galaxy.gas(at: 0).alpha == 0)
    }

    /// The arms keep their shape: the disc beyond the centre turns as one, so the edge and the middle of the arms stay
    /// within a few degrees of each other over ten minutes.
    @Test func theArmsDoNotWindUp() {
        let drift = (Galaxy.angularSpeed(radius: 0.3) - Galaxy.angularSpeed(radius: 1)) * 600
        #expect(abs(drift) < 0.1)
    }

    @Test func theGasLiesInTheDiscAndIsDarkerInTheLanes() {
        #expect(Galaxy.gas(x: 1.3, y: 0).inner == 0 && Galaxy.gas(x: 1.3, y: 0).outer == 0)
        // Along an arm there is gas; halfway between the arms there is less.
        let r = 0.5
        var onArm = 0.0, between = 0.0
        for k in 0..<24 {
            let jitter = Double(k) * 0.01
            let a = Galaxy.armAngle(radius: r + jitter, arm: 0)
            let g1 = Galaxy.gas(x: (r + jitter) * cos(a), y: (r + jitter) * sin(a))
            let g2 = Galaxy.gas(x: (r + jitter) * cos(a + .pi / 2), y: (r + jitter) * sin(a + .pi / 2))
            onArm += g1.inner + g1.outer
            between += g2.inner + g2.outer
        }
        #expect(onArm > between * 1.5)
    }

    @Test func eachSkyGivesSevenLitColours() {
        for theme in SpaceTheme.presets {
            let palette = Galaxy.palette(for: theme)
            #expect(palette.count == 7)
            #expect(palette.allSatisfy { max($0.r, $0.g, $0.b) > 0.9 }, "\(theme.name): every colour glows")
        }
    }
}
