import Foundation
import Darwin

/// What one process holds and has used, as the system reports it.
public struct ProcessUsage: Equatable, Sendable {
    public var pid: Int32
    /// The memory the process answers for (what Activity Monitor calls Memory), in bytes.
    public var footprint: UInt64
    /// Processor time since it started, user and system together.
    public var cpuSeconds: Double
}

public enum ProcessSampler {
    /// The usage of `pid`, or nil when there is no such process or it is not ours to look at.
    public static func sample(pid: Int32) -> ProcessUsage? {
        guard pid > 0 else { return nil }
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        guard result == 0 else { return nil }
        return ProcessUsage(pid: pid, footprint: info.ri_phys_footprint, cpuSeconds: seconds(machTime: info.ri_user_time &+ info.ri_system_time))
    }

    /// The system counts processor time in the clock's own ticks, which are not nanoseconds on Apple silicon.
    private static func seconds(machTime ticks: UInt64) -> Double {
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom != 0 else { return 0 }
        return Double(ticks) * Double(base.numer) / Double(base.denom) / 1_000_000_000
    }
}

/// Turns a process's running total of processor time into how busy it is, from two readings taken some time apart.
public struct CPUMeter {
    private var last: [Int32: (seconds: Double, at: Date)] = [:]

    public init() {}

    /// The share of one processor the process used since the last reading, in percent (a process with two busy threads
    /// uses 200). Nil for the first reading of a process and when no time has passed since the last one.
    public mutating func percent(pid: Int32, cpuSeconds: Double, at now: Date) -> Double? {
        let previous = last[pid]
        if let previous, now.timeIntervalSince(previous.at) <= 0 { return nil }
        last[pid] = (cpuSeconds, now)
        guard let previous else { return nil }
        let elapsed = now.timeIntervalSince(previous.at)
        // A total that went down belongs to another process that got the same number.
        return max(0, cpuSeconds - previous.seconds) / elapsed * 100
    }

    /// Forgets every process but these, so a process that ended does not keep its row.
    public mutating func keepOnly(_ pids: Set<Int32>) {
        last = last.filter { pids.contains($0.key) }
    }
}

public struct SystemMemory: Equatable, Sendable {
    public var used: UInt64
    public var total: UInt64

    public var fractionUsed: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    /// App memory, wired memory and compressed memory: what Activity Monitor adds up as Memory Used.
    public static func read() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let pages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count) &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        return SystemMemory(used: min(total, pages &* page), total: total)
    }
}

public enum ResourceText {
    public static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(count, UInt64(Int64.max))), countStyle: .file)
    }

    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}
