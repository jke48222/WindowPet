import AppKit
import ApplicationServices
import QuartzCore
import WindowPetCore

/// Accessibility permission plumbing. The pet's default experience is
/// zero-prompt (Tier 1 needs nothing); the AX prompt fires only from an
/// explicit user action, and grant-while-running is detected by polling —
/// there is no notification for it.
enum AXPermission {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestWithPrompt() {
        // The C import exposes kAXTrustedCheckOptionPrompt as a mutable
        // global, which Swift 6 will not let us touch across isolation. Its
        // value is this fixed string, so spell it out.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

/// One AXObserver per observed app. HARDENING RULES: this layer is a pure
/// event stream — after the single guarded attach-time probe it issues no AX
/// reads at all. Events mean "consult Tier 1 now"; Tier 1 stays the only
/// source of geometric truth. Every AX call checks its error, every element
/// carries a 100 ms messaging timeout (the default would hang us against a
/// beachballing app), and nothing here ever runs on the render path.
final class Tier2Observer {
    let pid: pid_t
    private var observer: AXObserver?
    private let appElement: AXUIElement
    fileprivate var onEvent: ((pid_t, String) -> Void)?
    private(set) var subscribed: [String] = []

    static let notifications: [String] = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification, // frequency only — we never read the title
    ]

    init?(pid: pid_t) {
        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<Tier2Observer>.fromOpaque(refcon).takeUnretainedValue()
            me.onEvent?(me.pid, notification as String)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let created = obs else {
            return nil
        }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in Self.notifications {
            if AXObserverAddNotification(created, appElement, note as CFString, refcon) == .success {
                subscribed.append(note)
            }
        }
        guard !subscribed.isEmpty else {
            observer = nil
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(created),
                           .commonModes)
    }

    /// The one read this layer ever performs: at attach, does the AX tree
    /// expose windows at all? Guarded, timed out, type-checked.
    func probeWindowCount() -> Int? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let arr = value as? [AnyObject] else { return nil }
        return arr.count
    }

    /// Electron's documented hook for assistive tech: flips its renderer's
    /// accessibility on. Harmless no-op error on non-Electron apps.
    func forceManualAccessibility() {
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func invalidate() {
        guard let obs = observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        for note in subscribed {
            AXObserverRemoveNotification(obs, appElement, note as CFString)
        }
        observer = nil
        onEvent = nil
    }

    deinit { invalidate() }
}

/// Owns the per-app observers and the capability matrix. Attach is lazy
/// (tracked window's app + newly activated apps), capped with LRU eviction,
/// detached on app quit. Health is judged by Tier2Policy from observed
/// evidence, never by guessing at bundles.
final class Tier2Manager {

    struct AppState {
        let pid: pid_t
        var attachedAt: TimeInterval
        var eventsSeen = 0
        var forcedManualAccessibility = false
        var degraded = false
        var sawTier1Motion = false
        var note = "attached"
    }

    private(set) var enabled = false
    private var observers: [pid_t: Tier2Observer] = [:]
    private(set) var states: [pid_t: AppState] = [:]
    private var lastWakeAt: [pid_t: TimeInterval] = [:]
    private var titleRates: [pid_t: DecayingRate] = [:]
    private var probeTimer: DispatchSourceTimer?
    private let maxObservers = 6

    /// Debounced "this app's windows did something" signal (30 ms leading
    /// edge — Stage Manager fires bursts during group transitions).
    var onActivity: ((pid_t, String) -> Void)?

    @discardableResult
    func enableIfTrusted() -> Bool {
        guard !enabled else { return true }
        enabled = AXPermission.trusted
        if enabled { startProbeTimer() }
        return enabled
    }

    func attach(to pid: pid_t, protecting protected: pid_t? = nil) {
        guard enabled, pid > 0, observers[pid] == nil else { return }
        if observers.count >= maxObservers {
            evictOldest(protecting: protected)
        }
        guard let obs = Tier2Observer(pid: pid) else {
            states[pid] = {
                var s = AppState(pid: pid, attachedAt: CACurrentMediaTime())
                s.degraded = true
                s.note = "observer create failed"
                return s
            }()
            return
        }
        obs.onEvent = { [weak self] p, note in self?.handleEvent(pid: p, note: note) }
        observers[pid] = obs
        var state = AppState(pid: pid, attachedAt: CACurrentMediaTime())
        // Attach-time probe: an app whose AX tree hides its windows is almost
        // certainly Electron with accessibility off — hook it immediately
        // rather than waiting out probation.
        if let count = obs.probeWindowCount() {
            if count == 0 {
                obs.forceManualAccessibility()
                state.forcedManualAccessibility = true
                state.note = "empty AX tree at attach — forced AXManualAccessibility"
            }
        } else {
            obs.forceManualAccessibility()
            state.forcedManualAccessibility = true
            state.note = "AXWindows unreadable at attach — forced AXManualAccessibility"
        }
        states[pid] = state
    }

