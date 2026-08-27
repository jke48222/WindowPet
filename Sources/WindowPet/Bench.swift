import AppKit
import WindowPetCore

/// Self-instrumenting energy benchmark (`--bench [secondsPerPhase]`).
/// Measures the process's own CPU (getrusage deltas) and RSS across three
/// deterministic phases, prints machine-readable results, and exits nonzero
/// if the dossier budgets are violated:
///
///   sleep  ≤ 0.3% CPU   (the dossier's "idle, pet asleep" budget)
///   active ≤ 3.0% CPU   (continuous travel between two windows)
///   RSS    ≤ 80 MB
///
/// Perched-idle (awake, breathing) is reported with a soft 1.0% gate.
/// External validation: sudo powermetrics --samplers tasks -i 5000.
enum CPUSampler {
    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}

final class BenchRunner {
    private let engine: PetEngine
    private let phaseSeconds: TimeInterval
    private var w1: NSWindow!
    private var w2: NSWindow!
    private var results: [(String, Double, Double)] = [] // phase, cpu%, rssMB
    private var travelToggle = false
    private var travelTimer: Timer?

    init(engine: PetEngine, phaseSeconds: TimeInterval) {
        self.engine = engine
        self.phaseSeconds = max(8, phaseSeconds)
    }

    func run() {
        engine.autonomy = false
        engine.reactionsEnabled = false
        engine.greetingEnabled = false
        engine.allowOwnWindows = true
        engine.debugForcePID = ProcessInfo.processInfo.processIdentifier
        engine.world.restrictPID = ProcessInfo.processInfo.processIdentifier

        func makeWindow(_ rect: CGRect) -> NSWindow {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.3)
            w.isReleasedWhenClosed = false
            w.orderFrontRegardless()
            return w
        }
        w1 = makeWindow(CGRect(x: 250, y: 160, width: 600, height: 300))
        w2 = makeWindow(CGRect(x: 880, y: 560, width: 480, height: 240))

        print("BENCH START phases=\(Int(phaseSeconds))s")
        after(0.8) { self.engine.start() }
        waitFor("spawn", timeout: 8, cond: {
            self.engine.stateName == "standing" && !self.engine.displayLinkActive
        }) {
            self.phasePerched()
        }
    }

    private func phasePerched() {
        measure("perched") { self.phaseSleep() }
    }

    private func phaseSleep() {
        engine.debugSetNeeds(NeedsVector(energy: 0.05, curiosity: 0.1,
                                         attention: 0.1, boredom: 0.1))
        engine.debugDecideNow()
        waitFor("sleep", timeout: 5, cond: { self.engine.isSleeping && !self.engine.displayLinkActive }) {
            self.measure("sleep") {
                self.engine.debugSetNeeds(NeedsVector(energy: 0.95))
                self.engine.debugDecideNow()
                self.waitFor("wake", timeout: 5, cond: { !self.engine.isSleeping }) {
                    self.phaseActive()
                }
            }
        }
    }

    private func phaseActive() {
        travelTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.travelToggle.toggle()
            let target = self.travelToggle ? self.w1! : self.w2!
            self.engine.debugTravel(to: CGWindowID(exactly: target.windowNumber) ?? 0)
        }
        travelTimer?.fire()
        measure("active") {
            self.travelTimer?.invalidate()
            self.report()
        }
    }

    private func measure(_ phase: String, then: @escaping () -> Void) {
        let c0 = CPUSampler.cpuSeconds()
        let t0 = CACurrentMediaTime()
        after(phaseSeconds) {
            let cpu = (CPUSampler.cpuSeconds() - c0) / (CACurrentMediaTime() - t0) * 100
            let rss = CPUSampler.rssMB()
            self.results.append((phase, cpu, rss))
            print(String(format: "BENCH RESULT %@ cpu=%.2f rss=%.1f", phase, cpu, rss))
            then()
        }
    }

    private func report() {
        func result(_ phase: String) -> (Double, Double) {
            let r = results.first { $0.0 == phase }
            return (r?.1 ?? 999, r?.2 ?? 999)
        }
        let maxRSS = results.map { $0.2 }.max() ?? 999
        var failed = false
        func verdict(_ name: String, _ value: Double, _ limit: Double, hard: Bool) {
            let ok = value <= limit
            if hard && !ok { failed = true }
            print(String(format: "BENCH VERDICT %@ %.2f <= %.1f %@", name, value, limit,
                         ok ? "PASS" : (hard ? "FAIL" : "WARN")))
        }
        verdict("sleep-cpu", result("sleep").0, 0.3, hard: true)
        verdict("active-cpu", result("active").0, 3.0, hard: true)
        verdict("rss-mb", maxRSS, 80, hard: true)
        verdict("perched-cpu", result("perched").0, 1.0, hard: false)
        print("BENCH DONE \(failed ? "FAIL" : "PASS")")
        exit(failed ? 1 : 0)
    }

    private func waitFor(_ what: String, timeout: TimeInterval,
                         cond: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if cond() { then(); return }
            if Date() > deadline {
                print("BENCH ERROR timed out waiting for \(what)")
                exit(2)
            }
            after(0.1) { poll() }
        }
        poll()
    }

    private func after(_ s: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block)
    }
}
