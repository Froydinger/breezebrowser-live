// Resource monitoring: what Breeze actually costs the machine right now.
//
// Breeze is not one process. Each awake tab is its own WebKit WebContent XPC
// service, plus shared Networking and GPU services — and macOS parents all of
// them to launchd, not to us, so a naive "how much am I using" reading reports
// only the tiny AppKit shell and looks like a lie next to Activity Monitor.
//
// We attribute them the way Activity Monitor does: every process whose
// *responsible* process is Breeze belongs to Breeze. `responsibility_get_pid_
// responsible_for_pid` is resolved with dlsym rather than linked, so if a future
// macOS drops it we degrade to reporting our own process instead of failing.
//
// Sampling is deliberately slow (see the no-perpetual-timers invariant in
// AGENTS.md): CPU needs two samples to have any meaning at all, so we take one
// every 15s and only while the app is active.

import Cocoa
import Darwin

struct ResourceSample {
    var cpuPercent: Double = 0        // percent of ONE core, matching Activity Monitor
    var memoryBytes: UInt64 = 0       // summed phys_footprint
    var processCount: Int = 0

    var memoryGB: Double { Double(memoryBytes) / 1_073_741_824.0 }
    /// Share of the whole machine's CPU, which is what "is this hurting?" means.
    var cpuLoad: Double { cpuPercent / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
}

final class ResourceMonitor {
    static let shared = ResourceMonitor()

    private(set) var latest = ResourceSample()
    /// Called on the main thread after every sample.
    var onSample: ((ResourceSample) -> Void)?

    private var timer: Timer?
    private var lastCPUNanos: [pid_t: UInt64] = [:]
    private var lastSampleAt: Date?
    private let queue = DispatchQueue(label: "breeze.resources", qos: .utility)

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),   // RTLD_DEFAULT
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        sample()   // prime the CPU baseline; the first reading is memory-only
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            // A background Breeze is not the problem the user is trying to solve,
            // and polling while hidden is exactly the idle drain we forbid.
            guard NSApp.isActive else { return }
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    /// Take a reading now, off the main thread, and report it back on main.
    func sample() {
        queue.async { [weak self] in
            guard let self else { return }
            let (sample, cpuNanos) = self.collect()
            DispatchQueue.main.async {
                self.lastCPUNanos = cpuNanos
                self.lastSampleAt = Date()
                self.latest = sample
                self.onSample?(sample)
            }
        }
    }

    // MARK: - Collection

    private func collect() -> (ResourceSample, [pid_t: UInt64]) {
        let mine = getpid()
        var nanos: [pid_t: UInt64] = [:]
        var footprint: UInt64 = 0
        var count = 0

        for pid in allPIDs() where pid == mine || Self.responsible(of: pid) == mine {
            guard let info = rusage(of: pid) else { continue }
            nanos[pid] = info.ri_user_time &+ info.ri_system_time
            footprint &+= info.ri_phys_footprint
            count += 1
        }

        var s = ResourceSample(cpuPercent: 0, memoryBytes: footprint, processCount: count)

        // CPU is a rate, so it exists only relative to the previous sample. A pid
        // we have not seen before contributes nothing this round rather than
        // dumping its whole lifetime of CPU into one interval and spiking to 400%.
        if let previousAt = lastSampleAt {
            let elapsed = Date().timeIntervalSince(previousAt)
            if elapsed > 0.5 {
                var delta: UInt64 = 0
                for (pid, now) in nanos {
                    guard let before = lastCPUNanos[pid], now > before else { continue }
                    delta &+= now &- before
                }
                s.cpuPercent = (Double(delta) / 1_000_000_000.0) / elapsed * 100.0
            }
        }
        return (s, nanos)
    }

    private func allPIDs() -> [pid_t] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        count += 64                                   // room for processes spawned mid-call
        var pids = [pid_t](repeating: 0, count: Int(count))
        let bytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * Int(count)))
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func responsible(of pid: pid_t) -> pid_t {
        guard let fn = responsibleFor else { return -1 }
        return fn(pid)
    }

    private func rusage(of pid: pid_t) -> rusage_info_current? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return ok == 0 ? info : nil
    }
}