    func detach(pid: pid_t) {
        observers.removeValue(forKey: pid)?.invalidate()
        states.removeValue(forKey: pid)
        lastWakeAt.removeValue(forKey: pid)
        titleRates.removeValue(forKey: pid)
    }

    func isAttached(_ pid: pid_t) -> Bool { observers[pid] != nil }

    /// Engine reports observed Tier-1 motion — the evidence half of the
    /// Electron contradiction.
    func notedTier1Motion(pid: pid_t) {
        states[pid]?.sawTier1Motion = true
    }

    private func handleEvent(pid: pid_t, note: String) {
        states[pid]?.eventsSeen += 1
        let now = CACurrentMediaTime()
        if note == kAXTitleChangedNotification {
            titleRates[pid, default: DecayingRate()].hit(at: now)
        }
        if now - (lastWakeAt[pid] ?? 0) > 0.03 {
            lastWakeAt[pid] = now
            onActivity?(pid, note)
        }
    }

    /// Title-change frequency for an observed app — the "is something
    /// happening in there" signal (builds, progress titles, playback).
    func titleRate(pid: pid_t, at now: TimeInterval) -> Double {
        titleRates[pid]?.rate(at: now) ?? 0
    }

    /// Most title-active observed app above the agitation threshold, if any.
    func hottestTitleApp(at now: TimeInterval) -> (pid: pid_t, rate: Double)? {
        let best = titleRates
            .map { (pid: $0.key, rate: $0.value.rate(at: now)) }
            .max { $0.rate < $1.rate }
        guard let best, ReactionPolicy.isAgitated(titleRate: best.rate) else { return nil }
        return best
    }

    /// Test hook: inject title activity as if events had arrived.
    func debugBumpTitleRate(pid: pid_t, hits: Int) {
        let now = CACurrentMediaTime()
        for _ in 0..<hits { titleRates[pid, default: DecayingRate()].hit(at: now) }
    }

    private func evictOldest(protecting protected: pid_t?) {
        let victim = states.values
            .filter { $0.pid != protected && observers[$0.pid] != nil }
            .min { $0.attachedAt < $1.attachedAt }
        if let victim { detach(pid: victim.pid) }
    }

    private func startProbeTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.probeTick() }
        t.resume()
        probeTimer = t
    }

    private func probeTick() {
        let now = CACurrentMediaTime()
        for (pid, state) in states {
            guard let obs = observers[pid] else { continue }
            let decision = Tier2Policy.probe(attachedFor: now - state.attachedAt,
                                             eventsSeen: state.eventsSeen,
                                             sawTier1Motion: state.sawTier1Motion,
                                             alreadyForced: state.forcedManualAccessibility,
                                             alreadyDegraded: state.degraded)
            switch decision {
            case .none:
                continue
            case .forceManualAccessibility:
                obs.forceManualAccessibility()
                states[pid]?.forcedManualAccessibility = true
                states[pid]?.note = "silent through probation — forced AXManualAccessibility"
                states[pid]?.attachedAt = now // fresh probation for the retry
                states[pid]?.sawTier1Motion = false // evidence consumed; require fresh contradiction
            case .markDegraded:
                states[pid]?.degraded = true
                states[pid]?.note = "no AX events despite motion — degraded (Tier 1 only)"
            }
        }
    }

    var summaryLines: [String] {
        guard enabled else { return ["Tier 2 disabled (Accessibility not granted)"] }
        if states.isEmpty { return ["Tier 2 on, no apps attached yet"] }
        return states.values.sorted { $0.attachedAt < $1.attachedAt }.map { s in
            let name = NSRunningApplication(processIdentifier: s.pid)?.localizedName ?? "pid \(s.pid)"
            let health = s.degraded ? "degraded" : (s.eventsSeen > 0 ? "healthy" : "quiet")
            let forced = s.forcedManualAccessibility ? ", electron-hooked" : ""
            return "\(name): \(health), \(s.eventsSeen) events\(forced) — \(s.note)"
        }
    }
}
