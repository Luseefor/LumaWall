import Darwin
import Foundation

public struct CPUSampler {
    private var lastHost = host_cpu_load_info()
    private var hasHost = false
    private var lastTaskNanos: UInt64 = 0
    private var lastSample = Date.distantPast

    public init() {}

    public mutating func sample() -> (process: Double, system: Double) {
        let now = Date()
        let system = sampleHost()
        let process = sampleTask(now: now)
        lastSample = now
        return (process, system)
    }

    private mutating func sampleHost() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer {
            lastHost = info
            hasHost = true
        }
        guard hasHost else { return 0 }
        let user = Double(info.cpu_ticks.0 - lastHost.cpu_ticks.0)
        let systemTicks = Double(info.cpu_ticks.1 - lastHost.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 - lastHost.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 - lastHost.cpu_ticks.3)
        let total = user + systemTicks + idle + nice
        guard total > 0 else { return 0 }
        return ((user + systemTicks + nice) / total) * 100
    }

    private mutating func sampleTask(now: Date) -> Double {
        var info = task_absolutetime_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_absolutetime_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let nanos = info.total_user + info.total_system
        defer { lastTaskNanos = nanos }
        let elapsed = now.timeIntervalSince(lastSample)
        guard lastSample != .distantPast, elapsed > 0 else { return 0 }
        let deltaSeconds = Double(nanos - lastTaskNanos) / Double(NSEC_PER_SEC)
        return max(0, min(100, (deltaSeconds / elapsed) * 100))
    }
}
