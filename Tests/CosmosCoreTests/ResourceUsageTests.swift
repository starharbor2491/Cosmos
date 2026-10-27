import Foundation
import Testing
@testable import CosmosCore

@Suite struct ResourceUsageTests {
    @Test func theRunningProcessReportsItsMemoryAndProcessorTime() throws {
        let usage = try #require(ProcessSampler.sample(pid: getpid()))
        #expect(usage.pid == getpid())
        #expect(usage.footprint > 1_000_000, "a running test process holds more than a megabyte")
        #expect(usage.cpuSeconds >= 0)
    }

    /// The system counts processor time in clock ticks that are not nanoseconds on Apple silicon; a conversion left out makes
    /// the figure some 40 times too small. A busy loop of a third of a second has to show up as about that much.
    @Test func processorTimeIsReportedInSeconds() throws {
        let before = try #require(ProcessSampler.sample(pid: getpid())).cpuSeconds
        let end = Date().addingTimeInterval(0.35)
        var sink = 0.0
        while Date() < end { for i in 0..<20_000 { sink += Double(i).squareRoot() } }
        let after = try #require(ProcessSampler.sample(pid: getpid())).cpuSeconds
        #expect(sink > 0)
        // Even on a busy machine a third of a second of work is well over this; without the conversion it is about a hundredth.
        #expect(after - before > 0.08, "a third of a second of work shows as \(after - before) s")
    }

    @Test func aProcessThatIsNotThereReportsNothing() {
        #expect(ProcessSampler.sample(pid: 0) == nil)
        #expect(ProcessSampler.sample(pid: -4) == nil)
        #expect(ProcessSampler.sample(pid: Int32.max) == nil)
    }

    @Test func processorUseIsTheTimeSpentOverTheTimeThatPassed() {
        var meter = CPUMeter()
        let start = Date()
        #expect(meter.percent(pid: 7, cpuSeconds: 10, at: start) == nil, "one reading says nothing about use")
        #expect(meter.percent(pid: 7, cpuSeconds: 10.5, at: start.addingTimeInterval(1)) == 50)
        // More than one core can be busy at once.
        #expect(meter.percent(pid: 7, cpuSeconds: 12.5, at: start.addingTimeInterval(2)) == 200)
    }

    @Test func eachProcessHasItsOwnRunningReading() {
        var meter = CPUMeter()
        let start = Date()
        _ = meter.percent(pid: 1, cpuSeconds: 0, at: start)
        _ = meter.percent(pid: 2, cpuSeconds: 100, at: start)
        #expect(meter.percent(pid: 1, cpuSeconds: 1, at: start.addingTimeInterval(2)) == 50)
        #expect(meter.percent(pid: 2, cpuSeconds: 100, at: start.addingTimeInterval(2)) == 0)
    }

    @Test func aReadingThatGoesBackwardsOrStandsStillIsNotUse() {
        var meter = CPUMeter()
        let start = Date()
        _ = meter.percent(pid: 3, cpuSeconds: 5, at: start)
        #expect(meter.percent(pid: 3, cpuSeconds: 4, at: start.addingTimeInterval(1)) == 0, "a pid reused by another process")
        #expect(meter.percent(pid: 3, cpuSeconds: 6, at: start.addingTimeInterval(1)) == nil, "no time has passed")
    }

    @Test func processesThatAreGoneAreForgotten() {
        var meter = CPUMeter()
        let start = Date()
        _ = meter.percent(pid: 8, cpuSeconds: 1, at: start)
        _ = meter.percent(pid: 9, cpuSeconds: 1, at: start)
        meter.keepOnly([9])
        #expect(meter.percent(pid: 8, cpuSeconds: 2, at: start.addingTimeInterval(1)) == nil)
        #expect(meter.percent(pid: 9, cpuSeconds: 2, at: start.addingTimeInterval(1)) == 100)
    }

    @Test func theMachineReportsHowMuchMemoryIsInUse() throws {
        let memory = try #require(SystemMemory.read())
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.used > 0 && memory.used <= memory.total)
        #expect(memory.fractionUsed > 0 && memory.fractionUsed <= 1)
    }

    @Test func sizesAreWrittenTheWayTheFinderWritesThem() {
        #expect(ResourceText.bytes(1_500_000_000).hasSuffix("GB"))
        #expect(ResourceText.bytes(250_000_000).hasSuffix("MB"))
        #expect(ResourceText.percent(0) == "0%")
        #expect(ResourceText.percent(12.4) == "12%")
        #expect(ResourceText.percent(199.6) == "200%")
    }
}
